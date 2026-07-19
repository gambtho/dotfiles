() {
  emulate -L zsh
  setopt extendedglob

  local _vekil_env_state_dir _vekil_env_host_file _vekil_env_ready_file
  local _vekil_env_host _vekil_env_url_host _vekil_env_port _vekil_env_mode
  local _vekil_env_part _vekil_env_left _vekil_env_right
  local -a _vekil_env_parts
  local -i _vekil_env_valid=0 _vekil_env_count=0
  local -i _vekil_env_openai_managed=0 _vekil_env_anthropic_managed=0

  if [[ -n ${VEKIL_MANAGED_OPENAI_BASE_URL:-} ]]; then
    if (( ! ${+OPENAI_BASE_URL} )) || [[ $OPENAI_BASE_URL != $VEKIL_MANAGED_OPENAI_BASE_URL ]]; then
      unset VEKIL_MANAGED_OPENAI_BASE_URL
    fi
  fi
  if [[ -n ${VEKIL_MANAGED_OPENAI_API_KEY:-} ]]; then
    if (( ! ${+OPENAI_API_KEY} )) || [[ $OPENAI_API_KEY != $VEKIL_MANAGED_OPENAI_API_KEY ]]; then
      unset VEKIL_MANAGED_OPENAI_API_KEY
    fi
  fi
  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_BASE_URL:-} ]]; then
    if (( ! ${+ANTHROPIC_BASE_URL} )) || [[ $ANTHROPIC_BASE_URL != $VEKIL_MANAGED_ANTHROPIC_BASE_URL ]]; then
      unset VEKIL_MANAGED_ANTHROPIC_BASE_URL
    fi
  fi
  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_API_KEY:-} ]]; then
    if (( ! ${+ANTHROPIC_API_KEY} )) || [[ $ANTHROPIC_API_KEY != $VEKIL_MANAGED_ANTHROPIC_API_KEY ]]; then
      unset VEKIL_MANAGED_ANTHROPIC_API_KEY
    fi
  fi
  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_MODEL:-} ]]; then
    if (( ! ${+ANTHROPIC_MODEL} )) || [[ $ANTHROPIC_MODEL != $VEKIL_MANAGED_ANTHROPIC_MODEL ]]; then
      unset VEKIL_MANAGED_ANTHROPIC_MODEL
    fi
  fi

  if ! () {
    _vekil_env_port=${VEKIL_PORT:-1337}
    [[ $_vekil_env_port == <-> ]] || return 1
    _vekil_env_port=$(( 10#$_vekil_env_port ))
    (( _vekil_env_port >= 1 && _vekil_env_port <= 65535 )) || return 1

    if [[ -e /.dockerenv || -n ${REMOTE_CONTAINERS:-} || -n ${CODESPACES:-} ]]; then
      _vekil_env_host=host.docker.internal
    else
      if (( ${+VEKIL_STATE_DIR} )); then
        [[ -n $VEKIL_STATE_DIR && $VEKIL_STATE_DIR == /* ]] || return 1
        _vekil_env_state_dir=$VEKIL_STATE_DIR
      elif [[ -n ${XDG_STATE_HOME:-} && $XDG_STATE_HOME == /* ]]; then
        _vekil_env_state_dir=$XDG_STATE_HOME/vekil
      else
        [[ -n ${HOME:-} && $HOME == /* ]] || return 1
        _vekil_env_state_dir=$HOME/.local/state/vekil
      fi

      [[ $_vekil_env_state_dir == /* && $_vekil_env_state_dir != *[$'\n\r']* ]] || return 1
      _vekil_env_parts=("${(@s:/:)_vekil_env_state_dir}")
      for _vekil_env_part in $_vekil_env_parts; do
        [[ $_vekil_env_part != . && $_vekil_env_part != .. ]] || return 1
      done

      _vekil_env_host_file=$_vekil_env_state_dir/proxy-host
      _vekil_env_ready_file=$_vekil_env_state_dir/proxy-ready
      [[ ${_vekil_env_state_dir:A} == $_vekil_env_state_dir ]] || return 1
      [[ -d $_vekil_env_state_dir && ! -L $_vekil_env_state_dir && -O $_vekil_env_state_dir ]] || return 1
      [[ -f $_vekil_env_host_file && ! -L $_vekil_env_host_file && -O $_vekil_env_host_file && -r $_vekil_env_host_file ]] || return 1
      [[ -f $_vekil_env_ready_file && ! -L $_vekil_env_ready_file && -O $_vekil_env_ready_file && -r $_vekil_env_ready_file ]] || return 1

      _vekil_env_mode=$(command stat -c %a -- $_vekil_env_state_dir 2>/dev/null) || \
        _vekil_env_mode=$(command stat -f %Lp -- $_vekil_env_state_dir 2>/dev/null) || return 1
      [[ $_vekil_env_mode == <-> ]] || return 1
      (( (8#$_vekil_env_mode & 8#77) == 0 )) || return 1

      _vekil_env_mode=$(command stat -c %a -- $_vekil_env_host_file 2>/dev/null) || \
        _vekil_env_mode=$(command stat -f %Lp -- $_vekil_env_host_file 2>/dev/null) || return 1
      [[ $_vekil_env_mode == <-> ]] || return 1
      (( (8#$_vekil_env_mode & 8#77) == 0 )) || return 1

      _vekil_env_mode=$(command stat -c %a -- $_vekil_env_ready_file 2>/dev/null) || \
        _vekil_env_mode=$(command stat -f %Lp -- $_vekil_env_ready_file 2>/dev/null) || return 1
      [[ $_vekil_env_mode == <-> ]] || return 1
      (( (8#$_vekil_env_mode & 8#77) == 0 )) || return 1

      _vekil_env_host=$(<$_vekil_env_host_file)
      [[ -n $_vekil_env_host && $_vekil_env_host != *[[:space:]]* ]] || return 1
      if [[ $_vekil_env_host == \[*\] ]]; then
        _vekil_env_host=${_vekil_env_host[2,-2]}
      fi

      if [[ $_vekil_env_host == *.* && $_vekil_env_host != *[^0-9.]* ]]; then
        _vekil_env_parts=("${(@s:.:)_vekil_env_host}")
        if (( ${#_vekil_env_parts} == 4 )); then
          _vekil_env_valid=1
          for _vekil_env_part in $_vekil_env_parts; do
            if [[ $_vekil_env_part != (0|[1-9][0-9]#) ]] || (( 10#$_vekil_env_part > 255 )); then
              _vekil_env_valid=0
              break
            fi
          done
        fi
      elif [[ $_vekil_env_host == *:* && $_vekil_env_host != *[^0-9A-Fa-f:]* && $_vekil_env_host != *:::* ]]; then
        _vekil_env_count=0
        _vekil_env_valid=1
        if [[ $_vekil_env_host == *::* ]]; then
          [[ ${_vekil_env_host#*::} != *::* ]] || _vekil_env_valid=0
          _vekil_env_left=${_vekil_env_host%%::*}
          _vekil_env_right=${_vekil_env_host#*::}
          _vekil_env_parts=("${(@s/:/)_vekil_env_left}" "${(@s/:/)_vekil_env_right}")
          for _vekil_env_part in $_vekil_env_parts; do
            [[ -z $_vekil_env_part ]] && continue
            if [[ $_vekil_env_part != [0-9A-Fa-f](#c1,4) ]]; then
              _vekil_env_valid=0
              break
            fi
            (( _vekil_env_count += 1 ))
          done
          (( _vekil_env_count < 8 )) || _vekil_env_valid=0
        else
          _vekil_env_parts=("${(@s/:/)_vekil_env_host}")
          (( ${#_vekil_env_parts} == 8 )) || _vekil_env_valid=0
          for _vekil_env_part in $_vekil_env_parts; do
            if [[ $_vekil_env_part != [0-9A-Fa-f](#c1,4) ]]; then
              _vekil_env_valid=0
              break
            fi
          done
        fi
      elif (( ${#_vekil_env_host} <= 253 )) && [[ $_vekil_env_host != .* && $_vekil_env_host != *. && $_vekil_env_host != *..* ]]; then
        _vekil_env_parts=("${(@s:.:)_vekil_env_host}")
        _vekil_env_valid=1
        for _vekil_env_part in $_vekil_env_parts; do
          if (( ${#_vekil_env_part} > 63 )) || [[ ! $_vekil_env_part =~ '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' ]]; then
            _vekil_env_valid=0
            break
          fi
        done
      fi
      (( _vekil_env_valid )) || return 1
    fi

    if [[ $_vekil_env_host == *:* ]]; then
      _vekil_env_url_host=[$_vekil_env_host]
    else
      _vekil_env_url_host=$_vekil_env_host
    fi
    command -v curl >/dev/null 2>&1 || return 1
    command curl --fail --silent --show-error \
      --connect-timeout 0.5 --max-time 1 \
      "http://${_vekil_env_url_host}:${_vekil_env_port}/readyz" >/dev/null 2>&1 || return 1
    return 0
  }; then
    if [[ -n ${VEKIL_MANAGED_OPENAI_BASE_URL:-} ]]; then
      unset OPENAI_BASE_URL VEKIL_MANAGED_OPENAI_BASE_URL
    fi
    if [[ -n ${VEKIL_MANAGED_OPENAI_API_KEY:-} ]]; then
      unset OPENAI_API_KEY VEKIL_MANAGED_OPENAI_API_KEY
    fi
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_BASE_URL:-} ]]; then
      unset ANTHROPIC_BASE_URL VEKIL_MANAGED_ANTHROPIC_BASE_URL
    fi
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_API_KEY:-} ]]; then
      unset ANTHROPIC_API_KEY VEKIL_MANAGED_ANTHROPIC_API_KEY
    fi
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_MODEL:-} ]]; then
      unset ANTHROPIC_MODEL VEKIL_MANAGED_ANTHROPIC_MODEL
    fi
    return 0
  fi

  if [[ -n ${VEKIL_MANAGED_OPENAI_BASE_URL:-} || ! -v OPENAI_BASE_URL ]]; then
    export OPENAI_BASE_URL="http://${_vekil_env_url_host}:${_vekil_env_port}/v1"
    export VEKIL_MANAGED_OPENAI_BASE_URL=$OPENAI_BASE_URL
    _vekil_env_openai_managed=1
  fi

  if (( _vekil_env_openai_managed )); then
    if [[ -n ${VEKIL_MANAGED_OPENAI_API_KEY:-} || -z ${OPENAI_API_KEY:-} ]]; then
      export OPENAI_API_KEY=dummy
      export VEKIL_MANAGED_OPENAI_API_KEY=$OPENAI_API_KEY
    fi
  elif [[ -n ${VEKIL_MANAGED_OPENAI_API_KEY:-} ]]; then
    unset OPENAI_API_KEY VEKIL_MANAGED_OPENAI_API_KEY
  fi

  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_BASE_URL:-} || ! -v ANTHROPIC_BASE_URL ]]; then
    export ANTHROPIC_BASE_URL="http://${_vekil_env_url_host}:${_vekil_env_port}"
    export VEKIL_MANAGED_ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL
    _vekil_env_anthropic_managed=1
    unset ANTHROPIC_AUTH_TOKEN
  fi

  if (( _vekil_env_anthropic_managed )); then
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_API_KEY:-} || -z ${ANTHROPIC_API_KEY:-} ]]; then
      export ANTHROPIC_API_KEY=dummy
      export VEKIL_MANAGED_ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
    fi
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_MODEL:-} || ! -v ANTHROPIC_MODEL ]]; then
      export ANTHROPIC_MODEL=claude-opus-4.8
      export VEKIL_MANAGED_ANTHROPIC_MODEL=$ANTHROPIC_MODEL
    fi
  else
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_API_KEY:-} ]]; then
      unset ANTHROPIC_API_KEY VEKIL_MANAGED_ANTHROPIC_API_KEY
    fi
    if [[ -n ${VEKIL_MANAGED_ANTHROPIC_MODEL:-} ]]; then
      unset ANTHROPIC_MODEL VEKIL_MANAGED_ANTHROPIC_MODEL
    fi
  fi

  if (( ! ${+functions[codex]} )) || [[ ${VEKIL_MANAGED_CODEX_FUNCTION:-0} == 1 ]]; then
    function codex {
      if [[ -n ${VEKIL_MANAGED_OPENAI_BASE_URL:-} ]]; then
        command codex -c "openai_base_url=\"${VEKIL_MANAGED_OPENAI_BASE_URL}\"" "$@"
      else
        command codex "$@"
      fi
    }
    typeset -g VEKIL_MANAGED_CODEX_FUNCTION=1
  fi

  return 0
}
