#!/usr/bin/env bash
# Smoke checks rápidos post-instalación de Falco. Para pruebas end-to-end
# (disparar una alerta real, validar Network Policies) ver tests/smoke-tests.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

echo "== Pods en namespace falco =="
kubectl -n falco get pods -o wide

echo ""
echo "== DaemonSet de Falco (debe correr en todos los nodos) =="
kubectl -n falco get daemonset falco

echo ""
echo "== Falcosidekick =="
kubectl -n falco get deployment falco-falcosidekick falco-falcosidekick-ui

echo ""
echo "== Confirmar que las 21 reglas custom cargaron sin error =="
kubectl -n falco logs daemonset/falco | grep -i "falco-rules-custom" || \
  echo "(no se encontró la línea de carga; revisar: kubectl -n falco logs daemonset/falco | grep -i 'Loading rules')"
