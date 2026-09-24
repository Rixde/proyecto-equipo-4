#!/usr/bin/env bash
# Dispara, una por una y en el mismo orden que helm/chart/values.yaml, las
# 21 reglas custom de Falco - para verlas en vivo en Slack y en el
# dashboard de Falcosidekick UI mientras corre.
#
# No es un test de pass/fail (Falco es asíncrono: alertar puede tardar uno o
# dos segundos). Es una demo controlada. Para Network Policies ver
# tests/smoke-tests.sh.
#
# Nota de seguridad del propio script: la regla "Modificación de binario
# crítico" NO se dispara escribiendo sobre /bin/sh o /bin/busybox real (en
# Alpine son symlinks al mismo binario: corromperlo rompería TODOS los
# comandos siguientes del script, incluido este mismo). Se apunta a
# /usr/sbin/sshd, que no existe en la imagen base y por lo tanto se crea sin
# afectar nada.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/_env.sh"

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

step() {
  echo ""
  echo "=== $1 ==="
  sleep 1
}

echo "Preparando pods de prueba (se borran al final del script)..."
kubectl delete pod test-shell test-priv test-cap test-hostpath --ignore-not-found >/dev/null 2>&1

kubectl run test-shell --image=alpine --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-shell --timeout=60s

echo "Instalando herramientas necesarias para las demos (nmap, python3, unshare)..."
kubectl exec test-shell -- sh -c 'apk add --no-cache nmap python3 util-linux >/dev/null 2>&1'

step "1. Shell spawneada en contenedor"
kubectl exec test-shell -- sh -c 'true'

step "2. Herramienta de reconocimiento ejecutada (nmap)"
kubectl exec test-shell -- sh -c 'nmap -p 80 127.0.0.1 >/dev/null 2>&1' || true

step "3. Herramienta de transferencia de red sospechosa (wget)"
kubectl exec test-shell -- wget -T 2 -q -O /dev/null http://example.com || true

step "4. Ejecución de binario desde directorio temporal"
kubectl exec test-shell -- sh -c 'cp /bin/busybox /tmp/evil && /tmp/evil true'

step "5. Uso de sudo o su en contenedor"
timeout 10 kubectl exec test-shell -- sh -c 'su - root -c true' || true

step "6. Cambio inesperado de UID a root (setuid)"
kubectl exec test-shell -- python3 -c 'import os; os.setuid(0)'

step "7. Contenedor privilegiado iniciado"
kubectl run test-priv --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test-priv","image":"alpine","command":["sleep","3600"],"securityContext":{"privileged":true}}]}}'
kubectl wait --for=condition=Ready pod/test-priv --timeout=60s

step "8. Uso de capability peligrosa (CAP_SYS_ADMIN)"
kubectl run test-cap --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test-cap","image":"alpine","command":["sleep","3600"],"securityContext":{"capabilities":{"add":["SYS_ADMIN"]}}}]}}'
kubectl wait --for=condition=Ready pod/test-cap --timeout=60s
kubectl exec test-cap -- true

step "9. Manipulación de namespaces de Linux (unshare)"
timeout 10 kubectl exec test-shell -- unshare --uts true || true

step "10. Acceso a filesystem del host"
kubectl run test-hostpath --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test-hostpath","image":"alpine","command":["sleep","3600"],"volumeMounts":[{"name":"hostroot","mountPath":"/host"}]}],"volumes":[{"name":"hostroot","hostPath":{"path":"/"}}]}}'
kubectl wait --for=condition=Ready pod/test-hostpath --timeout=60s
kubectl exec test-hostpath -- ls /host/etc >/dev/null

step "11. Escritura en directorio del sistema (/etc)"
kubectl exec test-shell -- sh -c 'echo test > /etc/malicious-test.txt'

step "12. Modificación de binario crítico (escritura, en /usr/sbin/sshd - no existe en la imagen base, se crea sin romper nada)"
kubectl exec test-shell -- sh -c 'echo test > /usr/sbin/sshd'

step "13. Modificación de binario del sistema (chmod, solo cambia permisos - no corrompe el contenido)"
kubectl exec test-shell -- chmod 777 /bin/busybox

step "14. Modificación de configuración de cron"
kubectl exec test-shell -- sh -c "mkdir -p /var/spool/cron/crontabs && echo '* * * * * echo hi' > /var/spool/cron/crontabs/root"

step "15. Gestión de usuarios dentro de un contenedor (adduser)"
kubectl exec test-shell -- adduser -D testuser

step "16. Lectura de archivo de credenciales (/etc/shadow)"
kubectl exec test-shell -- cat /etc/shadow >/dev/null

step "17. Acceso a token de ServiceAccount"
kubectl exec test-shell -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null

step "18. Conexión saliente a puerto inusual (NodePort 30280 de nuestro propio clúster)"
kubectl exec test-shell -- wget -T 2 -q -O /dev/null "http://${NODE_IP}:30280" || true

step "19. Conexión hacia IP en lista de vigilancia (8.8.8.8)"
kubectl exec test-shell -- wget -T 2 -q -O /dev/null http://8.8.8.8 || true

step "20. Conexión a puerto típico de minería de criptomonedas"
kubectl exec test-shell -- nc -w2 -z "${NODE_IP}" 3333 || true

step "21. Posible borrado de logs del sistema"
kubectl exec test-shell -- sh -c "mkdir -p /var/log && touch /var/log/testlog.log && rm /var/log/testlog.log"

echo ""
echo "=== Listo. Revisa las 21 alertas en: ==="
echo "  Slack (todas nuestras reglas son WARNING o más severas, así que las 21 deberían notificar)"
echo "  Falcosidekick UI: http://${NODE_IP}:30280"
echo "  o en crudo: kubectl -n falco logs daemonset/falco | tail -80"

echo ""
echo "Limpiando pods de prueba..."
kubectl delete pod test-shell test-priv test-cap test-hostpath --ignore-not-found
