# Troubleshooting

Este documento recopila los incidentes reales encontrados durante la implementación del proyecto, con su síntoma, causa raíz, diagnóstico y solución aplicada. Se conservan los incidentes ocurridos con la implementación original sobre Calico, marcados como *históricos*, porque documentan decisiones de diseño y método de diagnóstico que siguen siendo válidos aunque el CNI haya cambiado a Cilium.

---

## 1. `calico-node` en `CrashLoopBackOff` por autodetección incorrecta de IP *(histórico — Calico)*

**Síntoma.** Tras aplicar el operador de Calico, `calico-node` quedaba en `CrashLoopBackOff` en los nodos worker, mientras `calico-typha` y `calico-kube-controllers` seguían `Running`.

**Causa raíz.** Las VMs de VirtualBox tienen dos interfaces de red (NAT y solo-anfitrión). Calico autodetectó la IP de la interfaz NAT en lugar de la interfaz solo-anfitrión (`192.168.56.0/24`), que es la única alcanzable entre nodos.

**Diagnóstico.**
```bash
kubectl get pods -n calico-system -o wide
```

**Solución.**
```bash
kubectl patch installation.operator.tigera.io default --type='json' \
  -p='[{"op":"add","path":"/spec/calicoNetwork/nodeAddressAutodetectionV4","value":{"cidrs":["192.168.56.0/24"]}}]'
sudo firewall-cmd --permanent --add-port=5473/tcp   # puerto de Typha, sin él no hay sincronización
sudo firewall-cmd --reload
kubectl delete pods -n calico-system -l k8s-app=calico-node
```

**Nota de vigencia.** Con la migración a **Cilium**, este incidente ya no aplica: Cilium usa su propio mecanismo de detección de interfaz y no presentó este problema en la reinstalación. Se conserva como referencia porque el patrón de diagnóstico (revisar qué interfaz está tomando el CNI en entornos con múltiples redes de VirtualBox) es reutilizable ante cualquier CNI.

---

## 2. Interfaces del CNI bloqueadas por `firewalld` *(histórico — Calico, ya no aplica con Cilium)*

**Síntoma.** El pod de Falco en `worker1` quedaba indefinidamente en `Init:Error`; el init container no podía resolver DNS ni siquiera hacia `kubernetes.default`.

**Causa raíz.** La zona por defecto de `firewalld` en Rocky Linux (`public`) tiene como target `REJECT`. Las interfaces creadas por Calico (`vxlan.calico`, `cali*`) caían en esa zona, por lo que `firewalld` rechazaba activamente el tráfico este-oeste entre pods, incluido el tráfico hacia CoreDNS.

**Solución aplicada (en `worker1`):**
```bash
firewall-cmd --permanent --zone=trusted --add-interface=vxlan.calico
firewall-cmd --permanent --zone=trusted --add-interface=cali+
firewall-cmd --reload
systemctl disable --now firewalld
```

Es honesto documentar que mover las interfaces a la zona `trusted` fue el diagnóstico correcto, pero lo que en la práctica destrabó el tráfico fue deshabilitar `firewalld` por completo, ya que ambos pasos se aplicaron juntos sin probar el primero de forma aislada. Por un efecto secundario de terminal, `master` también terminó con `firewalld` deshabilitado.

**Por qué ocurrió con Calico.** La instalación original de Calico se hizo a mano y no incluía ninguna regla de `firewalld` para el tráfico de pods: sus interfaces (`vxlan.calico`, `cali*`) quedaban en la zona `public` por defecto. El problema no se reprodujo con **Cilium** porque su instalación se hace con Ansible (`k8s-cilium-ansible`, `01-prepare.yml`), que configura `firewalld` junto con el CNI: agrega `pod_cidr` y `service_cidr` a la zona `trusted` (por origen, no por interfaz) y abre los puertos propios de Cilium (`8472/udp`, `4240/tcp`, `4244/tcp`).

