---
name: suanova-dev-vm
description: >-
  Manage virtual machines (VM / VMI / 虚拟机) in the SUANOVA KubeVirt cluster via kubectl: create or spin up
  开机器 (Ubuntu golden image, 10.66.x 网段, CPU/RAM, owner label), list & inspect 查看 (node / IP / status),
  start/stop/restart, SSH/console/VNC connect, snapshot & restore 快照, live-migrate 热迁移, delete 删除,
  batch-create identical VMs (VirtualMachinePool), and troubleshoot. Use this skill whenever the user talks
  about 虚拟机 / VM / VMI / virtctl / kubevirt, or asks to 开一台机器 / 删一台虚拟机 / 热迁移到别的节点 /
  看下 VM 状态或 IP — even casually and without naming the skill. The cluster facts that make these work
  (golden images, NADs, nodeSelector, naming rules) live here; don't answer VM questions from memory. Skip:
  VM disk export/backup, Calico/networking, Deployments/Pods, KubeVirt API coding, or installing tools.
---

# KubeVirt VM Management Skill

## Purpose

This skill helps users perform day-to-day VM management in the SUANOVA KubeVirt cluster. The ground truth is
the output of `kubectl`; the manifests and commands below are based on the real cluster environment
(`kubevirt-vm-user-guide.md`) and can be used as-is. Everything is `kubectl`-only — `virtctl` is **not** required
(optional for interactive console/VNC and graceful shutdown; see "Connect" and "Lifecycle").

> For the full manifests and complete YAML, see `kubevirt-vm-user-guide.md`; this file gives the actionable
> essentials and commands. Before running anything, confirm the current state with read-only commands first —
> do not guess, to avoid accidentally deleting or modifying the wrong thing.
>
> **User / admin boundary**: this skill only handles **user-side** VM management. Cluster build/configuration
> (networking, storage, snapshot infrastructure, feature gates) lives in `kubevirt-cluster-admin-guide.md`;
> hand anything of that kind to the admin and do not change cluster config yourself.

## Cluster facts (align on these before acting)

| Item | Value |
|------|-------|
| Kubernetes | v1.35.4, 3 control-plane nodes, no taints |
| Nodes / subnets | `10-66-2-1` (10.66.2.0/24); `10-66-3-46`, `10-66-3-47` (10.66.3.0/24) |
| KubeVirt / CDI | v1.8.4 / v1.65.0 |
| Networking | CNAO (Multus + Linux bridge), NMState, Whereabouts (IPAM) |
| Storage | Rook/Ceph RBD; StorageClass `ceph-rbd-kubevirt` (WaitForFirstConsumer, recommended), `ceph-rbd-kubevirt-immediate` |
| Golden images | `default` namespace: `ubuntu-22.04-server-amd64-img`(3Gi), `ubuntu-24.04-server-amd64-img`(4Gi), `ubuntu-26.04-server-amd64-img`(4Gi) |

**VM networking is L2 underlay**: a VM's NIC connects to the physical subnet via the node's `br0` bridge and gets
a **real IP from that subnet** (not a Pod IP); the IP is allocated by **Whereabouts** from a per-subnet pool
(DHCP inside the guest is enough — KubeVirt answers DHCP on the virt-launcher side). Each subnet has one
NetworkAttachmentDefinition (NAD) in the `default` namespace:

| Subnet | NAD | Whereabouts pool | Gateway |
|--------|-----|------------------|---------|
| 10.66.2.0/24 | `vm-underlay-10-66-2-0` | 10.66.2.200 ~ 220 | 10.66.2.254 |
| 10.66.3.0/24 | `vm-underlay-10-66-3-0` | 10.66.3.200 ~ 220 | 10.66.3.254 |

Nodes are labeled by subnet: `kubevirt.io/subnet=10-66-2-0` / `10-66-3-0`.

## Four non-negotiable constraints (and why)

