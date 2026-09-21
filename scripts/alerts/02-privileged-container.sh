#!/usr/bin/env bash
# Dispara UNA sola alerta: "Contenedor privilegiado iniciado" (T1610,
# Privilege Escalation). Se dispara al CREAR el contenedor (evt.type=
# container), así que cada corrida borra y vuelve a crear el pod para
# poder re-disparar la alerta.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_env.sh"
kubectl delete pod test-priv --ignore-not-found >/dev/null 2>&1

echo "Creando un contenedor con securityContext.privileged=true..."
kubectl run test-priv --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test-priv","image":"alpine","command":["sleep","3600"],"securityContext":{"privileged":true}}]}}'
echo "Listo. Revisa Slack / Falcosidekick UI."
