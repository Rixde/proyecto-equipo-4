# Cargado (source) por los demás scripts - no se ejecuta solo.
# Centraliza: ubicar la raíz del proyecto y cargar .env, para que TODOS los
# scripts (no solo install.sh) respeten las mismas variables, sin importar
# con qué usuario del sistema operativo se estén corriendo.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# KUBECONFIG es opcional: si no se define, kubectl/helm usan su default
# (~/.kube/config del usuario que corre el script). Se define en .env solo
# si quieres apuntar a un kubeconfig distinto del default de tu usuario -
# por ejemplo, si el clúster se provisionó con Ansible usando otro usuario
# (ver .env.example).
if [ -n "${KUBECONFIG:-}" ]; then
  if [ ! -f "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG=$KUBECONFIG (definido en .env) no existe." >&2
    exit 1
  fi
  export KUBECONFIG
fi