1. **The subnet and `nodeSelector` must match.** Which subnet a VM lands in is decided by the multus
   `networkName` NAD reference, and you must also pin the VM to the matching subnet nodes with
   `nodeSelector: kubevirt.io/subnet: <matching-subnet>`. A mismatch gives the VM an IP from the wrong subnet
   or causes scheduling to fail.
2. **Root-disk PVC names must be globally unique within the namespace.** `dataVolumeTemplates[].metadata.name`
   becomes the PVC name directly; two VMs reusing the same root-disk name collide or even bind to the same disk.
   When creating a VM, change **all three together** to unique names: `metadata.name`,
   `dataVolumeTemplates[].metadata.name`, and `volumes[].dataVolume.name`.
3. **Disks must be shared** (`accessModes: ReadWriteMany` + `volumeMode: Block`, StorageClass
   `ceph-rbd-kubevirt`). This is the prerequisite for live migration; switching to `ReadWriteOnce` removes the
   VM's ability to migrate.
4. **Deletion is irreversible.** `reclaimPolicy: Delete` — deleting a VM/PVC removes the underlying RBD image.
   Always confirm with the user that data is backed up before deleting.

## Operational workflows

### 1. View / inspect current state

Overall view:

```bash
kubectl get vm,vmi -n default -o wide
kubectl get pvc -n default
kubectl get network-attachment-definitions -n default
kubectl get nodes --show-labels | grep subnet
```

Filter by owner (cluster convention: VMs carry an `owner` label):

```bash
kubectl get vm  -n default -l owner=<username>
kubectl get vmi -n default -l owner=<username> -o wide
```

Inspect a single VM:

```bash
kubectl describe vmi <vm> -n default                 # events, scheduling status
kubectl describe pod -l vm.kubevirt.io/name=<vm>     # network-status annotation: NAD/IP ready?
kubectl get vmim -n default -o wide                  # migration task status
```

### 2. Create a VM (clone from a golden image)

The admin has already uploaded the golden images — **do not** ask the user to re-upload images; clone the root
disk from a golden image. Confirm the golden images:

```bash
kubectl -n default get pvc | grep img
```

Reference manifest (8C/24Gi, on the 10.66.2.x subnet; full YAML in `kubevirt-vm-user-guide.md` §3.2):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-myapp            # ⚠️ change to a unique VM name
  namespace: default
  labels:
    owner: <username>
spec:
  runStrategy: Always       # Always=start on create; Halted=don't start; RerunOnFailure=auto-restart on failure
  dataVolumeTemplates:
  - metadata:
      name: vm-myapp-rootdisk    # ⚠️ root-disk PVC name, unique in the namespace
    spec:
      source:
        pvc:
          name: ubuntu-22.04-server-amd64-img   # golden image (24.04 / 26.04 also available)
          namespace: default
      storage:
        accessModes:
        - ReadWriteMany       # RWX: enables live migration
        storageClassName: ceph-rbd-kubevirt
        volumeMode: Block
        resources:
          requests:
            storage: 30Gi
  template:
    spec:
      nodeSelector:
        kubevirt.io/subnet: 10-66-2-0   # pin to the 10.66.2.x subnet nodes
      domain:
        cpu: { cores: 8 }
        resources:
          requests:
            memory: 24Gi
        devices:
          disks:
          - disk: { bus: virtio }
            name: rootdisk
          - disk: { bus: virtio }
            name: cloudinitdisk
          interfaces:
          - name: underlay
            bridge: {}        # L2 bridge
      networks:
      - name: underlay
        multus:
          networkName: default/vm-underlay-10-66-2-0   # pick the .2-subnet NAD
      volumes:
      - name: rootdisk
        dataVolume: { name: vm-myapp-rootdisk }        # must match the dataVolumeTemplates root-disk name
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            users:
            - name: ubuntu
              sudo: ALL=(ALL) NOPASSWD:ALL
              shell: /bin/bash
              lock_passwd: false
              passwd: "$6$..."     # crypt hash, see "passwd hash" below
            ssh_pwauth: true
            chpasswd:
              expire: false
          networkData: |
            version: 2
            ethernets:
              all-en:
                match: { name: "en*" }
                dhcp4: true
                nameservers:
                  addresses: [223.5.5.5, 8.8.8.8]
