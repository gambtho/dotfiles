#!/usr/bin/env bash
# Shared owner -> identity resolution for bin/gh, bin/git-identity, and the
# pre-push guard. Sourced, never executed.
#
# BASH 3.2 ONLY: macOS ships bash 3.2. No associative arrays, and none of the
# Bash-4-only array-reading builtins.
#
# Three states, and conflating any two reintroduces a silent wrong-identity
# path:
#   unmapped   owner absent from the map   -> out of remit
#   default    owner maps to the default   -> stock gh config
#   secondary  maps to another slug        -> may be UNPROVISIONED

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"

# The profile recorded by bin/bootstrap. Read the file directly rather than
# relying on a shell variable: the pre-push hook and the gh shim run outside
# any zsh startup, so profiles/*.zsh has not been sourced for them.
identity_profile() {
  local p=""
  [ -r "$HOME/.dotfiles-profile" ] || return 1
  p="$(tr -d '[:space:]' <"$HOME/.dotfiles-profile")"
  # The name becomes a path component below, so reject anything that is not a
  # plain lowercase token -- "../../etc" must not select an arbitrary file.
  case "$p" in
    "" | *[!a-z0-9-]*) return 1 ;;
  esac
  printf '%s\n' "$p"
}

# Which owner map applies here. Highest precedence first, REPLACE semantics --
# the first file that exists wins outright and the others are not merged in.
# Merging would let a machine silently inherit another machine's roles, which
# is the failure this whole design exists to prevent.
#
#   1. $IDENTITY_MAP_FILE   explicit override (tests, one-offs)
#   2. identity-owners.local     gitignored, this machine only
#   3. identity-owners.<profile> tracked, shared by machines of that profile
#   4. identity-owners           tracked, the shared default
#
# A selected file that is malformed or unreadable is NOT skipped: validation
# fails and every consumer fails closed. Falling through to a different map
# would silently change which account a push authenticates as.
identity_default_map_file() {
  local root="$IDENTITY_DOTFILES_ROOT" profile

  if [ -e "$root/core/git/identity-owners.local" ]; then
    printf '%s\n' "$root/core/git/identity-owners.local"
    return 0
  fi
  if profile="$(identity_profile)" &&
    [ -e "$root/core/git/identity-owners.$profile" ]; then
    printf '%s\n' "$root/core/git/identity-owners.$profile"
    return 0
  fi
  printf '%s\n' "$root/core/git/identity-owners"
}

IDENTITY_MAP_FILE="${IDENTITY_MAP_FILE:-$(identity_default_map_file)}"

