#!/usr/bin/env bash
# Dispara UNA sola alerta: "Acceso a token de ServiceAccount" (T1552,
# Credential Access).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_env.sh"
kubectl get pod test-shell >/dev/null 2>&1 || kubectl run test-shell --image=alpine --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-shell --timeout=60s >/dev/null

echo "Leyendo el token de ServiceAccount montado en el pod..."
kubectl exec test-shell -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
echo "Listo. Revisa Slack / Falcosidekick UI."
