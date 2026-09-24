# Instalación

## Prerrequisitos

Este proyecto asume que **ya tienes un clúster de Kubernetes funcionando** —
no importa cómo lo hayas provisionado (kubeadm a mano, Ansible, un servicio
administrado, `kind`, etc.) ni cuántos nodos tenga. Todo lo que hacen estos
scripts pasa por `kubectl`/`helm`, nunca por SSH ni por el sistema operativo
de los nodos.

**Obligatorio:**

1. `kubectl` configurado y funcionando contra tu clúster (`kubectl get nodes`
   debe funcionar). Si necesitas apuntar a un `kubeconfig` distinto del
   default de tu usuario, ver `.env.example` (`KUBECONFIG`).
2. Un CNI que implemente la API estándar de `NetworkPolicy` de Kubernetes.
   La mayoría lo hacen (Cilium, Calico, Weave...) — la excepción notoria es
   **Flannel solo**, que acepta el manifiesto de `NetworkPolicy` pero no lo
   aplica (queda "aceptado pero ignorado", sin error visible).
3. Helm 3 — si no lo tienes, `scripts/install.sh` lo instala automáticamente
   (necesita `sudo`).
4. Permisos suficientes en el clúster (idealmente `cluster-admin`) para crear
   namespaces, DaemonSets y NetworkPolicies.

**Opcional (recomendado):**

5. **Cilium específicamente**, con **Hubble** habilitado
   (`cilium hubble enable --ui`). Esto NO es necesario para que Falco o las
   Network Policies funcionen — es necesario únicamente para el dashboard de
   Hubble UI (mapa de red en vivo). Si tu clúster usa otro CNI, todo lo
   demás funciona igual; simplemente no vas a tener esa visualización.

`scripts/install.sh` verifica estos puntos automáticamente al arrancar y te
avisa con un mensaje claro si falta algo.

Si estás construyendo el clúster desde cero y quieres un ejemplo ya probado
que cumple todos los prerrequisitos (incluido Cilium+Hubble), pueden usar el
repo `k8s-ansible` del equipo — es un ejemplo de referencia, no una
dependencia de este proyecto.

## Pasos

```bash
git clone git@github.com:Rixde/proyecto-equipo-4.git
cd proyecto-equipo-4

cp .env.example .env
# Editar .env: FALCO_SLACK_WEBHOOK_URL (obligatorio), KUBECONFIG (opcional)

./scripts/install.sh
```

Esto instala Falco + Falcosidekick (con las 21 reglas custom), expone los
dashboards de Falcosidekick UI y Hubble UI como `NodePort` permanente
(`:30280` y `:30281`), y despliega la app de demo de 3 capas
(`frontend`/`backend`/`database`) con sus Network Policies.

## Verificación

```bash
./tests/smoke-tests.sh        # valida las Network Policies (permitido/bloqueado)
./scripts/test.sh             # confirma que Falco y las 21 reglas cargaron
./tests/alerts/01-shell.sh    # dispara una alerta de prueba
```

## Desinstalar

```bash
./scripts/cleanup.sh
```
