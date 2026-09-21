#!/usr/bin/env bash
# Dispara UNA sola alerta: "Shell spawneada en contenedor" (T1059, Execution).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_env.sh"
kubectl get pod test-shell >/dev/null 2>&1 || kubectl run test-shell --image=alpine --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-shell --timeout=60s >/dev/null

echo "Abriendo una shell dentro del contenedor..."
kubectl exec test-shell -- sh -c 'true'
echo "Listo. Revisa Slack / Falcosidekick UI."
