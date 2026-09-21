#!/usr/bin/env bash
# Instala Falco + Falcosidekick (+ UI) en el clúster vía Helm.
# Requiere kubectl/helm con acceso al clúster (ver .env.example -> KUBECONFIG
# si corres esto con un usuario del sistema distinto al que provisionó el
# clúster con Ansible).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

: "${FALCO_SLACK_WEBHOOK_URL:?Falta FALCO_SLACK_WEBHOOK_URL. Copia .env.example a .env y complétalo.}"

echo "== Verificando prerrequisitos del clúster =="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl no está instalado o no está en el PATH." >&2
  exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Error: kubectl no puede conectarse al clúster." >&2
  echo "Revisa tu kubeconfig (o define KUBECONFIG en .env - ver .env.example)." >&2
  exit 1
fi
echo "kubectl OK. Nodos:"
kubectl get nodes

if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  echo "Cilium detectado."
  if kubectl -n kube-system get svc hubble-relay >/dev/null 2>&1; then
    echo "Hubble detectado (dashboard de red disponible al final de la instalación)."
  else
    echo "Aviso: Cilium está pero Hubble no parece habilitado."
    echo "  Falco y Network Policies van a funcionar igual; para el mapa de red en vivo:"
    echo "  cilium hubble enable --ui"
  fi
else
  echo "Aviso: no se detectó Cilium (DaemonSet 'cilium' en kube-system)."
  echo "  Falco funciona con cualquier CNI (no depende de la red)."
  echo "  Las Network Policies funcionan con cualquier CNI que implemente la API"
  echo "  NetworkPolicy (Calico, Weave, el propio Cilium, etc. - NO con Flannel solo)."
  echo "  Sin Cilium específicamente, no vas a tener el dashboard de Hubble UI."
  echo "  Ver docs/installation.md -> Prerrequisitos."
fi

echo ""

if ! command -v helm >/dev/null 2>&1; then
  echo "Instalando Helm..."
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  sudo /tmp/get_helm.sh
fi

helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update falcosecurity

kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  -f helm/chart/values.yaml \
  --set falcosidekick.config.slack.webhookurl="${FALCO_SLACK_WEBHOOK_URL}"

echo "Esperando a que Falco y Falcosidekick estén listos..."
kubectl -n falco rollout status daemonset/falco --timeout=180s
kubectl -n falco rollout status deployment/falco-falcosidekick --timeout=120s
kubectl -n falco rollout status deployment/falco-falcosidekick-ui --timeout=120s

echo ""
echo "Listo. Pods en el namespace falco:"
kubectl -n falco get pods -o wide

echo ""
echo "== Exponiendo dashboards permanentemente (NodePort, sin port-forward) =="

# Fija un NodePort en el Service, leyendo port/targetPort reales (no se
# asumen, se descubren) para no romper el Service si el chart cambia.
expose_nodeport() {
  local ns="$1" svc="$2" node_port="$3" port targetPort
  port=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')
  targetPort=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].targetPort}')
  kubectl -n "$ns" patch svc "$svc" --type merge \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http\",\"port\":${port},\"targetPort\":${targetPort},\"nodePort\":${node_port}}]}}"
}

expose_nodeport falco falco-falcosidekick-ui 30280

if kubectl -n kube-system get svc hubble-ui >/dev/null 2>&1; then
  expose_nodeport kube-system hubble-ui 30281
else
  echo "Hubble UI no está instalado todavía. Instálalo desde el nodo master con:"
  echo "  cilium hubble enable --ui"
  echo "y vuelve a correr este script para exponerlo."
fi

echo ""
echo "Dashboards disponibles en cualquier momento, desde cualquier IP de nodo:"
echo "  Falcosidekick UI: http://<IP-de-cualquier-nodo>:30280  (usuario/clave: admin/admin, cámbialo)"
echo "  Hubble UI:        http://<IP-de-cualquier-nodo>:30281"

echo ""
echo "== Desplegando app de demo (frontend/backend/database) y Network Policies =="
kubectl apply -f manifests/namespaces.yaml
kubectl apply -f manifests/configmap.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml

kubectl -n frontend rollout status deployment/frontend --timeout=120s
kubectl -n backend rollout status deployment/backend --timeout=120s
kubectl -n database rollout status deployment/database --timeout=120s

kubectl apply -f manifests/network-policies/

echo ""
echo "Listo. Pods en frontend/backend/database:"
kubectl -n frontend get pods -o wide
kubectl -n backend get pods -o wide
kubectl -n database get pods -o wide