```

Create and confirm:

```bash
kubectl apply -f vm-myapp.yaml
kubectl get vm,vmi -n default -o wide   # expect vmi IP from the matching subnet pool, NODE = matching subnet node
```

**Three gotchas to explain when creating:**
- `passwd` is **not** plaintext — it is a **crypt password hash**. Generate it with `openssl` (not python's
  `crypt` module, which is unreliable on macOS). Linux: `openssl passwd -6 'your-password'` → `$6$...`
  (SHA-512). macOS (LibreSSL, no `-6` flag): `openssl passwd -1 'your-password'` → `$1$...` (MD5 — cloud-init
  and PAM accept it). The hash contains `$`, so wrap it in quotes in YAML. **More secure:** use
  `ssh_authorized_keys` and drop `passwd` / `ssh_pwauth`.
- **DNS must be written explicitly in `networkData`** — the NAD's DNS does not reach the guest automatically;
  without it the VM has no DNS.
- Ask the user for an `owner` label (per-person querying, accounting, cleanup). If they don't provide one,
  omit the label — never invent or reuse another user's label.

### 3. Lifecycle

VMs here use `runStrategy`, so lifecycle is a `kubectl patch` on the VM (or deleting the VMI to force a restart):

```bash
# Start the VM
kubectl patch vm <vm> -n default --type merge -p '{"spec":{"runStrategy":"Always"}}'
# Stop the VM (hard: VMI is torn down)
kubectl patch vm <vm> -n default --type merge -p '{"spec":{"runStrategy":"Halted"}}'
# Restart (force: delete the VMI, runStrategy Always recreates it)
kubectl delete vmi <vm> -n default
kubectl get vmi -n default -o wide # running VMIs and their IPs
```

These are **hard** (not graceful) operations — the VMI is torn down or recreated, and the underlay IP is **not
guaranteed to be retained** when it comes back (KubeVirt doesn't preserve secondary-network IPs across restart or
migration; the upstream fix is kubevirt/kubevirt#11410 "IPAM for secondary networks"). For a graceful shutdown,
run `sudo shutdown` inside the guest. (`virtctl stop/restart` do graceful ACPI shutdown if it happens to be
installed, but the skill doesn't require it.)

### 4. Connect to a VM

Primary method (no virtctl needed):

```bash
ssh ubuntu@<vmi-ip>                # password is the one set by cloud-init
```

VMs are on the underlay network — ping/ssh their subnet IP directly; **no** need to go through the Pod IP.

> Interactive serial console (`virtctl console`) and graphical VNC (`virtctl vnc`) need `virtctl`; they are optional
> extras, not required by this skill. Use SSH unless you specifically need console/VNC.

### 5. Snapshot & restore

Snapshotting is **ready to use** in this cluster (backed by RBD copy-on-write, VolumeSnapshotClass
`ceph-rbd-kubevirt-snap`). It requires all VM disks to be shared storage (RWX) — already satisfied here.
Snapshot infrastructure and low-level troubleshooting are **admin scope** (`kubevirt-cluster-admin-guide.md` §4).

**VM-level snapshot (recommended, captures the whole VM):**

```yaml
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: <vm>-snap-<date>
  namespace: default
spec:
  source: { apiGroup: kubevirt.io, kind: VirtualMachine, name: <vm> }
