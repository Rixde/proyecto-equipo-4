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

### Entregables

1. **Falco instalado y configurado**
   - DaemonSet corriendo en todos los nodos
   - Falcosidekick para routing de alertas
   - Integración con Slack o MS Teams
   - Dashboard de alertas (Falcosidekick UI)

2. **Reglas custom de Falco (mínimo 15)**
   - Detectar shells spawneados en containers
   - Alertar escrituras en /etc, /bin, /usr/bin
   - Detectar lectura de archivos sensibles (/etc/shadow)
   - Monitorear conexiones de red sospechosas
   - Detectar escalación de privilegios
   - Alertar cambios en binarios del sistema
   - Detectar uso de capabilities peligrosas
   - Monitorear acceso a secrets de Kubernetes
   - Y 7 reglas adicionales personalizadas

3. **Network Policies implementadas**
   - Default deny en todos los namespaces de producción
   - Whitelists documentadas por aplicación
   - Políticas ingress y egress
   - Diagrama visual de flujos permitidos
   - Testing de conectividad documentado

4. **Presentación**
   - Demo: Ejecutar shell en container → Alerta de Falco
   - Demo: Intentar conexión bloqueada por Network Policy
   - Mostrar anatomía de una regla de Falco
   - Visualización de red con Cilium Hubble (opcional)

## 👥 Integrantes del equipo

- Juárez Ugalde Ricardo
- Uarte Ortiz Enrique Yahir

## 🔧 Prerrequisitos (versiones de software)

- Kubernetes: `vX.Y.Z`
- Helm: `vX.Y.Z`
- Falco: `vX.Y.Z`
- Falcosidekick: `vX.Y.Z`
- kubectl: `vX.Y.Z`
- Otros: _pendiente_

## 📦 Instalación paso a paso

> _Pendiente de completar._

## ⚙️ Configuración

> _Pendiente de completar._

## 🧪 Testing y validación

> _Pendiente de completar._

## 🩺 Troubleshooting

> _Pendiente de completar._

## 🔗 Referencias y documentación

- [docs/installation.md](docs/installation.md) — Guía de instalación
- [docs/configuration.md](docs/configuration.md) — Configuraciones
- [docs/architecture.md](docs/architecture.md) — Diagrama de arquitectura
- [docs/troubleshooting.md](docs/troubleshooting.md) — Solución de problemas
- [docs/presentation.pdf](docs/presentation.pdf) — Slides de presentación

## 🛡️ Controles ISO/IEC 27001 cubiertos

Ver ficha de controles, evidencia y brecha residual en [docs/iso27001.md](docs/iso27001.md).