# Print the owner for a github.com URL. Exit 1 for any other host or
# unparseable input; callers treat that as "out of remit".
identity_url_owner() {
  local url="$1" rest host path

  case "$url" in
    https://* | http://*)
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    ssh://*)
      rest="${url#ssh://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    *@*:*)
      rest="${url#*@}"
      host="${rest%%:*}"
      path="${rest#*:}"
      ;;
    *)
      return 1
      ;;
  esac

  host="${host%%:*}"
  [ "$host" = "github.com" ] || return 1

  path="${path#/}"
  case "$path" in
    */*) : ;;
    *) return 1 ;;
  esac

  printf '%s\n' "${path%%/*}"
}

# Validate the map. A malformed or duplicated entry is a hard error, never a
# skipped line: a dropped entry demotes a known owner to "unmapped" and turns a
# blocked push into a silent wrong-identity push.
identity_validate_map() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line owner slug extra rest lineno=0 seen=""

  # A regular file specifically. A directory or FIFO is readable enough to pass
  # a bare -r test, but the read loop below then fails immediately and the
  # function would return success with an EMPTY map -- every owner unmapped,
  # every consumer failing open. That is the exact inversion of this design's
  # contract, so the type check belongs here rather than at selection time:
  # selection keeps its precedence and a bogus path is rejected loudly instead
  # of silently falling through to a map with different roles.
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'identity: owner map is not a readable regular file: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    # Split explicitly rather than relying on unquoted expansion, so the
    # behaviour is identical under `sh`-like IFS settings.
    IFS=$' \t' read -r owner slug extra rest <<<"$line"
    [ -n "$owner" ] || continue

    if [ -z "$slug" ] || [ -n "$extra" ]; then
      printf 'identity: malformed entry at %s:%d\n' "$file" "$lineno" >&2
      return 1
    fi
    # Validate the WHOLE token, not just its first character. Owners must be
    # canonical lowercase because identity_owner_slug folds the lookup key: an
    # uppercase entry here would parse fine and then never match anything, which
    # is a silent misconfiguration rather than a visible error.
    case "$owner" in
      -* | *[!a-z0-9-]*)
        printf 'identity: owner must be lowercase [a-z0-9-] at %s:%d\n' "$file" "$lineno" >&2
        return 1
        ;;
    esac
    # Slugs become path components in ~/.gitconfig.<slug> and ~/.gh-<slug>, so a
    # separator or dot segment would escape the intended location.
    case "$slug" in
      -* | *[!a-z0-9-]*)
        printf 'identity: slug must be lowercase [a-z0-9-] at %s:%d\n' "$file" "$lineno" >&2
        return 1
        ;;
    esac
    case " $seen " in
      *" $owner "*)
        printf 'identity: duplicate owner %s at %s:%d\n' "$owner" "$file" "$lineno" >&2
        return 1
        ;;
    esac
    seen="$seen $owner"
  done <"$file"

  return 0
}

identity_owner_slug() {
  local owner="$1" file="${2:-$IDENTITY_MAP_FILE}"
  local line o s extra rest

  # GitHub owner names are case-insensitive (Guarzo/guarzo/GUARZO all resolve
  # to the same account), but git's own `includeIf hasconfig:` matching is
  # case-sensitive and cannot be fixed from here. Fold here, once, so every
  # consumer -- bin/gh, bin/git-identity, the pre-push guard -- treats a
  # differently-cased owner as the same mapped identity instead of silently
  # falling through to "unmapped" and the default account. `tr` is used
  # instead of `${owner,,}` because that expansion is bash-4-only and this
  # file must run under bash 3.2 (macOS).
  owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    IFS=$' \t' read -r o s extra rest <<<"$line"
    [ -n "$o" ] || continue
    if [ "$o" = "$owner" ]; then
      printf '%s\n' "$s"
      return 0
    fi
  done <"$file"

  return 1
}

# shellcheck disable=SC2120  # callers may pass a map path; the default is used internally
identity_slugs() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line o s extra rest

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    IFS=$' \t' read -r o s extra rest <<<"$line"
    [ -n "$s" ] || continue
    printf '%s\n' "$s"
  done <"$file" | sort -u
}

identity_slug_configdir() {
  local slug="$1"
  if [ "$slug" = default ]; then
    printf '%s\n' "${GH_DEFAULT_CONFIG_DIR:-$HOME/.config/gh}"
  else
    printf '%s\n' "$HOME/.gh-$slug"
  fi
}

identity_slug_configfile() {
  local slug="$1"
  if [ "$slug" = default ]; then
    printf '%s\n' "$HOME/.gitconfig.local"
  else
    printf '%s\n' "$HOME/.gitconfig.$slug"
  fi
}

# A secondary slug is provisioned only when BOTH its git include and its gh
# config dir exist. Either alone is a half-configured identity, which looks
# usable to a naive check and then fails at push time.
identity_slug_provisioned() {
  local slug="$1" dir
  [ "$slug" = default ] && return 0
  [ -e "$(identity_slug_configfile "$slug")" ] || return 1
  dir="$(identity_slug_configdir "$slug")"
  [ -d "$dir" ] || return 1
  return 0
}

identity_slug_email() {
  local file
  file="$(identity_slug_configfile "$1")"
  [ -r "$file" ] || return 1
  git config --file "$file" user.email 2>/dev/null
}

identity_slug_key() {
  local file
  file="$(identity_slug_configfile "$1")"
  [ -r "$file" ] || return 1
  git config --file "$file" user.signingKey 2>/dev/null
}

# Distinct MAPPED owners across every remote. Unmapped owners are omitted, so
# "guarzo + an unmapped work org" is not mixed-owner.
identity_repo_owners() {
  local url owner
  git config --get-regexp '^remote\..*\.url$' 2>/dev/null |
    cut -d' ' -f2- |
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      owner="$(identity_url_owner "$url")" || continue
      identity_owner_slug "$owner" >/dev/null 2>&1 || continue
      printf '%s\n' "$owner"
    done | sort -u
}

# Which mapped slug does this repository's EFFECTIVE config actually match?
# Compares author email and signing key -- the original incident had correct
# emails and the wrong signing key in all three repositories, so email alone
# does not identify an identity. Prints nothing when no slug matches.
identity_effective_slug() {
  local eff_email eff_key slug exp_email exp_key
  eff_email="$(git config user.email 2>/dev/null || true)"
  eff_key="$(git config user.signingKey 2>/dev/null || true)"
  [ -n "$eff_email" ] || return 0

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    exp_email="$(identity_slug_email "$slug" 2>/dev/null || true)"
    [ -n "$exp_email" ] || continue
    [ "$exp_email" = "$eff_email" ] || continue
    exp_key="$(identity_slug_key "$slug" 2>/dev/null || true)"
    if [ -n "$exp_key" ] && [ -n "$eff_key" ] && [ "$exp_key" != "$eff_key" ]; then
      continue
    fi
    printf '%s\n' "$slug"
    return 0
  done < <(identity_slugs)

  return 0
}

# Render the conditional-include blocks that route matching remotes to each
# non-default identity, one per mapped owner, from the ACTIVE map.
#
# These are generated rather than tracked because the map is per-machine while a
# tracked block is not: once a machine-local map flips which account is default,
# a hardcoded block names the wrong owner and the other identity is never routed
# at all -- silently, because the config still parses. Generating from the same
# map every consumer reads makes that disagreement impossible by construction.
identity_render_routes() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line owner slug extra rest

  printf '# Generated by bin/relink from %s -- do not edit.\n' "$file"
  printf '# Routes each mapped owner to its identity; regenerate after map changes.\n'

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    IFS=$' \t' read -r owner slug extra rest <<<"$line"
    [ -n "$owner" ] || continue
    [ -n "$slug" ] || continue
    [ "$slug" = default ] && continue
    printf '[includeIf "hasconfig:remote.*.url:https://github.com/%s/**"]\n' "$owner"
    printf '\tpath = ~/.gitconfig.%s\n' "$slug"
  done <"$file"
}
