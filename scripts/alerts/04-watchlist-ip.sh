#!/usr/bin/env bash
# Dispara UNA sola alerta: "Conexión hacia IP en lista de vigilancia"
# (T1071, Command & Control). Simula un contenedor comprometido "llamando
# a casa" hacia una IP marcada como sospechosa (8.8.8.8, definida en
# helm/chart/values.yaml -> watchlist_ips).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_env.sh"
kubectl get pod test-shell >/dev/null 2>&1 || kubectl run test-shell --image=alpine --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-shell --timeout=60s >/dev/null

echo "Conectando hacia 8.8.8.8 (IP en lista de vigilancia)..."
kubectl exec test-shell -- wget -T 2 -q -O /dev/null http://8.8.8.8 || true
echo "Listo. Revisa Slack / Falcosidekick UI."
