#!/usr/bin/env bash
# seed-drift: the normalization pipeline — path neutralization, privilege-
# prefix stripping, word splitting, templated-assignment classification, and
# test-spelling canonicalization. This is the layer that churns as new seed
# variations appear. Sourced by bin/seed-drift; never executed.

sd_neutralize_paths() {
  # Deliberately unanchored on the right: `$HOME` also rewrites inside
  # `$HOMEBREW_PREFIX`, and a right boundary is genuinely awkward in
  # BSD-portable sed. It cannot flip a verdict, because the identical rule is
  # applied to both sides before they are diffed; the cost is confined to
  # mangled text in the sample lines printed for a drifted block.
  sed -e 's/\${SEED_HOME}/«HOME»/g' -e 's/\$SEED_HOME/«HOME»/g' \
    -e 's/\${DOTFILES_HOME}/«HOME»\/.dotfiles/g' \
    -e 's/\$DOTFILES_HOME/«HOME»\/.dotfiles/g' \
    -e 's/\${WORKSPACE}/«WS»/g' -e 's/\$WORKSPACE/«WS»/g' \
    -e 's/\${HOME}/«HOME»/g' -e 's/\$HOME/«HOME»/g'
}

sd_drop_priv_prefix() {
  # Privilege words are dropped in COMMAND POSITION only: at line start, or
  # right after an operator/keyword that begins a new command. `as_user` sits
  # mid-line 8 times in the template (`if as_user test -x ...`,
  # `... || as_user bash -lc ...`) and the live seeds split on it —
  # wanderer-kills writes `if ! as_user test -f "$GITIGNORE"; then` where
  # wanderer writes `if [ ! -f "$GITIGNORE" ]; then` — so a line-start-only
  # rule would report every one of those shapes as drift.
  #
  # No word-boundary escape: that construct is a GNU sed extension and this
  # script must also run under the BSD sed macOS ships. Operators are
  # self-delimiting, so they need no boundary; the keywords take an explicit
  # `(^|[[:space:]])` left boundary instead, which is why they are a separate
  # expression. `sd_normalize_code_line` has already collapsed runs of
  # whitespace to single spaces before we get here.
  #
  # The operator arm takes `[[:space:]]*`, not `+`: command substitution opens
  # with `$(` and the privilege word follows with NO space, so `+` matched
  # every `if as_user foo` in the template while missing every
  # `x="$(as_user foo)"` — and the seeds, which drop the wrapper entirely,
  # were reported as drifted on lines that differ by exactly that one word.
  # The keyword arm keeps `+` because a keyword must be space-separated from
  # its command; `[[:space:]]*` there would let `ifas_user` match. The runuser
  # operator arm gets the same `*` for symmetry — no seed nests it inside `$(`
  # today, but the gap is identical and an asymmetric fix would only invite the
  # question later.
  # `((` opens ARITHMETIC, not a command — both as `$((x))` and as the bare
  # `((x))` command. In `x=$((sudo + 1))` and `if ((sudo + 1)); then` the word
  # `sudo` is an arithmetic variable, and the operator arm — which deliberately
  # requires no space after its opener — would strip it to `+ 1`. sed has no
  # lookbehind, so shield the token for the duration of the loop and restore it
  # after. Shielding `((` covers `$((` too: it leaves a bare `$` in front of the
  # shield, and `$` is not in the operator class. A single `(` is deliberately
  # NOT shielded, so a real subshell like `(sudo foo)` still strips. \001 is used
  # because it cannot occur in a shell script these seeds are written in.
  local line="$1" prev="" arith=$'\001'
  line=${line//'(('/"$arith"}
  while [ "$line" != "$prev" ]; do
    prev="$line"
    line=$(printf '%s\n' "$line" | sed -E \
      -e 's/(^|[{(|;!]|&&|\|\|)([[:space:]]*)(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+/\1\2/g' \
      -e 's/(^|[[:space:]])(if|then|while|until|do|elif)([[:space:]]+)(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+/\1\2\3/g' \
      -e 's/^(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+//' \
      -e 's/(^|[{(|;!]|&&|\|\|)([[:space:]]*)runuser -u [^[:space:]]+ --[[:space:]]+/\1\2/g' \
      -e 's/(^|[[:space:]])(if|then|while|until|do|elif)([[:space:]]+)runuser -u [^[:space:]]+ --[[:space:]]+/\1\2\3/g' \
      -e 's/^runuser -u [^[:space:]]+ --[[:space:]]+//')
  done
  line=${line//"$arith"/'(('}
  printf '%s' "$line"
}

# Per-project assignments the template carries as `{USER}` / `{WORKSPACE}`
# placeholders, for which every rendered seed necessarily holds a different
# literal. Dropping them from BOTH sides is what makes the two shapes the fleet
# actually uses compare equal:
#
#   inline  - the seed keeps `WORKSPACE="/workspaces/x"` where the template has
#             `WORKSPACE="{WORKSPACE}"`, inside a compared window. A value
#             mismatch: 1 line behind AND 1 ahead, reported as DIVERGED.
#   hoisted - the seed lifts the assignment into its variable block, far above
#             every anchor. A placement mismatch: the template's line has no
#             counterpart in the window at all, reported as BEHIND.
#
# Neutralizing the placeholder to its value would only fix the first shape.
# Dropping the line fixes both, because a window that no longer contains it on
# either side compares equal whether the seed hoisted it or not.
#
# LITERAL RHS ONLY. catch-up-local-seed.md is explicit that WORKSPACE must not
# be derived - the seed is mounted at an arbitrary container path that need not
# sit inside the checkout, so `git rev-parse` from there resolves to the wrong
# tree. A seed that regressed to `WORKSPACE="$(git rev-parse --show-toplevel)"`
# must still be flagged, so anything containing `$`, a backtick or `$(` is kept
# and drifts against the template's dropped literal.
#
# The definedness check in sd_check_seed is the compensating guard: block
# comparison no longer notices a seed that never assigns these at all.

# Splits a declaration into its individual words, one per line, honouring one
# level of quoting so `export WORKSPACE="/my path" OTHER=1` yields two words and
# not three. Deliberately not `eval` or `set --`: the input is seed content, and
# word-splitting it through the shell would execute the substitutions inside it.
sd_split_words() {
  local s="$1" out="" q="" c i n=${#1}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -n "$q" ]; then
      out="$out$c"
      [ "$c" = "$q" ] && q=""
      continue
    fi
    case "$c" in
      \" | \')
        q="$c"
        out="$out$c"
        ;;
      ' ' | $'\t') out="$out"$'\n' ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s\n' "$out"
}

# The single grammar for a per-project templated declaration, shared by the drop
# rule in sd_normalize_code_line and the whole-file check in
# sd_templated_var_problems. Exactly one place decides what one of these
# declarations IS and whether its RHS is a plain literal: two copies of that
# question drifting apart is precisely how a line gets dropped from the diff by
# one rule and then missed by the other.
#
# With no $2 the question is "is this line, as a whole, a lone literal
# declaration?" - the drop rule's question. With $2 it is "does this line
# declare THAT variable, and how?" - the whole-file check's question.
#
#   0 - a declaration with a plain literal RHS   => dropped from comparison
#   2 - a declaration with any other RHS         => kept, and reported
#   1 - not one of these declarations at all
sd_classify_templated_assignment() {
  local line="$1" want="${2:-}" rhs inner word name kw=0 found=1
  local words=() w
  line="${line#"${line%%[![:space:]]*}"}"
  # Declaration prefixes, kept identical on both sides of the shared grammar.
  # `export` matters: a seed that exports WORKSPACE has declared it just as much
  # as a bare assignment does, and rejecting the form here while accepting it in
  # the definedness check is the inconsistency this function exists to prevent.
  case "$line" in
    export\ * | declare\ * | readonly\ * | typeset\ * | local\ *)
      kw=1
      # `local` does NOT declare a whole-file variable: bash refuses it outside
      # a function outright, and inside one the binding dies with the call, so a
      # top-level read afterwards still aborts under `set -u`. Treating it as an
      # assignment would silence exactly the failure this check exists to catch.
      # It stays a declaration for the DROP rule, where the question is only
      # whether the line is a per-project value the diff should ignore.
      case "$line" in
        local\ *) [ -z "$want" ] || return 1 ;;
      esac
      line="${line#* }"
      line="${line#"${line%%[![:space:]]*}"}"
      # EVERY option word, not just the first: `declare -x -r WORKSPACE=...` and
      # `local -r WORKSPACE=...` are declarations too, and stopping after one
      # leaves the option looking like the variable name - which reports a
      # perfectly well-defined WORKSPACE as never assigned.
      while :; do
        case "$line" in
          -*)
            case "$line" in
              *' '*)
                line="${line#* }"
                line="${line#"${line%%[![:space:]]*}"}"
                ;;
              # Options and nothing else.
              *) return 1 ;;
            esac
            ;;
          *) break ;;
        esac
      done
      ;;
  esac
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    words+=("$w")
  done <<<"$(sd_split_words "$line")"
  [ "${#words[@]}" -gt 0 ] || return 1
  # Without a declaration keyword, only a LONE `NAME=VALUE` line declares
  # anything: `WORKSPACE=/w cmd` is a prefix assignment scoped to that one
  # command, so it must not count as defining WORKSPACE for the rest of the
  # seed. With a keyword, every word is a declaration.
  if [ "$kw" -eq 0 ] && [ "${#words[@]}" -ne 1 ]; then
    return 1
  fi
  # The drop rule never removes a line that does more than one thing: whatever
  # else it assigns is information the diff still needs.
  if [ -z "$want" ] && [ "${#words[@]}" -ne 1 ]; then
    return 1
  fi
  for word in "${words[@]}"; do
    case "$word" in *=*) ;; *) continue ;; esac
    name="${word%%=*}"
    case "$name" in
      SEED_USER | WORKSPACE) ;;
      *) continue ;;
    esac
    [ -z "$want" ] || [ "$name" = "$want" ] || continue
    rhs="${word#*=}"
    case "$rhs" in
      # Single quotes suppress every expansion, so the content is literal
      # whatever it holds - but the closing quote must be the LAST character, or
      # what looks like a quoted value is a quoted value followed by more.
      \'*\')
        inner="${rhs%\'}" inner="${inner#\'}"
        case "$inner" in *\'*) return 2 ;; esac
        ;;
      \"*\")
        inner="${rhs%\"}" inner="${inner#\"}"
        case "$inner" in *'$'* | *'`'* | *'"'*) return 2 ;; esac
        ;;
      # Unquoted: an allowlist of characters a literal path can contain, so
      # every form carrying shell syntax - `WORKSPACE=/w;true`,
      # `WORKSPACE=<(pwd)`, `WORKSPACE=~`, a glob - is rejected rather than
      # silently dropped. Rejecting is the safe direction: a rejected line is
      # kept and shows up as drift.
      *)
        case "$rhs" in
          *[!A-Za-z0-9_/.:@%+,-]*) return 2 ;;
        esac
        ;;
    esac
    found=0
  done
  return "$found"
}