```

```bash
kubectl apply -f vm-snapshot.yaml
kubectl get virtualmachinesnapshot -n default   # wait for Ready
```

Restore (VirtualMachineRestore): point at the snapshot name to roll the whole VM back to that point in time.
⚠️ **The target VM must be powered off first** (stop it via the "Lifecycle" section — `runStrategy: Halted`). The
restore controller waits for the VMI to disappear and the operation fails after 5 minutes if the VM stays running.

**Disk-level snapshot (CSI, single root disk):** create a `VolumeSnapshot` with
`volumeSnapshotClassName: ceph-rbd-kubevirt-snap`, source = the root-disk PVC. You can restore a **new PVC**
from the snapshot (`dataSource` → `VolumeSnapshot`) and use it as a clone source for a new VM.

> If a snapshot fails (e.g. `provided secret is empty` / `clusterID must be set` /
> `snapshot feature gate not enabled`), it is a low-level VSC/feature-gate issue — **hand it to the admin**
> (admin guide §4); do not change cluster config yourself.

### 6. Live migration

Live migration moves a **running** VM to another node without interrupting the workload. It is triggered by
creating a `VirtualMachineInstanceMigration` object:

```bash
# Manual migration (the object `virtctl migrate` would create)
kubectl apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: migrate-<vm>
spec:
  vmiName: <vm>
EOF
kubectl get vmi <vm> -n default -o wide   # confirm NODE changed, VM did not drop
kubectl get vmim -n default -o wide       # Scheduling → Running → Succeeded
kubectl delete vmim migrate-<vm> -n default   # cancel
```

**Three prerequisites / gotchas to explain to the user:**
- All disks must be **RWX** RBD block PVCs (constraint #3). Migration control traffic runs over the Pod network
  (Calico); nodes must reach each other on TCP 49152/49153.
- **Same-subnet only**: the VM is pinned to a subnet by `nodeSelector`, and the target node must satisfy the same
  selector, so migration only happens **between nodes of the same subnet**. Current distribution: `.3` subnet has
  2 nodes (10-66-3-46/47) → `.3` VMs can migrate; `.2` subnet has only 1 node → `.2` VMs **cannot migrate**.
- **The underlay IP changes after migration** (known Whereabouts issue, kubevirt#13709/#14320): migration
  succeeds and data is intact, but the new Pod re-requests an IP, so the external IP may change and the old IP can
  even be grabbed by a newly created VM. Workloads that depend on a fixed IP will lose connectivity. Tell the user;
  to keep the IP, switch to a static guest IP (see `kubevirt-vm-user-guide.md` §6.3) or wait for the upstream
  fix — kubevirt/kubevirt#11410 "IPAM for secondary networks" (PersistentIPs/IPAMClaim), which covers restart too.

**Automatic migration on node drain**: by default VMs have **no** `evictionStrategy` set, so draining only cold-
restarts/interrupts them. To auto-migrate on drain, patch the VM (takes effect after the VM is restarted —
delete the VMI to force one, see "Lifecycle"):

```bash
kubectl patch vm <vm> -n default --type merge \
  -p '{"spec":{"template":{"spec":{"evictionStrategy":"LiveMigrate"}}}}'
