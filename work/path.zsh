# Guard: only load when work profile is active
[[ -z "$WORK_PROFILE" ]] && return

export PATH=$PATH:$GOPATH/src/goms.io/aks/rp/bin
export PATH=$PATH:$HOME/bin
export PATH=$PATH:$HOME/.local/bin
