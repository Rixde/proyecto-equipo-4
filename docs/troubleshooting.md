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

## 2. Interfaces del CNI bloqueadas por `firewalld` *(histórico — Calico, con efecto persistente)*

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

**Decisión de diseño (documentada también en `docs/iso27001.md`, control A.8.20).** `firewalld` permanece deshabilitado en los 3 nodos del clúster. Riesgo aceptado porque la red es solo-anfitrión de VirtualBox (`192.168.56.0/24`) sin exposición externa; queda marcado como pendiente de compensar si el proyecto llegara a producción, por ejemplo con Network Policies asumiendo la segmentación que `firewalld` hacía a nivel de host.

**Nota de vigencia.** Esta condición (`firewalld` deshabilitado) se mantiene en los 3 nodos tras la migración a Cilium, ya que los mismos nodos/VMs se reutilizaron. Con Cilium no se ha necesitado ninguna excepción adicional de `firewalld`.

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
