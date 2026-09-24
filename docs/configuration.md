# Configuración

Este documento describe cómo está configurado cada componente del proyecto y por qué se tomó cada decisión. Para instalar desde cero, ver `docs/installation.md`; para incidentes puntuales y su resolución, ver `docs/troubleshooting.md`.

## 1. Variables de entorno (`.env`)

`scripts/_env.sh` es cargado por todos los demás scripts (no se ejecuta solo) y centraliza dos variables, definidas en `.env` (nunca se sube a git, está en `.gitignore`):

| Variable | Obligatoria | Propósito |
|---|---|---|
| `FALCO_SLACK_WEBHOOK_URL` | Sí | URL del webhook de Slack para las alertas de Falco. `install.sh` la valida al inicio y aborta si falta. |
| `KUBECONFIG` | No | Solo necesaria si el usuario del sistema que corre los scripts no es el mismo que provisionó el clúster (por ejemplo, un `kubeconfig` distinto al de `~/.kube/config` del usuario actual). |

**Por qué el webhook no vive en `values.yaml`:** se inyecta en tiempo de ejecución con `--set falcosidekick.config.slack.webhookurl="${FALCO_SLACK_WEBHOOK_URL}"` dentro de `install.sh`, para que el secreto nunca quede versionado en el repositorio. `manifests/secrets-example.yaml` documenta una alternativa vía `Secret` de Kubernetes (`falcosidekick.config.existingSecret`) para quien prefiera no pasar el webhook por línea de comandos.

## 2. Falco (`helm/chart/values.yaml`)

```yaml
driver:
  kind: modern_ebpf   # eBPF sin necesidad de compilar módulo de kernel (Rocky Linux 9)

tty: true              # permite ver las alertas también en el log del pod de Falco
```

Se eligió el driver `modern_ebpf` en vez del módulo de kernel clásico porque no requiere compilar contra la versión exacta del kernel de cada nodo — relevante porque el kernel de Rocky Linux 9.8 usado (`5.14.0-611.5.1.el9_7`) está fuera del rango de versiones LTS que Kubernetes recomienda, y compilar un módulo contra un kernel no estándar es una fuente adicional de fallas evitable.

## 3. Falcosidekick + Slack

**Creación del webhook (paso manual, no automatizable por script):**

