#!/usr/bin/env bash
# Pruebas de conectividad para validar las Network Policies (Fase 3).
# OJO: no usa 'set -e' porque las pruebas "deny" DEBEN fallar - ese es el
# resultado correcto. Si Cilium no implementara NetworkPolicy, estas pruebas
# fallarían (el tráfico bloqueado pasaría igual) y quedaría en evidencia.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/_env.sh"

pass=0
fail=0

check() {
  local desc="$1" expected="$2"
  shift 2
  if "$@" >/tmp/netpol-test-out 2>&1; then
    result="allow"
  else
    result="deny"
  fi
  if [ "$result" = "$expected" ]; then
    echo "OK   [$expected] $desc"
    pass=$((pass + 1))
  else
    echo "FAIL [esperaba $expected, obtuve $result] $desc"
    echo "     salida: $(tail -1 /tmp/netpol-test-out)"
    fail=$((fail + 1))
  fi
}

echo "== 1. Flujo permitido: frontend -> backend:80 =="
check "frontend puede llegar a backend" allow \
  kubectl exec -n frontend deploy/frontend -- wget -T 3 -q -O - http://backend.backend.svc.cluster.local

echo ""
echo "== 2. Flujo permitido: backend -> database:80 =="
check "backend puede llegar a database" allow \
  kubectl exec -n backend deploy/backend -- wget -T 3 -q -O - http://database.database.svc.cluster.local

echo ""
echo "== 3. Flujo bloqueado (transitivo): frontend -> database:80 =="
check "frontend NO debe llegar a database directamente" deny \
  kubectl exec -n frontend deploy/frontend -- wget -T 3 -q -O - http://database.database.svc.cluster.local

echo ""
echo "== 4. Flujo bloqueado: frontend -> internet =="
check "frontend NO debe salir a internet" deny \
  kubectl exec -n frontend deploy/frontend -- wget -T 3 -q -O - http://example.com

echo ""
echo "== 5. Flujo bloqueado: namespace ajeno (default) -> backend =="
check "un pod fuera de frontend NO debe llegar a backend" deny \
  kubectl run netpol-test --image=busybox:1.36 -n default --restart=Never --rm -i --command \
    -- wget -T 3 -q -O - http://backend.backend.svc.cluster.local

echo ""
echo "== 6. Flujo bloqueado: namespace ajeno (default) -> database =="
check "un pod fuera de backend NO debe llegar a database" deny \
  kubectl run netpol-test2 --image=busybox:1.36 -n default --restart=Never --rm -i --command \
    -- wget -T 3 -q -O - http://database.database.svc.cluster.local

echo ""
echo "== Resultado: $pass OK, $fail FAIL =="
rm -f /tmp/netpol-test-out
[ "$fail" -eq 0 ]
