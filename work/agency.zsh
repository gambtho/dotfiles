[[ -n ${WORK_PROFILE:-} ]] || return

typeset agency_dir="$HOME/.config/agency/CurrentVersion"
if [[ ":$PATH:" != *":$agency_dir:"* ]]; then
  export PATH="$agency_dir:$PATH"
fi
unset agency_dir
