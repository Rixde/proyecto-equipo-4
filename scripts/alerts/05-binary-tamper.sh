#!/usr/bin/env bash
# Dispara UNA sola alerta: "Modificación de binario crítico" (T1222,
# Persistence). Simula reemplazar un binario del sistema (ej. sshd) -
# técnica clásica de backdoor. Apunta a /usr/sbin/sshd porque NO existe en
# la imagen base de Alpine: se crea sin corromper ningún binario real que
# el contenedor necesite (a diferencia de /bin/sh, que es symlink de
# busybox y rompería el pod si se sobreescribe).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_env.sh"
kubectl get pod test-shell >/dev/null 2>&1 || kubectl run test-shell --image=alpine --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-shell --timeout=60s >/dev/null

echo "Escribiendo sobre /usr/sbin/sshd (binario en la lista de vigilancia)..."
kubectl exec test-shell -- sh -c 'echo test > /usr/sbin/sshd'
echo "Listo. Revisa Slack / Falcosidekick UI."
