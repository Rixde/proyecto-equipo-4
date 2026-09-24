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
repo [`k8s-cilium-ansible`](https://github.com/Rixde/k8s-cilium-ansible.git)
del equipo — es un ejemplo de referencia, no una dependencia de este proyecto.

## Configurar acceso a `kubectl`

Confirma primero que `kubectl` ya funciona con tu usuario actual:

```bash
kubectl get nodes
```

- Si ves tus nodos → tu `kubectl` ya está listo, salta directo a
  [Crear el webhook de Slack](#crear-el-webhook-de-slack).
- Si falla (por ejemplo, `kubectl` no encuentra ningún clúster) → sigue los
  pasos de abajo. Esto pasa normalmente cuando corres los scripts con un
  usuario del sistema **distinto** al que provisionó el clúster (por
  ejemplo, Ansible usó el usuario `ansible`, y tú estás en `root` u otro).

La fuente de verdad de cualquier clúster `kubeadm` es `/etc/kubernetes/admin.conf`
(propiedad de `root`, pero legible con `sudo`). Cópialo a tu propio usuario:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config-k8s
sudo chown $(id -u):$(id -g) ~/.kube/config-k8s
chmod 600 ~/.kube/config-k8s

# Verifica que funciona ANTES de seguir:
KUBECONFIG=~/.kube/config-k8s kubectl get nodes
```

*(Se usa el nombre `config-k8s`, distinto de `~/.kube/config`, para no pisar
un `kubeconfig` que ya tengas ahí de otro clúster.)*

Si ese último comando muestra tus nodos, ya tienes lo que necesitas para el
paso `KUBECONFIG` de `.env` más abajo. Si falla ahí, el problema es el acceso
al clúster — resuélvelo antes de continuar, porque `scripts/install.sh`
fallaría por la misma razón.

## Crear el webhook de Slack

Falcosidekick necesita una URL de webhook para poder notificar a Slack. Se
crea una vez, manualmente (no es automatizable por script):

1. Si no tienes un workspace de Slack para esto, crea uno gratis en
   [slack.com/get-started](https://slack.com/get-started) y crea un canal,
   por ejemplo `#falco-alerts`.
2. Entra a [api.slack.com/apps](https://api.slack.com/apps) → **Create New
   App** → **From scratch**.
3. Ponle un nombre (por ejemplo "Falco Alerts") y selecciona tu workspace.
4. En el menú lateral, entra a **Incoming Webhooks** y actívalo (toggle a
   *On*).
5. Baja y haz clic en **Add New Webhook to Workspace** → elige el canal
   destino (`#falco-alerts`) → **Allow**.
6. Slack te da una URL con esta forma:
   ```
   https://hooks.slack.com/services/T000.../B000.../XXXXXXXX
   ```
   Esa es tu `FALCO_SLACK_WEBHOOK_URL`. Guárdala para el siguiente paso —
   **nunca la pegues en un archivo que se vaya a subir a git**, va en `.env`
   (ver `.gitignore`).

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

## Probar las alertas y el mapa de tráfico de red

Primero, confirma que Falco y las 21 reglas custom cargaron sin error:

```bash
./scripts/test.sh
```

### Alertas de Falco (Slack + Falcosidekick UI)

Abre en el navegador el dashboard de Falcosidekick UI
(`http://<IP-de-cualquier-nodo>:30280`) y tu canal de Slack **antes** de
disparar nada, para verlas llegar en vivo.

- **Una alerta puntual** (para una demo controlada o para reproducir un
  incidente específico):
  ```bash
  ./tests/alerts/01-shell.sh          # shell interactiva en un contenedor
  ./tests/alerts/02-privileged-container.sh
  ./tests/alerts/03-sa-token-access.sh
  ./tests/alerts/04-watchlist-ip.sh
  ./tests/alerts/05-binary-tamper.sh
  ```
  Cada uno dispara **una sola** alerta, sin ruido — puedes correrlos varias
  veces seguidas.
- **Las 21 reglas en orden**, como demo completa:
  ```bash
  ./tests/trigger-alerts.sh
  ```
  Tarda 1-2 minutos y limpia los pods de prueba al terminar.

### Network Policies y mapa de tráfico (Hubble UI)

> ⚠️ Si tienes Hubble UI abierto (`http://<IP-de-cualquier-nodo>:30281`)
> justo después de instalar, **el mapa va a aparecer vacío** ("No data
> found to render a service map"). Eso es normal: Hubble solo dibuja
> tráfico que efectivamente ocurrió — como los pods de la app de demo
> acaban de arrancar, todavía no hay ningún flujo que mostrar.

Para ver el mapa poblarse en vivo:

1. Abre Hubble UI y selecciona el namespace `frontend` (o `backend`/`database`)
   en el menú superior.
2. En una terminal, corre las pruebas de conectividad:
   ```bash
   ./tests/smoke-tests.sh
   ```
3. Verás las líneas aparecer en tiempo real en Hubble UI: **verde/sólida**
   para tráfico permitido (`frontend→backend`, `backend→database`), y
   **roja/punteada** para tráfico bloqueado (`frontend→database` directo,
   egress a internet, acceso desde `default`) — la prueba visual de que
   Cilium está aplicando las Network Policies, no solo aceptándolas.

`tests/smoke-tests.sh` también imprime su propio resultado `OK`/`FAIL` por
cada uno de los 6 casos, independientemente de si tienes Hubble UI abierto o
no.

## Desinstalar

```bash
./scripts/cleanup.sh
```
