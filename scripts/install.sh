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
  # No hay Cilium. Identificamos si hay ALGÚN OTRO CNI corriendo para dar un
  # mensaje específico - no todos los CNI se comportan igual con respecto a
  # NetworkPolicy (Flannel la ignora; Calico/Weave/etc. sí la implementan).
  other_cni=$(kubectl get daemonset -A --no-headers 2>/dev/null \
    | grep -Eio 'flannel|calico-node|calico|weave-net|kube-router|antrea-agent' \
    | sort -u | head -1 || true)

  case "$other_cni" in
    flannel)
      echo "Aviso: se detectó Flannel como CNI."
      echo "  Flannel NO implementa la API de NetworkPolicy: los manifiestos de"
      echo "  este proyecto se van a aceptar pero NO se van a aplicar, sin ningún"
      echo "  error visible (la 'brecha residual' que se declara en docs/architecture.md)."
      echo "  Falco funciona igual (no depende del CNI)."
      echo "  Recomendado: migrar a Cilium antes de continuar - ver docs/installation.md"
      echo "  -> Prerrequisitos, o el repo k8s-ansible del equipo como referencia."
      echo "  Este script NO lo hace automático a propósito: migrar el CNI de un"
      echo "  clúster en uso puede causar una interrupción de red real, y requiere"
      echo "  acceso SSH a los nodos (para ajustar firewall) que install.sh no tiene."
      ;;
    calico-node|calico|weave-net|kube-router|antrea-agent)
      echo "Aviso: se detectó '${other_cni}' como CNI (no Cilium)."
      echo "  Falco funciona igual. Las Network Policies deberían funcionar bien"
      echo "  ('${other_cni}' sí implementa la API de NetworkPolicy)."
      echo "  Lo único que no vas a tener es el dashboard de Hubble UI (es específico"
      echo "  de Cilium). Si lo quieres, tendrías que migrar a Cilium primero - ver"
      echo "  docs/installation.md -> Prerrequisitos."
      ;;
    *)
      echo "Aviso: no se detectó ningún CNI instalado (ni Cilium ni otro conocido)."
      echo "  Sin un CNI, varios pods no van a poder arrancar y las Network Policies"
      echo "  no tienen nada que las aplique."
      echo "  Instala un CNI antes de continuar - recomendamos Cilium (ver"
      echo "  docs/installation.md -> Prerrequisitos, o el repo k8s-ansible)."
      ;;
  esac
fi

echo ""

if ! command -v helm >/dev/null 2>&1; then
  echo "Instalando Helm..."
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  # El propio get_helm.sh se autoverifica al final usando el $PATH restringido
  # de sudo (que en Rocky/RHEL no incluye /usr/local/bin) y puede reportar
  # error aunque la instalación sí haya funcionado. Por eso no confiamos en
  # su código de salida (|| true) y verificamos nosotros mismos, con NUESTRO
  # propio $PATH, justo después.
  sudo /tmp/get_helm.sh || true
  if ! command -v helm >/dev/null 2>&1; then
    echo "Error: Helm no quedó disponible en el PATH después de instalarlo." >&2
    echo "Revisa que /usr/local/bin esté en tu \$PATH y vuelve a correr este script." >&2
    exit 1
  fi
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
