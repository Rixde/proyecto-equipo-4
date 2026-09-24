# Proyecto 4: Falco + Network Policies (Runtime Security)

## 🎯 Descripción del proyecto

Proyecto orientado a la seguridad en tiempo de ejecución (runtime security) de un clúster de Kubernetes, mediante la implementación de **Falco** (monitoreo de seguridad en runtime con eBPF) y **Network Policies** (microsegmentación de red).

### Herramientas asignadas

- **Falco**: Runtime security monitoring con eBPF
- **Network Policies**: Microsegmentación de red

### Objetivos del proyecto

1. Instalar Falco en el clúster
2. Crear 15+ reglas custom de detección
3. Implementar Network Policies en todos los namespaces
4. Configurar alertas (Slack/MS Teams)
5. Crear diagrama de flujos de red

### ✅ Qué implementamos

- **Falco + Falcosidekick**, con **21 reglas custom** (mínimo pedido: 15) — fusión sin duplicados de las reglas de ambos integrantes del equipo, organizadas por táctica (ejecución, escalación de privilegios, persistencia, credenciales, red/impacto) y con exclusión explícita de namespaces de infraestructura para evitar falsos positivos.
- **Alertas a Slack** en tiempo real, más un dashboard (**Falcosidekick UI**) expuesto de forma permanente vía `NodePort` — sin depender de `kubectl port-forward`.
- **Network Policies de 3 capas** (`frontend → backend → database`): default-deny como base, whitelists explícitas por capa, y bloqueo **transitivo** verificado (`frontend` nunca llega a `database`, aunque `backend` sí pueda alcanzar ambas).
- **Visualización de red en vivo con Hubble UI** (Cilium) — mapa de tráfico con veredicto (`forwarded`/`dropped`) de cada flujo, también expuesto por `NodePort` permanente.
- **Testing automatizado**: 6 casos de conectividad (`tests/smoke-tests.sh`), disparadores individuales y completos de las 21 alertas (`tests/alerts/`, `tests/trigger-alerts.sh`), y verificación de que las reglas cargaron sin error (`scripts/test.sh`).
- **Infraestructura reproducible**: clúster de 3 nodos (kubeadm + Cilium + Hubble) provisionado con Ansible en un repositorio aparte — [`k8s-cilium-ansible`](https://github.com/Rixde/k8s-cilium-ansible.git) —, resultado de fusionar la automatización de un integrante con el entorno de 3 nodos y las reglas base del otro.
- **Documentación completa**: guía de instalación, configuración razonada de cada componente, 12 incidentes reales de troubleshooting, y la ficha de controles ISO/IEC 27001 con evidencia concreta por control.

## 👥 Integrantes del equipo

- Juárez Ugalde Ricardo
- Uarte Ortiz Enrique Yahir

## 🔧 Prerrequisitos (versiones de software)

- Kubernetes: `v1.36` (kubeadm)
- kubectl: `v1.36`
- Helm: `v3.22.0` (`scripts/install.sh` lo instala solo si falta)
- Falco: `0.45.0` (gestionado por el chart `falcosecurity/falco`; Falcosidekick va como subchart de la misma dependencia, sin versión fijada aparte)
- Cilium + Hubble: opcional — cualquier versión reciente compatible con `cilium hubble enable --ui`. No es un requisito duro del proyecto (ver `docs/installation.md` → Prerrequisitos).
- SO de los nodos: Rocky Linux 9, con `containerd` como runtime.

## 📦 Instalación paso a paso

```bash
git clone git@github.com:Rixde/proyecto-equipo-4.git
cd proyecto-equipo-4

cp .env.example .env
# Editar .env: FALCO_SLACK_WEBHOOK_URL (obligatorio), KUBECONFIG (opcional)

./scripts/install.sh
```

Guía completa (prerrequisitos, cómo crear el webhook de Slack, cómo configurar `kubectl` si no apunta al clúster correcto) en **[`docs/installation.md`](docs/installation.md)**.

## ⚙️ Configuración

Cada decisión de configuración está justificada en **[`docs/configuration.md`](docs/configuration.md)**: por qué `modern_ebpf` como driver de Falco, por qué Falcosidekick corre sin persistencia en Redis, por qué los dashboards se exponen por `NodePort` en vez de `port-forward`, y el detalle de las 21 reglas custom y las 4 capas de Network Policies.

## 🧪 Testing y validación

```bash
./scripts/test.sh             # confirma que Falco y las 21 reglas cargaron sin error
./tests/smoke-tests.sh        # 6 casos de Network Policies (permitido/bloqueado)
./tests/alerts/01-shell.sh    # dispara una alerta puntual (hay 5, una por táctica MITRE)
./tests/trigger-alerts.sh     # dispara las 21 reglas en orden, demo completa
```

Detalle de qué prueba cada script y cómo ver el mapa de tráfico en vivo con Hubble UI en **[`docs/installation.md`](docs/installation.md#probar-las-alertas-y-el-mapa-de-tráfico-de-red)**.

## 🩺 Troubleshooting

12 incidentes reales (síntoma, causa raíz, diagnóstico, solución) encontrados durante la implementación — ver **[`docs/troubleshooting.md`](docs/troubleshooting.md)**.

## 🔗 Referencias y documentación

- [docs/installation.md](docs/installation.md) — Guía de instalación
- [docs/configuration.md](docs/configuration.md) — Configuraciones
- [docs/architecture.md](docs/architecture.md) — Diagrama de arquitectura
- [docs/troubleshooting.md](docs/troubleshooting.md) — Solución de problemas
- [docs/presentation.pdf](docs/presentation.pdf) — Slides de presentación

## 🛡️ Controles ISO/IEC 27001 cubiertos

Ver ficha de controles, evidencia y brecha residual en [docs/iso27001.md](docs/iso27001.md).
