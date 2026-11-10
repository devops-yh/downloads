az vm list-usage --location koreacentral --query "[?contains(name.value, 'NC') && (contains(name.value, 'H100') || contains(name.value, 'A100'))].{Name:name.localizedValue, Current:currentValue, Limit:limit}" -o table

az vm list-usage --location koreacentral --query "[?name.value=='standardNCadsH100v5Family' || name.value=='standardNCADSA100v4Family'].{Name:name.localizedValue, Current:currentValue, Limit:limit}" -o table

az vm list-usage --location koreacentral --query "[?contains(name.localizedValue, 'H100') || contains(name.localizedValue, 'A100')].{Name:name.localizedValue, Current:currentValue, Limit:limit}" -o table


#!/bin/bash
# aks-watch_v2.sh
# 사용법: ./aks-watch_v2.sh [컨텍스트1 컨텍스트2 ...]
# 인자가 없으면 CONTEXTS_DEFAULT, 그것도 비어 있으면 kubeconfig의 모든 컨텍스트를 대상으로 합니다.

INTERVAL=${INTERVAL:-1}
CONTEXTS_DEFAULT=""   # 예: "aks-dev aks-stg aks-prod"
CONTEXTS="$*"
[ -z "$CONTEXTS" ] && CONTEXTS="$CONTEXTS_DEFAULT"
[ -z "$CONTEXTS" ] && CONTEXTS=$(kubectl config get-contexts -o name)

while true; do
  clear
  echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')  (interval ${INTERVAL}s, Ctrl+C 종료)"
  for ctx in $CONTEXTS; do
    echo
    echo "=================== $ctx ==================="
    echo "[Nodes]"
    kubectl --context "$ctx" --request-timeout=5s get nodes -L agentpool 2>&1
    echo
    echo "[Non-Running Pods]"
    out=$(kubectl --context "$ctx" --request-timeout=5s get pods -A --no-headers 2>&1)
    if echo "$out" | grep -qiE "^(error|Unable|The connection)"; then
      echo "$out"
    else
      echo "$out" | awk '$4!="Running" && $4!="Completed"' | grep . || echo "(없음)"
    fi
  done
  sleep "$INTERVAL"
done