```

### 7. Delete

```bash
kubectl delete vm <vm> -n default
```

**Always** re-confirm before deleting: it also removes the root-disk PVC / RBD image (`reclaimPolicy: Delete`);
data is unrecoverable.

### 8. Batch-create identical VMs (VirtualMachinePool, optional)

Use a `VirtualMachinePool` when you need N **identical** VMs (the VM-world equivalent of a Deployment/ReplicaSet).
Notes:

- This is an **alpha** feature. If creation is rejected (`vm pool feature gate not enabled`), the admin hasn't
  enabled the `VMPool` gate (admin guide §5) — **admin handles it**.
- **Stateful vs stateless**: putting `dataVolumeTemplates` in the template gives each replica its own persistent
  disk = **stateful**; for **stateless** (no persistence / read-only shared disk), drop `dataVolumeTemplates` and
  point `volumes` at a read-only base disk.
- ⚠️ **Root-disk base name must be unique per pool.** When a pool is stateful, set
  `dataVolumeTemplates[].metadata.name` to a **pool-unique base** — prefix it with the pool name, e.g.
  `<pool>-rootdisk` — and point `volumes[].dataVolume.name` at that same base. The controller appends an ordinal
  suffix per replica, so the DVs/PVCs come out as `<pool>-rootdisk-0/1/2`. If two pools reuse a generic base
  (e.g. a bare `rootdisk`), their replicas claim the **same** DV/PVC names (`rootdisk-0/1/2`): the later pool is
  **not refused** — it silently binds to the earlier pool's already-Bound disks, so both pools' VMs dual-attach to
  one live OS disk (data-corruption risk). Constraint #2's global-uniqueness rule applies to the pool's base name
  too, across the whole namespace.
- ⚠️ **Shrinking deletes at random by default**: when you lower `replicas`, the pool picks replicas to delete
  **randomly** by default (v1.8.4 default `Random` — it may delete a middle one and keep the last). To fix the
  order, configure `scaleInStrategy.proactive.selectionPolicy.sortPolicy`
  (`DescendingOrder` / `AscendingOrder` / `Newest` / `Oldest` / `Random`).
- The controller **auto-appends ordinal suffixes** to each replica's DV name (`<pool>-rootdisk` →
  `<pool>-rootdisk-0/1/2`) and rewrites `volumes[].dataVolume.name` accordingly — so per-replica names are never
  needed, **but the base name must still be namespace-unique** (prefix it with the pool name; a bare `rootdisk`
  collides across pools).
- **Do not hardcode** `interfaces[].macAddress` or `firmware.uuid` — replica MACs are assigned by kubemacpool;
  hardcoding causes L2 MAC conflicts between replicas.
- On a subnet, each replica still gets its own Whereabouts IP via `nodeSelector` + NAD.
- Deleting a pool also deletes the VMs and replica PVCs it manages (DV `reclaimPolicy: Delete`); confirm first.

```bash
kubectl get virtualmachinepool -n default
kubectl get vm -n default -l app=<pool>
kubectl patch virtualmachinepool <pool> -n default --type merge -p '{"spec":{"replicas":5}}'   # scale up
kubectl patch virtualmachinepool <pool> -n default --type merge -p '{"spec":{"replicas":2}}'   # scale down (random delete by default, see above)
kubectl delete virtualmachinepool <pool> -n default     # also deletes the managed VMs
```

## Troubleshooting quick reference

| Symptom | Check |
|---------|-------|
| VMI stuck in `Scheduling` | `kubectl describe vmi <vm>` for events; confirm the nodeSelector subnet has nodes |
| VM has no IP / no network | Confirm `dhcp4: true` in guest `networkData`; confirm the right NAD subnet; check the pod's network-status annotation |
| No DNS in the VM | DNS must be set explicitly in `networkData`; the NAD's DNS does not reach the guest |
| Want to pin the VM's IP | Use a Multus `ips` annotation (underlay network guide Step 7C); not guaranteed under live migration |
| IP changed after migration | Whereabouts doesn't know about migration; see "Live migration" |
| Cannot migrate | Root disk must be an RWX RBD block PVC; the target subnet needs a second node |
| Snapshot fails: `provided secret is empty` / `clusterID must be set` / `snapshot feature gate not enabled` | Low-level VSC/feature-gate issue; admin handles it (admin guide §4) |
| Creating a pool rejected: `vm pool feature gate not enabled` | Admin hasn't enabled the `VMPool` gate (admin guide §5) |

## Hard rules

1. Trust only the real output of `kubectl`; **never fabricate** VM state, IPs, or resources.
2. Confirm with the user before destructive operations (`delete`, a `stop` that affects business, migration), and
   explain the consequences (especially `reclaimPolicy: Delete` removing data).
3. If unsure about subnet / NAD / ownership, query read-only first, then act.
4. Full YAML lives in `kubevirt-vm-user-guide.md`; lower-level details (networking, storage, snapshot
   infrastructure, feature gates) live in `kubevirt-cluster-admin-guide.md` — admin scope, this skill does not
   do them and must not steer the user to do them.
