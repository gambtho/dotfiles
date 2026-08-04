# Guard: only load when work profile is active
[[ -z "$WORK_PROFILE" ]] && return

export PATH=$PATH:$GOPATH/src/goms.io/aks/rp/bin
export PATH=$PATH:$HOME/bin
export PATH=$PATH:$HOME/.local/bin
# kubectl plugins installed by work/install.sh live here, not on the system path.
export PATH=${KREW_ROOT:-$HOME/.krew}/bin:$PATH
