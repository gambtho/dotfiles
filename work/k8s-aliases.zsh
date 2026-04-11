# Guard: only load when work profile is active
[[ -z "$WORK_PROFILE" ]] && return

# AKS namespace shortcuts (Azure-specific namespaces)
alias kneg='kubectl -n eventgrid'
alias kncs='kubectl -n containerservice'
alias kncsa='kubectl -n containerservicei-async'

# AKS prod tools aliases — only loaded with work profile
alias aks='aks-prod-tools'
alias as='aks-prod-tools ssh'
alias ak='aks-prod-tools kubectl'
alias akg='aks-prod-tools kubectl -c $c && kubectl cluster-info && kubectl get nodes'
alias akge='aks-prod-tools kubectl -c $c -p env && kubectl cluster-info && kubectl get nodes'
alias klies="k get po --all-namespaces -o json | jq -r '.items[] | select(.status.phase != \"Running\" or ([ .status.conditions[] | select(.type == \"Ready\" and .status == \"False\") ] | length ) == 1 ) | \"k -n \" + .metadata.namespace + \" delete po \" + .metadata.name'"
alias kexec="aks-prod-tools ssh -c $c --exec "
alias hcp='hcpdebug debug -e prod -p bash'
alias ksn0='k scale --replicas=0 -n infra deployment/underlay-nanny'
alias ksn3='k scale --replicas=3 -n infra deployment/underlay-nanny'
alias keml='aks ssh -c $c -i 0 --exec "sudo etcdctl member list"'
alias aa='aks-prod-tools kubectl -c $c && kubectl cluster-info'
alias ss='knl edit deploy linkerd-proxy-injector'
alias dd='knl edit deploy linkerd-destination'
alias ff='kubectl -n linkerd get po'
alias fixit="rm -rf ~/.azure/* && az login -o none"

function icm {
  if [[ -z "${1}" ]]; then
    echo -e "Enter full ICM title string: \c"
    read var
    eval "set -- '${var}'"
  fi

  words=("${(@s: :)1}")
  incident=""
  cluster=""
  component=""
  node=""
  n=""
  c=""

  for word in "${words[@]}"; do
    if [[ "$word" =~ ^[0-9]+$ ]]; then
      incident=$word
    elif [[ "$word" == *"/"* ]]; then
      cluster="${word%%/*}"
      c="${word%%/*}"
      raw_component="${word#*/}"
      if [[ "$raw_component" == k8s-* ]]; then
        node="$raw_component"
        n="$raw_component"
      else
        component="$raw_component"
      fi
    fi
  done

  if [[ -n "$incident" ]]; then typeset -g incident_global="${incident}"; else unset incident_global; fi
  if [[ -n "$cluster" ]]; then typeset -g cluster_global="${cluster}"; else unset cluster_global; fi
  if [[ -n "$component" ]]; then typeset -g component_global="${component}"; else unset component_global; fi
  if [[ -n "$node" ]]; then typeset -g node_global="${node}"; else unset node_global; fi

  [[ -n "$incident" ]] && echo "incident=$incident"
  [[ -n "$cluster" ]] && echo "cluster=$c"
  [[ -n "$component" ]] && echo "component=$component"
  [[ -n "$node" ]] && echo "node=$node"

  if [[ -n "$cluster" ]]; then
    aks-prod-tools kubectl -c "$cluster"
  fi
}