**Nota de vigencia (corrección).** Una versión anterior de este documento y de `docs/iso27001.md` afirmaba que `firewalld` seguía deshabilitado en los 3 nodos tras la migración a Cilium, como "riesgo aceptado". **Eso era incorrecto**: al reaprovisionar los nodos con Ansible para la migración a Cilium, el playbook vuelve a habilitar y arrancar `firewalld` en todos los nodos. El estado actual es **`firewalld` activo en los 3 nodos** con reglas específicas por rol (detalle en `docs/iso27001.md`, control A.8.20). La deshabilitación de `firewalld` fue una medida temporal propia de la etapa con Calico. Muestra de que `firewalld` está activo con Cilium: el incidente 10, donde bloqueaba el tráfico de Hubble Relay.

---

## 3. Instalación de Helm falla por falta de `git` y `tar`

**Síntoma.**
```
[WARNING] Could not find git. It is required for plugin installation.
[ERROR] Could not find tar. It is required to extract the helm binary archive.
Failed to install helm
```

**Causa raíz.** La imagen base de Rocky Linux usada no trae `git` ni `tar` preinstalados.

**Solución.**
```bash
sudo dnf install -y git tar openssl
./get_helm.sh
```

---

## 4. Pod de Falco en `Init:Error` justo después de un `kubeadm join` reciente

**Síntoma.** Al unirse un nodo worker nuevo al clúster, el pod de Falco agendado ahí queda en `Init:Error` o `Init:CrashLoopBackOff` durante 2-5 minutos, mientras los pods en nodos ya establecidos arrancan sin problema.

**Causa raíz.** Es una **condición de arranque (race condition)**, no un error de configuración: el plugin de red (Calico o Cilium, según la implementación) necesita varios segundos para terminar de sincronizar sus rutas en el nodo recién unido. Si un pod se agenda ahí antes de que la sincronización termine, sus primeros intentos de resolver DNS hacia CoreDNS fallan. Kubernetes reintenta con *backoff* exponencial, y una vez que el CNI se estabiliza, los reintentos posteriores tienen éxito solos.

**Diagnóstico.** Revisar el log del init container de un reintento *reciente*, no del primero:
```bash
kubectl logs -n falco <pod> -c falcoctl-artifact-install --previous
```
Si no hay error real ahí (el artefacto se descargó e instaló correctamente), se confirma la condición de arranque y no un problema real de firewall/DNS/CNI.

**Solución.** Ninguna acción correctiva — se resuelve solo tras los reintentos automáticos de Kubernetes.

**Evidencia con Cilium.** Este mismo patrón se observó al reconstruir el clúster con Cilium: tras el `kubeadm join` de los workers, `cilium status --wait` reportó temporalmente `unable to retrieve cilium status: dial unix /var/run/cilium/cilium.sock: connect: no such file or directory` y los pods de `hubble-relay`/`hubble-ui` quedaron en `Pending`/`ContainerCreating` por unos minutos, resolviéndose solo sin intervención — confirma que la causa raíz (condición de arranque, no error de configuración) es independiente del CNI usado.

**Lección operativa.** Cuando un pod falla justo después de que un nodo se une, esperar unos minutos y revisar los logs de un reintento reciente antes de aplicar un fix — el log de un intento viejo puede mostrar un error que ya no aplica.

---

## 5. `falco-falcosidekick-ui-redis-0` atascado en `Pending` (sin `StorageClass`)

**Síntoma.**
```
Warning  FailedScheduling  0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims. not found
```
y `kubectl get storageclass` no devuelve nada.

**Causa raíz.** `kubeadm` no trae ningún `StorageClass` por defecto (a diferencia de un cloud gestionado como EKS/GKE), y el Redis de la UI de Falcosidekick pide un `PersistentVolumeClaim` que nunca puede satisfacerse.

**Decisión.** No se necesita persistencia para este proyecto: Redis solo cachea eventos recientes para el dashboard, no es la evidencia que se conserva (esa vive en los logs/capturas del repo). Se desactiva la persistencia en vez de instalar un *provisioner* de almacenamiento completo.

**Solución.**
```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --reuse-values \
  --set falcosidekick.webui.redis.storageEnabled=false

kubectl delete pvc falco-falcosidekick-ui-redis-data-falco-falcosidekick-ui-redis-0 -n falco --ignore-not-found
```
El parámetro exacto se confirmó inspeccionando los valores reales del subchart, ya que `helm show values falcosecurity/falco` no expone los defaults completos de un subchart de dependencia:
```bash
helm get values falco -n falco -a | grep -n -i -B2 -A30 "webui:"
```