sd_canon_test() {
  # `[ X ]` and `test X` are one builtin spelled two ways, and the seeds split
  # on it constantly: the template writes `if test -L "$GITIGNORE"` where
  # slabledger writes `[ -L "$GITIGNORE" ] &&`. Canonicalize onto `test`.
  #
  # A token walk rather than a sed fixpoint loop like sd_drop_priv_prefix's:
  # this runs on every code line of every block of every seed, and a second
  # per-line subshell measured ~30% onto a full audit. sd_normalize_code_line
  # has already collapsed whitespace to single spaces, so splitting on space
  # is exact here and needs no IFS games.
  #
  # Only a STANDALONE `[` token is rewritten, never `${a[0]}` or a `[Yy]` glob,
  # because those carry no surrounding spaces and so never form their own word.
  #
  # BAIL-OUT RULE: a token walk cannot parse shell, so where the pairing of an
  # opener to its closer is not unambiguous this returns the line UNCHANGED
  # rather than guessing. Three shapes bail: a bracket inside a quoted string
  # (`[ "$x" = "a ] b" ]`), a `[` appearing while a predicate is already open
  # (`[ -z "$(cmd [ x ] arg)" ]` — the inner one is not in command position but
  # its closer is still a bare `]`), and a closer with no opener. An
  # un-canonicalized line at worst reports drift a human then reads; a
  # mis-paired rewrite silently corrupts the comparison. Prefer visible drift
  # over a false clean.
  local line="$1"
  case "$line" in
    *'[ '*) ;;
    *) # nothing to do; skip the split entirely for the common case
      printf '%s' "$line"
      return 0
      ;;
  esac

  local -a toks out mk
  read -r -a toks <<<"$line"
  local i n=${#toks[@]} t cmdpos=1 open=0 inq="" k len c
  out=() mk=()
  for ((i = 0; i < n; i++)); do
    t="${toks[i]}"

    # Structural brackets are only structural outside quotes.
    if [ -z "$inq" ]; then
      if [ "$t" = "[" ]; then
        # Nesting is not supported, only rejected: a second opener while one is
        # live means the closers cannot be paired by position alone.
        if [ "$open" = 1 ] || [ "$cmdpos" != 1 ]; then
          printf '%s' "$line"
          return 0
        fi
        out+=("test")
        mk+=($((${#out[@]} - 1)))
        open=1
        cmdpos=0
        continue
      fi
      if [ "$t" = "]" ] || [ "$t" = "];" ]; then
        if [ "$open" != 1 ]; then
          printf '%s' "$line"
          return 0
        fi
        open=0
        # The closer arrives as its own word, but `if [ -x "$f" ]; then`
        # collapses the separator onto it — so `];` must drop the bracket and
        # KEEP the `;`, or every `if [ ... ]; then` in the tree loses its
        # command separator and the window stops parsing under `bash -n`.
        if [ "$t" = "];" ]; then
          # Reattach, not `out+=(";")`: the template writes `if test -x "$f";
          # then` with the separator flush against the operand, so a standalone
          # `;` would leave a stray space and the two spellings would still not
          # compare equal — which is the entire point of this function.
          if [ "${#out[@]}" -gt 0 ]; then
            out[${#out[@]} - 1]="${out[${#out[@]} - 1]};"
          else
            out+=(";")
          fi
          cmdpos=1
        fi
        continue
      fi
    fi

    out+=("$t")

    # Quote tracking, charwise but only for tokens that actually contain a
    # quote — the overwhelming majority do not, so the fast path stays a single
    # pattern match. An escaped quote is not modelled; miscounting one only
    # costs a bail-out, which is safe by construction.
    case "$t" in
      *[\"\']*)
        len=${#t}
        for ((k = 0; k < len; k++)); do
          c="${t:k:1}"
          if [ -z "$inq" ]; then
            case "$c" in '"' | "'") inq="$c" ;; esac
          elif [ "$c" = "$inq" ]; then
            inq=""
          fi
        done
        ;;
    esac

    # A command starts at line start or after a separator/keyword. `;`-suffixed
    # words (`then`, `fi;`) count via the trailing-`;` test.
    if [ -z "$inq" ]; then
      case "$t" in
        '&&' | '||' | '|' | '{' | '(' | '!' | 'if' | 'then' | 'elif' | 'while' | 'until' | 'do') cmdpos=1 ;;
        *';') cmdpos=1 ;;
        *) cmdpos=0 ;;
      esac
    fi
  done

  # An opener with no closer, or a string left open, means the walk lost track.
  if [ "$open" != 0 ] || [ -n "$inq" ]; then
    printf '%s' "$line"
    return 0
  fi

  # `test ! -f x` and `! test -f x` are the same predicate; the seeds write
  # both (`[ ! -f "$G" ]` normalizes to the former, the template writes the
  # latter). Hoist the negation so they agree — but ONLY for a `test` this
  # function itself created, tracked in `mk`. Swapping any adjacent `test !`
  # pair would rewrite unrelated arguments, turning `echo test ! value` into
  # `echo ! test value`.
  local j idx m=${#out[@]}
  if [ "${#mk[@]}" -gt 0 ]; then
    for j in "${mk[@]}"; do
      idx=$((j + 1))
      if [ "$idx" -lt "$m" ] && [ "${out[idx]}" = "!" ]; then
        out[j]="!"
        out[idx]="test"
      fi
    done
  fi

  printf '%s' "${out[*]}"
}

sd_normalize_code_line() {
  local line="$1" cls=0
  line="${line//$'\t'/ }"
  while [ "$line" != "${line//  / }" ]; do line="${line//  / }"; done
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || return 0
  # Only a LITERAL declaration is dropped. A derived one stays in the diff and
  # is reported by the whole-file check as well, so that it is caught wherever
  # the seed happens to put it.
  sd_classify_templated_assignment "$line" || cls=$?
  [ "$cls" -ne 0 ] || return 0
  line=$(sd_drop_priv_prefix "$line")
  line=$(sd_canon_test "$line")
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | sd_neutralize_paths
}

sd_normalize() {
  local rec tag text rest pending="" joining=0
  # Positional split, not `IFS=$'\t' read`: that form strips leading tabs from
  # `text`, which would corrupt every `<<-` heredoc body. `para` and `lineno`
  # are skipped rather than bound — binding them trips SC2034 under
  # `shellcheck -S warning`, which this repo gates on.
  while IFS= read -r rec; do
    rest="${rec#*$'\t'}"
    rest="${rest#*$'\t'}"
    tag="${rest%%$'\t'*}"
    text="${rest#*$'\t'}"
    if [ "$tag" = C ]; then
      if [ "$joining" = 1 ]; then
        pending="$pending ${text#"${text%%[![:space:]]*}"}"
      else
        pending="$text"
      fi
      if [ "${pending%\\}" != "$pending" ]; then
        pending="${pending%\\}"
        joining=1
        continue
      fi
      sd_normalize_code_line "$pending"
      pending="" joining=0
      continue
    fi
    # A heredoc body ends any pending continuation: a payload line is data and
    # must never be folded into the shell line above it.
    if [ "$joining" = 1 ]; then
      sd_normalize_code_line "$pending"
      pending="" joining=0
    fi
    if [ "$tag" = Hu ]; then
      printf '%s\n' "$text" | sd_neutralize_paths
    else
      printf '%s\n' "$text"
    fi
  done
  [ "$joining" = 0 ] || sd_normalize_code_line "$pending"
}