1. Entrar a [api.slack.com/apps](https://api.slack.com/apps) → *Create New App* → *From scratch*.
2. Activar la app en el workspace del equipo.
3. Ir a *Incoming Webhooks*, activarlo y *Add New Webhook to Workspace*.
4. Elegir el canal de destino y copiar la URL generada (`https://hooks.slack.com/services/...`).
5. Pegar esa URL en `FALCO_SLACK_WEBHOOK_URL` dentro de `.env` (nunca en `values.yaml` ni en git — ver sección 1).

```yaml
falcosidekick:
  enabled: true
  webui:
    enabled: true
    redis:
      storageEnabled: false
    ...
    slack:
      minimumpriority: warning
```

- **`redis.storageEnabled: false`**: el clúster no tiene ningún `StorageClass` (`kubeadm` no trae uno por defecto), y el Redis de la UI solo cachea eventos recientes para el dashboard — no es la evidencia que se conserva del proyecto. Se desactivó la persistencia en vez de instalar un *provisioner* de almacenamiento completo (ver `docs/troubleshooting.md`, incidente 5).
- **`minimumpriority: warning`**: filtra el ruido de prioridades `Debug`/`Informational` hacia Slack, dejando el canal legible sin perder ninguna alerta de las 21 reglas custom (todas están en `WARNING`, `ERROR` o `CRITICAL`).

## 4. Dashboards expuestos por NodePort

`install.sh` fija un `NodePort` permanente en los Services de los dos dashboards, leyendo el `port`/`targetPort` reales del Service en vez de asumirlos, para no romper la exposición si una versión futura del chart los cambia:

| Dashboard | NodePort | Contenido |
|---|---|---|
| Falcosidekick UI | `30280` | Historial de alertas de Falco. Usuario/clave por defecto `admin`/`admin` — **cambiar antes de exponer el clúster fuera del laboratorio**. |
| Hubble UI | `30281` | Mapa de tráfico de red en tiempo real (requiere Cilium + Hubble; ver `docs/installation.md` → Prerrequisitos). |

Se prefirió `NodePort` sobre `kubectl port-forward` (usado en las primeras pruebas manuales) porque un `port-forward` muere si se cierra la sesión de terminal que lo lanzó, mientras que el `NodePort` queda disponible de forma permanente desde cualquier IP de nodo.

## 5. Reglas custom de Falco (21 reglas)

Definidas en `customRules` dentro de `helm/chart/values.yaml`, organizadas en dos grupos:

- **Grupo 1 — propuestas del profesor** (8 reglas): shell inesperado en `default`, escritura en directorios críticos, lectura de archivos sensibles, conexión a IP en lista de vigilancia, escalación de privilegios, modificación de binarios del sistema, uso de *capabilities* peligrosas, lectura del token de *service account*.
- **Grupo 2 — reglas adicionales del equipo** (13 reglas): cubren persistencia, escalación de privilegios adicional, contenedores privilegiados, acceso al filesystem del host, herramientas de red sospechosas, manipulación de namespaces, minería de criptomonedas, borrado de logs, entre otras.

**Decisión de tuning aplicada de forma consistente:** casi todas las reglas excluyen la lista `namespaces_infraestructura` (`kube-system`, `kube-node-lease`, `calico-system`/componentes del CNI, `tigera-operator`, `falco`). Sin esta exclusión, actividad legítima y rutinaria de los propios componentes del clúster —como la relectura periódica del token de *service account* por `coredns` o el CNI— genera ruido indefinido en Slack, indistinguible de una prueba real (ver `docs/troubleshooting.md`, incidente 8). Esto es evidencia directa de criterio para el control **A.5.25** de ISO/IEC 27001 (clasificación de eventos de seguridad).

**Estado abierto:** la regla *"Conexión saliente a puerto inusual"* usa el campo obsoleto `evt.dir=<`, generando un warning (no bloqueante) al cargar. Pendiente de corregir con el mismo patrón ya aplicado a otra regla equivalente (ver `docs/troubleshooting.md`, incidente 6).

## 6. App de demostración (frontend/backend/database)

Definida en `manifests/deployment.yaml` y `manifests/configmap.yaml`: 3 `Deployment` (2 réplicas cada uno) usando `nginx:stable-alpine`, uno por namespace (`frontend`, `backend`, `database`). Cada uno sirve una página HTML propia inyectada por `ConfigMap` (en vez de la página por defecto de nginx), para que al probar la conectividad entre capas el contenido de la respuesta identifique de qué capa vino — útil para la demo en vivo y para las capturas de evidencia.

## 7. Validar y demostrar las reglas de Falco

Cada regla tiene un disparador reproducible, sin necesidad de recordar comandos sueltos:

- **`scripts/alerts/01-shell.sh` a `05-binary-tamper.sh`** — disparan **una sola alerta puntual** cada uno (shell interactivo, contenedor privilegiado, lectura de token de *service account*, conexión a IP vigilada, modificación de binario), pensados para una demo controlada o para reproducir un incidente específico.
- **`scripts/trigger-alerts.sh`** — dispara las **21 reglas en orden**, una por una, contra un mismo pod de prueba (creando pods adicionales solo cuando la regla lo requiere), e imprime en consola qué regla corresponde a cada paso. Limpia los pods de prueba al terminar. No es un test de *pass/fail* — es una demo secuencial para verlas llegar en vivo a Slack y a Falcosidekick UI.

## 8. Network Policies

Manifiestos en `manifests/network-policies/`, aplicados en orden porque cada capa depende de la anterior:

1. **`00-default-deny.yaml`** — `default-deny-all` (ingress + egress) en los namespaces `frontend`, `backend` y `database`. Punto de partida: todo bloqueado.
2. **`01-allow-dns.yaml`** — egress hacia CoreDNS (puerto 53 UDP/TCP) en los 3 namespaces. Sin esta política, ningún nombre `*.svc.cluster.local` resuelve, aunque el tráfico de aplicación sí estuviera permitido (ver `docs/troubleshooting.md`, incidente 7).
3. **`02-frontend-policies.yaml`**, **`03-backend-policies.yaml`**, **`04-database-policies.yaml`** — whitelists específicas por capa, usando la etiqueta automática `kubernetes.io/metadata.name` para seleccionar el namespace de origen/destino:
   - `frontend` → egress permitido solo hacia `backend`, puerto 80.
   - `backend` → ingress permitido solo desde `frontend`; egress permitido solo hacia `database`, puerto 80.
   - `database` → ingress permitido solo desde `backend`; sin egress de aplicación (solo el DNS del paso 2).

Resultado esperado y verificado por `tests/smoke-tests.sh`: `frontend → backend` y `backend → database` permitidos; `frontend → database` directo bloqueado (demuestra que la segmentación es transitiva, no solo un filtro de IP superficial); egress a internet y acceso desde namespaces ajenos (`default`) bloqueados.

Estas políticas son manifiestos `NetworkPolicy` estándar (no `CiliumNetworkPolicy`), por lo que funcionan igual con cualquier CNI compatible con la API `NetworkPolicy` — no dependen de que el clúster use Cilium.

## 9. Capa opcional: Cilium + Hubble

Cilium y Hubble **no forman parte de este repositorio** (ver `docs/installation.md` → Prerrequisitos): se instalan a nivel de clúster, fuera del alcance de `install.sh`. `install.sh` detecta su presencia automáticamente al inicio (`kubectl -n kube-system get daemonset cilium`) y ajusta su salida en consecuencia:

- Si Cilium **y** Hubble están presentes → expone el dashboard de Hubble UI en el NodePort `30281`.
- Si Cilium está pero Hubble no está habilitado → avisa cómo activarlo (`cilium hubble enable --ui`).
- Si Cilium no está presente → avisa que Falco y las Network Policies funcionan igual, pero sin mapa de tráfico en vivo.

Esta separación es intencional: mantiene el repositorio agnóstico del CNI usado por cada integrante del equipo, evitando acoplar el despliegue de Falco/Network Policies a una decisión de infraestructura que puede variar entre entornos.