---

## 6. Reglas custom de Falco rechazadas: macro inexistente y campo obsoleto

**Síntoma.** Tras aplicar el `ConfigMap` con las reglas custom, el `DaemonSet` de Falco quedó con un pod en `CrashLoopBackOff` en el nodo donde le tocaba el turno del *rolling update*.

**Causa raíz.** El `DaemonSet` usa `RollingUpdate` con `maxUnavailable: 1`, reemplazando pods uno a la vez y deteniendo el avance si el nuevo pod no llega a `Ready`. El archivo de reglas tenía dos problemas:

1. La regla *"Contenedor iniciado en modo privilegiado"* usaba la macro `container_started`, no definida en la versión de Falco desplegada.
2. La regla *"Posible escalación de privilegios"* usaba la condición `evt.dir=<`, marcada obsoleta: desde que Falco dejó de emitir eventos de entrada, esa comparación siempre evalúa verdadero y no filtra nada.

**Diagnóstico.**
```bash
kubectl logs -n falco <pod-en-crashloop> -c falco --previous
```
Falco reporta la ubicación exacta: `LOAD_ERR_VALIDATE: Undefined macro 'container_started'` y `LOAD_DEPRECATED_ITEM: field 'evt.dir'`.

**Solución.** Se sustituyó la macro inexistente por una condición basada en un evento de ciclo de vida existente, y se retiró la comparación obsoleta:
```bash
sed -i 's/condition: container_started and container.privileged=true/condition: evt.type=container and container.privileged=true/' custom-rules-equipo3.yaml
sed -i 's/evt.type in (setuid, setresuid) and evt.dir=< and/evt.type in (setuid, setresuid) and/' custom-rules-equipo3.yaml
helm upgrade falco falcosecurity/falco --namespace falco --reuse-values -f custom-rules-equipo3.yaml
```

**Lección.** Falco valida el archivo de reglas completo, no regla por regla: un solo error invalida todo el archivo aunque las demás reglas estén bien escritas. Conviene revisar los logs de *todos* los nodos tras cada cambio, ya que el `RollingUpdate` puede dejar nodos corriendo versiones distintas de las reglas mientras el rollout avanza.

**Estado abierto en el repositorio actual.** La regla *"Conexión saliente a puerto inusual"* de `helm/chart/values.yaml` reincide en el mismo campo obsoleto (`evt.dir=<`), confirmado por `./scripts/test.sh` (`Ok, with warnings`). No bloquea la carga, pero debe corregirse con el mismo patrón descrito arriba.

---

## 7. Network Policy `default-deny-all` rompe la resolución DNS

**Síntoma.**
```
wget: bad address 'backend.backend.svc.cluster.local'
```
inmediatamente después de aplicar el `default-deny-all` en los 3 namespaces.

**Causa raíz.** `bad address` no es un bloqueo de conexión — es que el pod no pudo resolver el nombre a una IP. Para resolver, necesita consultar a CoreDNS (`kube-system`), y el `default-deny-all` sin excepciones también bloqueó esa salida.

**Solución.** Permitir egress a CoreDNS explícitamente en los 3 namespaces (puerto 53 UDP/TCP), usando la etiqueta `kubernetes.io/metadata.name` que Kubernetes asigna automáticamente a todo namespace desde la v1.21. Ver `manifests/network-policies/01-allow-dns.yaml`.

**Verificación del estado intermedio correcto.** Tras permitir DNS pero antes de las whitelists de aplicación, el nombre debe resolver pero la conexión debe quedar en `timeout` (no `bad address`) — confirma que DNS está abierto y el resto sigue cerrado como se espera.

---

## 8. Ruido de falsos positivos: alertas repetidas sin generar tráfico propio

**Síntoma.** La regla *"Lectura del token de service account"* sigue disparando alertas indefinidamente después de la prueba inicial con `test-shell`, sin que se ejecute ninguna acción nueva.

**Causa raíz.** La condición de la regla filtraba solo por `container`, sin excluir namespaces de infraestructura. Prácticamente todo pod del sistema (`coredns`, `calico-node`/`cilium`, `kube-proxy`) lee su propio token de *service account* de forma rutinaria para hablar con la API del clúster, y Kubernetes lo renueva automáticamente cada hora.

**Diagnóstico.**
```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --all-containers --prefix --tail=100 | grep -i "token de service account"
```
Si el campo `pod=` muestra `calico-node-xxxx` o `coredns-xxxx` en vez de `test-shell`, se confirma que es ruido de fondo del clúster, no una repetición de la prueba.

**Solución (tuning de falsos positivos).** Excluir los namespaces de infraestructura conocida:
```yaml
condition: >
  open_read and container and
  fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount and
  not k8s.ns.name in (kube-system, calico-system, falco, kube-node-lease)
```

**Relevancia para ISO/IEC 27001 (control A.5.25).** Este ajuste es evidencia directa de criterio en la clasificación de eventos de seguridad: se documenta como decisión consciente que excluye namespaces de infraestructura conocida, dejando el namespace `default` y cualquier namespace de aplicación futuro bajo vigilancia completa.

---

## 9. Pods de Hubble/Falcosidekick UI en `Pending` justo después de instalar Cilium

**Síntoma.** `cilium status --wait` se queda colgado indefinidamente. `kubectl -n kube-system get pods` muestra `hubble-relay`/`hubble-ui` en `Pending`, con el evento:
```
Warning  FailedScheduling  0/1 nodes are available: 1 node(s) had untolerated taint(s)
```

**Causa raíz.** El playbook de Ansible instala Cilium/Hubble (`04-master.yml`) **antes** de que los workers se unan al clúster (`05-workers.yml`). En ese punto del despliegue solo existe el nodo master, y todavía conserva el *taint* estándar de control-plane (`node-role.kubernetes.io/control-plane:NoSchedule`) que `kubeadm` aplica por defecto — aunque el diseño del clúster espera que el master también funcione como worker. Con un único nodo *tainted* y sin tolerancia, cualquier `Deployment` sin `hostNetwork` (como `hubble-relay`/`hubble-ui`) no tiene dónde agendarse.

**Solución.** Se agregó una tarea en `04-master.yml` que quita el taint del control-plane **antes** de instalar Cilium/Hubble, para que el nodo quede agendable de inmediato:
```bash
kubectl taint node <nodo> node-role.kubernetes.io/control-plane:NoSchedule-
```

**Lección.** El orden de las tareas en un playbook importa tanto como las tareas en sí: una suposición del diseño (“el master también agenda pods”) debe quedar establecida *antes* de cualquier paso que dependa de ella, no después.

---

## 10. Hubble UI muestra "1/3 nodes" — `firewalld` bloqueaba el tráfico de Hubble Relay hacia otros nodos

**Síntoma.** El dashboard de Hubble UI carga, pero la esquina superior derecha muestra `1/3 nodes`, y namespaces con pods en otros nodos aparecen sin flujos ("No flows found").

**Causa raíz.** Hubble Relay se conecta al puerto `4244` de cada agente de Cilium (que usa `hostNetwork`, es decir, escucha en la IP real del nodo, no en una IP de pod). Cilium enmascara (SNAT) el tráfico de un pod hacia una IP de nodo — porque, desde la perspectiva del `pod_cidr`, la IP de un nodo es un destino "externo" — así que al llegar al nodo destino, la IP de origen ya no es la del pod de Hubble Relay, sino la IP del **nodo que envía**. Esa IP no está en la regla de zona `trusted` de `firewalld` (que solo confía en `pod_cidr`/`service_cidr`), así que la zona por defecto (`public`, target `REJECT`) la bloquea.

**Diagnóstico.**
```bash
kubectl -n kube-system logs deploy/hubble-relay --tail=30
kubectl -n kube-system get endpoints hubble-peer
```
El log de Relay muestra explícitamente a qué IP no logra conectarse.

**Solución.** Igual que con el puerto de *health checks* de Cilium (`4240`), se abrió explícitamente el puerto de Hubble en `firewalld` de los 3 nodos:
```bash
sudo firewall-cmd --permanent --add-port=4244/tcp
sudo firewall-cmd --reload
```
Ambos puertos quedaron incorporados de forma permanente en la lista `fw_ports` del repo de aprovisionamiento (`k8s-cilium-ansible`, `inventory/group_vars/masters.yml` y `workers.yml`), para que un reaprovisionamiento no vuelva a reproducir el problema.

**Lección.** Confiar en `pod_cidr` como origen no cubre tráfico host-a-host entre nodos (salud entre agentes, Hubble, etc.) — ese tráfico sale con la IP del nodo emisor, no con una IP de pod, y necesita su propia regla explícita de firewall aunque el origen "real" sea un pod.

---

## 11. `install.sh` reporta "Failed to install helm" aunque la instalación sí funcionó

**Síntoma.** El script se detiene justo después de que el propio instalador de Helm imprime `helm installed into /usr/local/bin/helm`, con el mensaje:
```
helm not found. Is /usr/local/bin on your $PATH?
Failed to install helm
```
Al correr `install.sh` de nuevo, no reinstala nada y continúa sin problema.

**Causa raíz.** El instalador oficial de Helm (`get_helm.sh`) se corre con `sudo`, y al final hace su propia autoverificación (`command -v helm`) **dentro de esa sesión de `sudo`**. En Rocky/RHEL, el `$PATH` restringido que usa `sudo` (`secure_path`) no incluye `/usr/local/bin` — el mismo problema, exactamente, documentado en este proyecto para Cilium (ver `docs/configuration.md`). El binario sí se instaló correctamente; solo la autoverificación de `get_helm.sh`, con ese `$PATH` recortado, no lo encuentra. Como `install.sh` usa `set -euo pipefail`, ese código de salida distinto de cero detiene todo el script.

**Solución.** No confiar en el código de salida de `get_helm.sh`, y verificar con el `$PATH` real del usuario que corre el script:
```bash
sudo /tmp/get_helm.sh || true
command -v helm >/dev/null 2>&1 || { echo "Error: Helm no quedó disponible."; exit 1; }
```

**Lección.** Es el mismo patrón de fondo que el incidente de Cilium: cualquier script que se autoverifica corriendo bajo `sudo` puede dar un falso negativo si su `$PATH` restringido no coincide con el `$PATH` real del usuario. Conviene no confiar ciegamente en el código de salida de herramientas de terceros corridas con `sudo`.

---

## 12. `trigger-alerts.sh` generó más de 180 alertas en una sola corrida (se esperaban 21)

**Síntoma.** Una sola ejecución de `trigger-alerts.sh` (pensado para disparar 21 alertas, una por regla) llenó Slack con más de 180 mensajes.

**Causa raíz.** El script instalaba 3 herramientas con `apk add --no-cache nmap python3 util-linux` para poder disparar 3 de las reglas de demostración. Instalar un paquete en Alpine escribe (y a veces cambia permisos de) decenas de archivos dentro de `/usr/bin`, `/usr/sbin` y `/etc` — cada uno de esos archivos hizo *match* individualmente con la regla *"Escritura en directorio del sistema"*, generando una alerta por archivo instalado, no una alerta por acción intencional.

**Diagnóstico.** Comparar el campo `pod=`/`comando=` de las alertas contra lo que el script realmente ejecutó a propósito — la mayoría correspondían a `apk`, no a ninguna de las 21 acciones de demostración.

**Solución.** Se rediseñaron los disparadores individuales (`tests/alerts/01` a `05`) para no depender de instalar ningún paquete adicional — se eligieron 5 reglas que se pueden disparar con herramientas que ya vienen en la imagen base (`sh`, `wget`, `chmod`, etc.), evitando el ruido de raíz en vez de intentar filtrarlo con una regla adicional.

**Relevancia para ISO/IEC 27001 (control A.5.25).** Es una categoría de ruido distinta a la del incidente 8: no es actividad rutinaria de la infraestructura del clúster, sino un efecto secundario del propio proceso de *testing* de seguridad. Ambos casos refuerzan la misma idea: el criterio de qué es ruido operativo esperado debe documentarse explícitamente, no descubrirse a mitad de una demo en vivo.
