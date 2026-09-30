---
name: suanova-dev-vm
description: >-
  Manage virtual machines (VM / VMI / 虚拟机) in the SUANOVA KubeVirt cluster via kubectl: create or spin up
  开机器 (Ubuntu golden image, 10.66.x 网段, CPU/RAM, owner label), list & inspect 查看 (node / IP / status),
  start/stop/restart, SSH/console/VNC connect, snapshot & restore 快照, live-migrate 热迁移, attach a MetaX
  GPU or a RoCE NIC by PCI passthrough (直通显卡 / RoCE 网卡), delete 删除, batch-create identical VMs
  (VirtualMachinePool), and troubleshoot. Use this skill whenever the user talks
  about 虚拟机 / VM / VMI / virtctl / kubevirt, or asks to 开一台机器 / 删一台虚拟机 / 热迁移到别的节点 /
  看下 VM 状态或 IP / 给 VM 一个固定 IP / 给 VM 加显卡或网卡 — even casually and without naming the skill.
  The cluster facts that make these work (golden images, IP pools, NADs, nodeSelector, GPU/RoCE device
  resources, naming rules) live here; don't answer VM questions from memory. Skip: VM disk export/backup,
  Calico/networking, Deployments/Pods, KubeVirt API coding, or installing tools.
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
> hand anything of that kind to the admin and do not change cluster config yourself. That includes **creating or
> changing an IP pool** — see the Hard rules.

> **The underlay address comes from a pool.** A VM annotates itself with a pool, a controller mints it a
> one-address network, and the guest stays on DHCP. It is the reason an address now survives a restart and a
> live migration. The full task-oriented guide is `cubestack-ipam/docs/user-guide.md`; §2 of this file is the
> version to copy when creating a VM.

## Cluster facts (align on these before acting)

| Item | Value |
|------|-------|
| Kubernetes | v1.35.4, 3 control-plane nodes (each also a worker), no taints |
| Nodes / subnet | `10-66-3-43`, `10-66-3-46`, `10-66-3-47` — all three on **10.66.3.0/24** |
| KubeVirt / CDI | v1.8.4 / v1.65.0 |
| Networking | CNAO (Multus + Linux bridge), NMState, **cubestack-ipam** (pool-based static underlay IPs), Whereabouts |
| Storage | Rook/Ceph RBD; StorageClass `ceph-rbd-kubevirt` (WaitForFirstConsumer, recommended), `ceph-rbd-kubevirt-immediate` |
| Golden images | `default` namespace, all `ceph-rbd-kubevirt-immediate` + Block + RWO. **Default: `ubuntu-22.04-server-cloudimg-5.15.0-130-amd64.img` (3Gi)** — Ubuntu 22.04.5, kernel 5.15.0-130, **stock — no MetaX driver** (the kernel in the name is just what it ships). Also available: `ubuntu-22.04-server-amd64-img`(3Gi), `ubuntu-24.04-server-amd64-img`(4Gi), `ubuntu-26.04-server-amd64-img`(4Gi). **None of them carries the MetaX driver** — install it in the guest (§2b) |

**VM networking is L2 underlay**: a VM's NIC connects to the physical subnet via the node's `br0` bridge and gets
a **real IP from that subnet** (not a Pod IP). There is exactly one way to obtain that address — a **pool claim**:

| | Pool claim — the only way |
|---|---|
| How | annotate the VM with a pool; a controller mints a one-address NAD for that VM |
| NAD | `default/<vm-name>-static`, minted for you (it does not exist yet when you apply) |
| IPAM | `static` — the address is written into the NAD |
| Survives a pod restart | **yes** — the address lives in the network, not the pod sandbox |
| Live migration | **yes, keeping its address** (pool mode `static`) |

> **The old shared NAD `vm-underlay-10-66-3-0` is GONE** (deleted 2026-09-29, Whereabouts `.200–.220`).
> A manifest that still names it will sit in `FailedCreatePodSandBox` indefinitely — and worse, the
> failure looks like "NAD not minted yet" rather than a missing NAD, so check the name first. Every VM
> that was on it has moved to a pool claim. Nothing offers `networkName` without a pool any more.

**Find a pool** (cluster-scoped; **always use the full resource name** — Whereabouts already owns the plural
`ippools` (`ippools.whereabouts.cni.cncf.io`) in `kube-system`, so a bare `kubectl get ippools` can show you the
wrong objects or nothing):

```bash
kubectl get ippools.ipam.cubestack.io
```

```
NAME          SUBNET         START         END           GATEWAY       AGE
dev-ip-pool   10.66.3.0/24   10.66.3.200   10.66.3.230   10.66.3.254   6h23m
```

(That is the live set as of 2026-09-28 — `dev-ip-pool` is currently the **only** pool; a
`cubestack-static-v4` used to exist and is gone. More than one pool can exist on a subnet, so run the command
rather than trusting any listing, this one included.)

More than one pool can exist on a subnet; **use the one your admin designated** (`dev-ip-pool` here).
Which pool a VM uses is just the annotation value, so it is a per-VM choice, not a cluster-wide one.

A pool's `START`/`END` is the band you might get an address from; **you cannot pick which one** (the allocator
takes the lowest free address). The pool's mode matters for migration and is not in the default columns:

```bash
kubectl get ippools.ipam.cubestack.io <pool> -o jsonpath='{.spec.nadTemplate.ipam}{"\n"}'
```

`static` → the VM can live-migrate. `whereabouts` → it cannot, and a node drain may hang trying.

All three nodes — `10-66-3-43`, `10-66-3-46`, `10-66-3-47` — sit on the **same subnet** (`10.66.3.0/24`), so
any of them can host a VM and there is nothing to discriminate between. **Do not write a `nodeSelector` for the
underlay.** Older documents pinned a VM to a subnet with a node label plus a matching selector; that label is
now redundant and every manifest here omits the selector.

> **10.66.3.0/24 is the only live subnet** (re-checked 2026-09-29). The `10.66.2.0/24` subnet no longer
> exists at all — no node carries that label and its NAD `vm-underlay-10-66-2-0` is gone. If an older
> document offers you `10-66-2-0`, it is stale.

The shared `vm-underlay-10-66-3-0` NAD was **deleted on 2026-09-29**, once no VM or pod referenced it.
`dev-ip-pool` is now the only thing allocating on this subnet, and a pool claim is the only way to get an
underlay address.

## Five non-negotiable constraints (and why)

1. **The NAD is the only thing that decides the subnet.** Which subnet a VM lands in is decided by the multus
   `networkName` NAD reference — there is no node label to keep in step with it, and no `nodeSelector` to write.
   With a pool claim there is one thing to get right: the reference in
   `networks[].multus.networkName` must name **the same NAD the pool mints**, written as `namespace/name`.
   A VM whose `networkName` points at a NAD that does not exist sits in `FailedCreatePodSandBox` until the
   controller mints it (a few seconds), and forever if the claim then fails.
2. **Never assign an underlay IP yourself.** No static address in the guest, no hand-written NAD, no
   Whereabouts `ips` annotation. The guest stays on **DHCP** — KubeVirt answers it on the virt-launcher side —
   and the address comes from the pool. A pool's band **must not overlap** the shared NAD's Whereabouts window
   (`10.66.3.200–.220`) or another pool's band; the upstream guide calls this load-bearing, not hygiene.
   Overlap is what produces two hosts answering on one address, and on a `static` pool nothing refuses the
   duplicate — it is silent, and the only detector is the `DuplicateAddress` audit event. **If you find a pool
   whose band does overlap, raise it with the admin** — it is not something to work around by hand-editing.
3. **Root-disk PVC names must be globally unique within the namespace.** `dataVolumeTemplates[].metadata.name`
   becomes the PVC name directly; two VMs reusing the same root-disk name collide or even bind to the same disk.
   When creating a VM, change **all three together** to unique names: `metadata.name`,
   `dataVolumeTemplates[].metadata.name`, and `volumes[].dataVolume.name`.
4. **Disks must be shared** (`accessModes: ReadWriteMany` + `volumeMode: Block`, StorageClass
   `ceph-rbd-kubevirt`). This is the prerequisite for live migration; switching to `ReadWriteOnce` removes the
   VM's ability to migrate.
5. **Deletion is irreversible.** `reclaimPolicy: Delete` — deleting a VM/PVC removes the underlying RBD image.
   Always confirm with the user that data is backed up before deleting.

## Operational workflows

### 1. View / inspect current state

Overall view:

```bash
kubectl get vm,vmi -n default -o wide
kubectl get pvc -n default
kubectl get network-attachment-definitions -n default
kubectl get nodes -o wide
kubectl get iprequests.ipam.cubestack.io -A      # which VM holds which address
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

Reference manifest (8C/24Gi, on the 10.66.3.x subnet, address from a pool):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-myapp            # ⚠️ change to a unique VM name — it also names the claim and the NAD
  namespace: default
  labels:
    owner: myname         # ⚠️ replace with the user's own name — NOT "<username>", which is not a valid
                          #    label value and is rejected by the API server. Omit the label if unknown.
  annotations:
    ipam.cubestack.io/pool: dev-ip-pool      # REQUIRED — its presence is what triggers the claim.
                                             # Not magic: list the pools and use the one for your
                                             # environment (`kubectl get ippools.ipam.cubestack.io`).
    # ipam.cubestack.io/nad-name: vm-myapp-static # optional; defaults to <vm-name>-static
spec:
  runStrategy: Always       # Always=start on create; Halted=don't start; RerunOnFailure=auto-restart on failure
  dataVolumeTemplates:
  - metadata:
      name: vm-myapp-rootdisk    # ⚠️ root-disk PVC name, unique in the namespace
    spec:
      source:
        pvc:
          name: ubuntu-22.04-server-cloudimg-5.15.0-130-amd64.img   # DEFAULT golden image (see the facts table)
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
      # No nodeSelector: all three nodes are on 10.66.3.0/24, so any of them will do.
      # A device request (GPU / RoCE VF) is the only thing here that restricts placement.
      domain:
        cpu: { cores: 8 }
        resources:
          requests:
            memory: 24Gi      # REQUIRED — KubeVirt's webhook rejects a VMI with no memory declared
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
          networkName: default/vm-myapp-static   # ⚠️ MUST match the NAD the pool mints: <ns>/<vm-name>-static
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
kubectl get vm,vmi -n default -o wide   # expect an IP from the pool's band, NODE = a matching subnet node
```

**Then check the claim** — this is what actually tells you the address was assigned:

```bash
kubectl get iprequests.ipam.cubestack.io -n default vm-myapp-ip
kubectl get vmi vm-myapp -n default -o jsonpath='{.status.interfaces[*].ipAddress}{"\n"}'
```

```
NAME          POOL           ASSIGNED      NAD               PHASE   AGE
vm-myapp-ip   dev-ip-pool    10.66.3.203   vm-myapp-static   Bound   30s
```

`Bound` with an address is success. The claim is named `<vm-name>-ip`, lives in the VM's namespace, and is
**created and owned by the controller** — you did not create it and must not hand-write it.

**Four gotchas to explain when creating:**
- The VM briefly sits in **`FailedCreatePodSandBox`** on its first start, because the NAD is created *after* the
  VM. That is by design and self-healing — wait. If it is still there after a minute, the claim failed; read its
  condition (see Troubleshooting).
- `passwd` is **not** plaintext — it is a **crypt password hash**. One command, then move on:
  `openssl passwd -1 '<password>'` → `$1$...` (MD5). `-1` is accepted by cloud-init and PAM everywhere;
  on Linux `-6` (SHA-512) also works, but macOS LibreSSL has no `-6` flag. Quote the result in YAML —
  the hash contains `$`.
  **Do not verify it, and do not go shopping for a "stronger" one.** A local round-trip — python's or
  perl's `crypt`, both unreliable here, which is the documented reason to avoid them — proves only that
  the hash is self-consistent. It cannot prove the *guest* accepts the password, which also depends on
  cloud-init having applied it and on sshd drop-in ordering. The only real test is an actual SSH login,
  and the calling pipeline performs exactly that anyway. `$6$` over `$1$` buys nothing either: what
  bounds the risk is the password's entropy, not the KDF, so a wordlist entry falls to either. Both
  detours have cost minutes on a real run and changed no outcome — generate the hash, use it, and let
  the login test be the test.
  **More secure:** use `ssh_authorized_keys` and drop `passwd` / `ssh_pwauth`.
- **DNS must be written explicitly in `networkData`** — the NAD's DNS does not reach the guest automatically;
  without it the VM has no DNS.
- Ask the user for an `owner` label (per-person querying, accounting, cleanup). If they don't provide one,
  omit the label — never invent or reuse another user's label.

### 2b. Optional extras on create: RoCE NIC and MetaX GPU

Both are attached by **PCI passthrough** (硬件直通), both are optional, and either can be taken alone. Add the
relevant blocks to the §2 manifest before you apply.

⚠️ **Placement follows whoever advertises the resource** (verified 2026-09-29):

| Resource | Advertised by |
|---|---|
| `metax-tech.com/vfio-gpu` | **`10-66-3-43` only** (8) |
| `mellanox.com/roce_vf` | **all three nodes** — `43`, `46`, `47` (8 each) |

A resource request restricts placement to the nodes that advertise it, so the node must be Ready and schedulable.
For a GPU that pins the VM to 43 by itself. For RoCE it no longer does — **every node carries it now**, so the
request alone leaves the scheduler a free choice. When you need one specific node, pin it explicitly with
`nodeSelector: kubernetes.io/hostname: "10-66-3-46"`. That is the **only** selector worth writing — the
underlay needs none, since every node is on the same subnet.

| | MetaX GPU | RoCE NIC |
|---|---|---|
| Resource | `metax-tech.com/vfio-gpu` | `mellanox.com/roce_vf` |
| Advertised by | `10-66-3-43` only | all of `43`, `46`, `47` |
| Manifest location | `domain.devices.hostDevices[]` | `interfaces[]` + `networks[]` |
| What you supply | the VM fragment | just the VM fragment — the NAD is shared and already exists |
| Admin precondition | KubeVirt `permittedHostDevices` + MetaX operator | a `SriovNetworkNodePolicy` giving the node VFs |
| Live-migratable | **no** | **no** |

Any passthrough device — GPU or VF — makes the VMI non-migratable (`LIVE-MIGRATABLE: False` in
`kubectl get vmi -o wide`). That is expected, not a fault; the VM restarts in place instead of migrating.

#### GPU — `metax-tech.com/vfio-gpu`

**One `hostDevices` entry per GPU, each with a unique `name`.** Four GPUs means four entries:

```yaml
        devices:
          hostDevices:
          - deviceName: metax-tech.com/vfio-gpu
            name: gpu1
          - deviceName: metax-tech.com/vfio-gpu
            name: gpu2
          # ... one entry per GPU; `name` must be unique within the VM
```

**Changing the count later needs a VMI restart** — PCI devices cannot be hot-plugged:

```bash
kubectl patch vm <vm> -n default --type=merge -p '{"spec":{"template":{"spec":{"domain":{"devices":{"hostDevices":[
  {"deviceName":"metax-tech.com/vfio-gpu","name":"gpu1"},
  {"deviceName":"metax-tech.com/vfio-gpu","name":"gpu2"}
]}}}}}}'
kubectl delete vmi <vm> -n default     # REQUIRED — the template patch alone changes nothing in the guest
```

⚠️ **Patching the VM looks like success and does nothing.** The VM object updates immediately and the API server
reports the patch applied, but the **running VMI keeps its old shape** until it is recreated. Check both
separately — `.spec.template.spec.domain.devices.hostDevices` on the **vm**, then the same on the **vmi**. On a
pool claim the address survives this restart (see §3).

⚠️ **Do not use the node to count GPUs in use.** The node keeps reporting a flat **8** however many are
allocated — device plugins publish a fixed capacity and never decrement `allocatable`. Read the virt-launcher
pod's request instead:

```bash
kubectl get pod -n default -l vm.kubevirt.io/name=<vm> \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests.metax-tech\.com/vfio-gpu}{"\n"}'
```

**Verify inside the guest:**

```bash
lspci -nn | grep -i 9999      # one [9999:4000] Display controller per GPU
mx-smi                        # "Attached GPUs : N", each Available, with a UUID
```

⚠️ **No golden image carries the MetaX driver — you must install it in the guest, every time.** The host's metax
operator prepares the *host* side and nothing more; there is no driver injection at VM start, and no image is
"the one with the driver". Verified 2026-09-30 by mounting the default image's root filesystem directly: empty
`/opt`, no `mx-smi`, no `metax.ko`, no metax package, no installer in `/root` — a stock Ubuntu 22.04.5 cloud
image. (The `5.15.0-130` in its name is the kernel it ships, not evidence of a driver.)

So **`lspci` succeeding is not evidence the GPU is usable** — install the driver:

```bash
# inside the guest, as root
wget -O metax-driver-<ver>-deb-x86_64.run "<vendor URL>"   # MetaX download; the URL is pre-signed and expires
chmod +x metax-driver-<ver>-deb-x86_64.run
./metax-driver-<ver>-deb-x86_64.run -- -f                  # DKMS-builds `metax`, installs /opt/mxdriver
modprobe metax                                             # enough — no guest reboot needed
sudo mx-smi                                                # "Attached GPUs : N"
```

The install is a **DKMS build against the running kernel**, so it survives a guest restart; `metax` also carries
the `pci:v00009999d00004000` alias, so it autoloads from the PCI device on the next boot. Verified with
`metax-driver-3.9.0.14` (module `metax` 3.10.14, `mx-smi` 2.3.4) on Ubuntu 22.04 / kernel 5.15. An already
provisioned VM is the easy source for the installer — copy `/root/metax-driver-*.run` out of it rather than
re-fetching, since the vendor URL expires.

⚠️ **Re-install after a kernel upgrade.** DKMS compiles against the running kernel, so an apt kernel bump inside
the guest leaves the module unloadable until the driver is installed again. Put the install in cloud-init
`runcmd` for a VM you will keep, or pin the kernel.

⚠️ **Guest bus addresses are renumbered on every start.** The device plugin allocates from its free pool, so a
GPU that was `0b:00.0` can come back as `08:00.0`. `mx-smi` **UUIDs** are the stable identifier; never pin work
to a guest bus address.

#### RoCE NIC — `mellanox.com/roce_vf`

RoCE is RDMA over Ethernet, reached by passing an **SR-IOV Ethernet VF** through to the guest. Two parts: the
VM fragment, and in-guest configuration. **You do not create a NAD** — one shared NAD already exists.

**1. The shared NAD — reference it, do not make one.**

| | |
|---|---|
| NAD | `default/vm-roce-network` |
| Resource | `mellanox.com/roce_vf` — 8 VFs per node, on all three nodes |
| Type | `type: sriov`, `vlan: 0` |
| IPAM | deliberately **absent** |

**One NAD serves every RoCE VM.** A `sriov` NAD is only a *template* — which resource pool, which VLAN — and
nothing in it is claimed. The actual VF is allocated **per pod** by the SR-IOV device plugin, so N VMs on this
one NAD get N different VFs. The underlay is the opposite case: `cnv-bridge` + `ipam: static` bakes the address
into the NAD, so that one *must* be per-VM — which is exactly why the pool mints one per VM.

⚠️ **`ipam` is deliberately absent from it, not `{"type":"null"}`.** `sriov: {}` is PCI passthrough, so a NAD's
IPAM would configure only the virt-launcher pod's netns and never reach the guest, and the `null` IPAM binary
is not installed here anyway.

Restoring it is admin scope; the definition is:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vm-roce-network
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/resourceName: mellanox.com/roce_vf   # must match the node's resource exactly
spec:
  config: |-
    {"cniVersion":"1.0.0","name":"vm-roce-network","type":"sriov","vlan":0,"logLevel":"info"}
```

**2. The VM fragment** — a second interface, distinguished from the underlay by its `multus` network:

```yaml
        devices:
          interfaces:
          - name: underlay
            bridge: {}
          - name: roce
            sriov: {}                      # passthrough — not a bridge
      networks:
      - name: underlay
        multus:
          networkName: default/<vm>-static    # pool-minted underlay (see §2)
      - name: roce
        multus:
          networkName: default/vm-roce-network   # the shared NAD above
```

**3. The guest configures the VF itself**, via cloud-init `networkData` — matching **by driver, never by name**:

```yaml
          networkData: |
            version: 2
            ethernets:
              underlay:
                match: { driver: virtio_net }     # pool-minted bridge NIC — stays on DHCP
                dhcp4: true
                nameservers:
                  addresses: [223.5.5.5, 8.8.8.8]
              roce:
                match: { driver: mlx5_core }      # the passthrough VF
                dhcp4: false
                addresses: [10.57.128.21/24]      # separate fabric, no IPAM — see the note below
                mtu: 1500
```

⚠️ **Match by driver, not by interface name.** The VF's guest name shifts with the VM's device count: it is
`enp(8+N)s0` for N GPUs — `enp9s0` at 1 GPU, `enp10s0` at 2, `enp12s0` at 4, `enp13s0` at 5 — because passthrough
devices take PCI slots and predictable naming follows the slot. Anything that hardcodes a name breaks the moment
the GPU count changes. **If the NIC seems to have vanished after a restart, it was renamed** — check
`ip -br addr` before investigating further.

⚠️ The guest also needs `mlx5_ib`, which lives in `linux-modules-extra-$(uname -r)` and is **not installed by
default**. Without it there is no verbs device, however healthy the NIC looks. Install it in cloud-init
(`packages:`) and `modprobe mlx5_ib`.

**4. Verify inside the guest:**

```bash
ip -br addr                                          # the VF, carrying 10.57.128.x
ibv_devinfo | grep -E 'hca_id|link_layer|state'      # link_layer: Ethernet, state: PORT_ACTIVE
```

> **The RoCE address is not the underlay.** `10.57.128.0/24` is a separate L2 fabric with no pool and no IPAM,
> so it is the one place a static in-guest address is correct and does **not** breach Hard rule 4. The underlay
> still comes from the pool on DHCP; only the RoCE NIC is set by hand — and it is a per-VM choice, so take the
> next free address in the established sequence (the existing RoCE VMs used `.11`–`.13`; `.21` and `.22` are taken).

> **Do not use the `ib-vf-network` NAD.** It hands out an **InfiniBand** VF (`mellanox.com/mlx5_ib_vf`), and IB
> VFs are a dead end for a guest — the fabric's subnet manager does not issue LIDs to VF GUIDs, so the port
> never leaves `Down`. RoCE needs no subnet manager, which is exactly why it works where IB does not.

**5. Proving it end-to-end — a two-VM test.** One VM only proves the device exists. RDMA needs a peer, and the
peer should be on a **different node**, or you are measuring a loopback rather than the fabric. `10.57.128.0/24`
is flat, so two RoCE VMs on different nodes reach each other directly:

```bash
# on both guests: RoCEv2 is the IPv4-mapped GID (index 3), 0/1 are link-local
cat /sys/class/infiniband/<hca>/ports/1/gids/3        # -> ::ffff:10.57.128.x

# server, on the node-46 VM
ib_write_bw -d <hca> -i 1 -x 3 -F --report_gbits -D 20
# client, on the node-43 VM — the server's RoCE address, not its underlay one
ib_write_bw -d <hca> -i 1 -x 3 -F --report_gbits -D 20 10.57.128.22
```

`-x 3` picks the RoCEv2 GID, `-i 1` the port. Expect **~350–370 Gb/sec** between two VMs on the 400 Gb NICs.

⚠️ The **same device has two names**: the host calls it `mlx5_0`, the guest `rocep8s0` / `rocep13s0` — the
`roce` prefix plus the guest netdev name. Do not expect one name to work in both places.

⚠️ The guest's GID table can read **all zeros for the first minute or two** after first boot, because
`roce-up.sh` loads `mlx5_ib` *after* netplan has already assigned the address, so the driver misses the address
event. It populates on its own — re-read it before debugging.

> **A node only has RoCE VFs if an admin created a `SriovNetworkNodePolicy` for it** (43, 46 and 47 have one
> each — one policy per node, never one policy widened to cover several, because editing a policy re-syncs and
> reboots every node it matches). Extending it to a new node is **admin scope**, not something this skill should
> do: applying a policy **reboots the target node** — `disableDrain: true` suppresses the drain, not the reboot —
> and since `SriovOperatorConfig.spec.disableDrain` defaults to `false` it would cordon and evict first as well.
> The sequence is: set `disableDrain: true`, live-migrate the node's VMs away with a migration pinned by
> `addedNodeSelector`, apply the policy, wait for the reboot, restore `disableDrain: false`, migrate back.

> **Two timing traps when you add a node**, both of which look like failures and are not:
> `syncStatus` still reads `Succeeded` from the *previous* sync for the first minute after you apply, so a poll
> loop breaks instantly and looks like a no-op — require an `InProgress` transition before accepting `Succeeded`.
> And after the reboot the node briefly advertises **no** device resources at all (`roce_vf` absent, even
> `mlx5_ib_vf` reading `0`) until `sriov-device-plugin` restarts and re-registers; give it a minute before
> concluding the policy broke something. The expected end state is `roce_vf: 8` **and** `mlx5_ib_vf: 16`.

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

These are **hard** (not graceful) operations — the VMI is torn down or recreated. **On a pool claim the address
survives**: it lives in the minted NAD, not in the pod's sandbox, so the recreated pod attaches to the same
network and comes back on the same IP. That is the whole point of the pool path, and it is what the legacy
shared NAD cannot do — there the new pod re-requests a Whereabouts lease and the IP may change or be taken by
another VM in the meantime. For a graceful shutdown, run `sudo shutdown` inside the guest. (`virtctl stop/restart`
do graceful ACPI shutdown if it happens to be installed, but the skill doesn't require it.)

### 4. Connect to a VM

Primary method (no virtctl needed):

```bash
ssh ubuntu@<vmi-ip>                # password is the one set by cloud-init
```

VMs are on the underlay network — ping/ssh their subnet IP directly; **no** need to go through the Pod IP.

> Interactive serial console (`virtctl console`) and graphical VNC (`virtctl vnc`) need `virtctl`; they are optional
> extras, not required by this skill. Use SSH unless you specifically need console/VNC.

**When SSH says `Permission denied (publickey)` even though the key is in `authorized_keys`**, the key you planted
is corrupt. A single dropped character in the base64 blob is invisible to the eye and `authorized_keys` still
*looks* right — compare fingerprints rather than eyeballing, and **copy the key from `~/.ssh/id_ed25519.pub`
(or an existing `design/vm/**-cloudinit.yaml`), never retype or re-quote it from memory**:

```bash
ssh-keygen -lf <(sed -n '1p' <<< "$(ssh -o BatchMode=yes ubuntu@<ip> cat /home/ubuntu/.ssh/authorized_keys)")
#        vs
ssh-keygen -lf ~/.ssh/id_ed25519.pub
# "is not a public key file" on the left == a truncated blob; a real key is 68 chars, not 67
```

Password login will not rescue you: **it is off by default on these images**, and `ssh_pwauth: true` in your
cloud-init does *not* turn it on. Ubuntu drops two files in `sshd_config.d/`, and sshd reads them in lexical
order, so the later one wins:

```
/etc/ssh/sshd_config.d/50-cloud-init.conf        PasswordAuthentication yes   <- yours, applied
/etc/ssh/sshd_config.d/60-cloudimg-settings.conf PasswordAuthentication no    <- wins
```

SSH keys are the intended path; fix the key rather than the sshd config. To recover a VM you can no longer log
into, use the guest agent through the virt-launcher pod:

```bash
POD=$(kubectl get pod -n default -l vm.kubevirt.io/name=<vm> -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default $POD -c compute -- sh -c '
V="/usr/bin/virsh -c qemu:///session qemu-agent-command <ns>_<vm>"
PID=$($V "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"id\"],\"capture-output\":true}}" | sed -n "s/.*\"pid\":\([0-9]*\).*/\1/p")
sleep 2; $V "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"'
# out-data is base64 — decode it. The domain is always <namespace>_<vm-name>.
```

This needs no cloud login at all and works whenever `AgentConnected=True` on the VMI (qemu-guest-agent — which the
default image ships).

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

**Four prerequisites / gotchas to explain to the user:**
- All disks must be **RWX** RBD block PVCs (constraint #4). Migration control traffic runs over the Pod network
  (Calico); nodes must reach each other on TCP 49152/49153.
- **Any node can be the target.** All three nodes (`10-66-3-43`, `10-66-3-46`, `10-66-3-47`) are on
  `10.66.3.0/24` and no `nodeSelector` restricts the VM to one of them, so migration works between any pair.
  What *does* rule nodes out is a pinned `kubernetes.io/hostname`, or a GPU/VF request only some nodes satisfy
  (§2b) — and any passthrough device makes the VMI non-migratable anyway.
- **The address only survives if the pool is `static`.** Check the pool's mode first
  (`{.spec.nadTemplate.ipam}`). On a `static` pool migration just works and the guest keeps its address. On a
  `whereabouts` pool the migration **hangs in `Scheduling` forever**, with no timeout, and the event is
  `Could not allocate IP in range: ip: 10.66.3.221 / - 10.66.3.221` — a claim's NAD holds exactly one address,
  and the ledger cannot give it to two pods at once. If you see that, delete the migration object; there is
  nothing to wait for.
- **A VM on the legacy shared NAD migrates, but changes address.** Its Whereabouts range (`.200–.220`) has room
  for the target pod to take a *different* lease while the source still holds its own, so the migration
  completes and the VM comes up elsewhere on the subnet — old IP gone, and the old one can be handed to a new
  VM. Tell the user before migrating one; if the address must be stable, move the VM to a `static` pool first.

**Automatic migration on node drain**: by default VMs have **no** `evictionStrategy` set, so draining only cold-
restarts/interrupts them. To auto-migrate on drain, patch the VM (takes effect after the VM is restarted —
delete the VMI to force one, see "Lifecycle"):

```bash
kubectl patch vm <vm> -n default --type merge \
  -p '{"spec":{"template":{"spec":{"evictionStrategy":"LiveMigrate"}}}}'
```

⚠️ Note the path — `spec.template.spec.evictionStrategy`, **not** `spec.evictionStrategy`. KubeVirt's CRD is
structural, so a wrong field name is **silently pruned** by the apiserver: no error, no eviction strategy.
Confirm it landed (`-o jsonpath='{.spec.template.spec.evictionStrategy}'`), and leave it unset on a
`whereabouts` pool so a drain cannot trigger a migration that will hang.

### 7. Delete

```bash
kubectl delete vm <vm> -n default
```

**Always** re-confirm before deleting: it also removes the root-disk PVC / RBD image (`reclaimPolicy: Delete`);
data is unrecoverable.

**The address is released with it.** The chain is `VM → IPRequest → NAD`, all by `ownerReference`, so garbage
collection takes the claim and the minted NAD with the VM. No finalizers, and nothing left to clean up by hand.

To release an address **while keeping the VM**, you must stop referencing the NAD as well as drop the
annotation — remove `ipam.cubestack.io/pool`, delete the network from the VM's `networks` list, *then* delete
the `IPRequest`. Half-measures do nothing: removing the annotation alone leaves an existing claim untouched
(the VM controller is create-only), and deleting the NAD alone is reverted — the controller owns it and
re-mints it.

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
  one live OS disk (data-corruption risk). Constraint #3's global-uniqueness rule applies to the pool's base name
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
- On a subnet, each replica gets its own address. The pool claim's NAD name defaults to
  `<vm-name>-static` and is derived from **each replica's own VM name** (`<pool>-0`, `<pool>-1`, …), so N replicas
  get N distinct NADs and N distinct addresses — the template's annotations are inherited, and nothing collides.
  Watch the band size: a 20-address pool cannot host more than 20 replicas, and the 21st claim fails
  `RangeExhausted` rather than falling back to Whereabouts.
- ⚠️ **The template carries the pool ANNOTATION and NO network at all.** Put
  `ipam.cubestack.io/pool: <pool>` under `virtualMachineTemplate.metadata.annotations` and leave
  `spec.template.spec.networks[]` and `domain.devices.interfaces[]` **absent**. The admission policy
  sees the annotation on each replica the controller creates and injects that replica's own
  `default/<replica>-static` plus its bridge interface.
  **A template that names a `networkName` is handed to every replica verbatim** — all N members attach
  to one NAD. On a `static` pool nothing refuses the duplicate: they come up on the same address, the
  symptom is intermittent connectivity, and the only detector is the `DuplicateAddress` audit event.
  At `replicas: 1` this hides, which is how it survives review.
- ⚠️ **Editing `virtualMachineTemplate` RESTARTS every member.** It does not merely mark them
  `RestartRequired` — measured 2026-09-28: the pool controller's update was followed one second later
  by a graceful VMI shutdown, with a fresh VMI after. On a pool claim the address survives (it lives in
  the minted NAD, not the pod sandbox), so this is a restart, not an outage — but do not do it casually
  on a pool carrying real work.
- **Scaling up is clean; scaling back down is not free.** Scale-up adds members untouched. Scale-down
  deletes the chosen replicas *and* restarts the survivor, because the controller rewrites the
  remaining members' specs — so a `replicas: 2 → 1` costs a brief restart of the one you kept.
- Deleting a pool also deletes the VMs and replica PVCs it manages (DV `reclaimPolicy: Delete`); confirm first.

```bash
kubectl get virtualmachinepool -n default
kubectl get vm -n default -l app=<pool>
kubectl patch virtualmachinepool <pool> -n default --type merge -p '{"spec":{"replicas":5}}'   # scale up
kubectl patch virtualmachinepool <pool> -n default --type merge -p '{"spec":{"replicas":2}}'   # scale down (random delete by default, see above)
kubectl delete virtualmachinepool <pool> -n default     # also deletes the managed VMs
```

### 9. Day-2 address work (pool claims)

**Where is an address? / what is free?**

```bash
kubectl get iprequests.ipam.cubestack.io -n <namespace>     # all claims in a namespace
kubectl get ippools.ipam.cubestack.io <pool>                # the band
kubectl get iprequests.ipam.cubestack.io -A | grep <pool>   # what is taken from it
```

`PHASE` is `Pending`, `Bound` or `Failed`. There is no "reserve then allocate" step — **creating the claim is
the allocation**, so there is nothing to check before you create a VM. The allocator takes the lowest free
address, so a fresh claim reliably lands at the bottom of what is left. You cannot request a specific address;
if you need a reserved one, that is a smaller pool, not a field.

**Move a VM to a different pool or NAD name.** Editing the annotation on a VM that already has a claim **does
nothing** — the VM controller is create-only, it will not patch the VM or an existing claim, and it emits an
event saying the change was ignored. The escape hatch is to delete the claim so it is recreated from the VM's
*current* annotations:

```bash
kubectl -n <ns> delete iprequest <vm>-ip
```

This also deletes the NAD the claim owns. **If the new NAD name differs, update the VM's `networkName` at the
same time** or the VM will be unable to start. If the recreated claim comes back `Failed` with `NADNotOwned`,
the old NAD had not been collected yet — delete the leftover NAD and the claim retries and succeeds.

**Do not hand-edit the minted NAD.** The controller owns it and re-mints it; an edit silently reverts. The
minted NAD also carries **no annotations** — the hand-written `vm-underlay-10-66-3-0` carried
`k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br0` (that NAD is deleted now, so you cannot
compare against it), and a minted NAD has nothing. Leave it alone: it works without. If a VM ever fails with
a resource error, that annotation is the first difference to check against a VM that works.

**Audit findings** (for anything a claim's condition does not explain) arrive as `Warning` events every 10 min:

```bash
kubectl get events -A --field-selector reason=DuplicateAddress   # 2 VMs on 1 address — silent on a static pool
kubectl get events -A --field-selector reason=OrphanedNAD
kubectl get events -A --field-selector reason=PoolDeleted
```

### 10. Publish a golden image (upload a local disk)

To turn a disk image you have locally into a cloneable base — the same shape as the four images in the facts
table — create an **upload** DataVolume, then push into it. **No `virtctl` needed**: the upload API is plain
HTTPS, so `kubectl` plus `curl` covers it. (Verified end-to-end 2026-09-30.)

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-24.04-gpu-img        # this name is what later VMs clone from
  namespace: default
spec:
  source:
    upload: {}                      # what marks it as an upload target
  storage:
    accessModes: [ReadWriteOnce]
    storageClassName: ceph-rbd-kubevirt-immediate   # see below — NOT ceph-rbd-kubevirt
    volumeMode: Block
    resources:
      requests:
        storage: 30Gi               # >= the image's VIRTUAL size, not the file size
```

- **`ceph-rbd-kubevirt-immediate`, not `ceph-rbd-kubevirt`.** A golden image is never attached to a running VM,
  so the usual `WaitForFirstConsumer` class leaves the DV `Pending` forever with nothing to trigger it.
- For a qcow2 source the file size is much smaller than what the disk needs — check
  `qemu-img info <image> | grep 'virtual size'` first.

```bash
# 1. wait for UploadReady — uploading before this fails
kubectl -n default get dv ubuntu-24.04-gpu-img -w     # Pending -> UploadScheduled -> UploadReady

# 2. the proxy is a bare ClusterIP with no route/override, so it must be forwarded
#    explicitly. Leave this running.
kubectl -n cdi port-forward svc/cdi-uploadproxy 9443:443     # terminal 1

# 3. mint an upload token and push the image in (terminal 2)
TOKEN=$(kubectl create -f - -o jsonpath='{.status.token}' <<'EOF'
apiVersion: upload.cdi.kubevirt.io/v1beta1
kind: UploadTokenRequest
metadata:
  name: upload-ubuntu-24.04-gpu-img        # any name
  namespace: default
spec:
  pvcName: ubuntu-24.04-gpu-img            # must match the DataVolume/PVC
EOF
)

curl -k -X POST -H "Authorization: Bearer $TOKEN" \
  --data-binary @./ubuntu-24.04-server-cloudimg-amd64.img \
  https://127.0.0.1:9443/v1beta1/upload

kubectl -n default get dv ubuntu-24.04-gpu-img                # PHASE: Succeeded, 100.0%
```

**Two gotchas, both of which cost a round each:**

- **The token exists only in the response to the create call.** `UploadTokenRequest` is **create-only** —
  `kubectl get utr` returns `MethodNotAllowed`, and the object never appears in `get`/`list`. A recipe that
  says "create it, then read `.status.token`" does not work; capture it from the create, as above.
- **Pipe the token straight into `curl`.** Do not write it to a file — it is a live credential. It is
  short-lived and minted per attempt, so a failed upload simply re-mints one.

`-k` because the proxy's cert is self-signed. A failed upload leaves the DV at `UploadReady`, so just re-run
the create+curl pair.

**`virtctl image-upload` is exactly this, wrapped** — and it needs the same port-forward (`--uploadproxy-url
https://127.0.0.1:9443 --insecure --no-create`), so it saves nothing but the token plumbing.

**Never attach a golden image as a writable root disk** — clone it (`source: {pvc: {...}}`, §2). Its
`reclaimPolicy: Delete` means deleting the base destroys it and every future clone source.

## Troubleshooting quick reference

| Symptom | Check |
|---------|-------|
| VMI stuck in `Scheduling` | `kubectl describe vmi <vm>` for events; the usual causes are a pinned `kubernetes.io/hostname`, or a GPU/VF request no Ready node advertises |
| `FailedCreatePodSandBox` for a few seconds at first start | Normal — the NAD is minted after the VM. Wait |
| Still there after a minute | The claim failed and no NAD was minted — read its condition (rows below) |
| Claim `Failed`, reason `PoolNotFound` | Pool name is wrong, or you gave a namespace — `IPPool` is **cluster-scoped**. `kubectl get ippools.ipam.cubestack.io` (full resource name) |
| Claim `Failed`, reason `TemplateAbsent` | The pool has no `nadTemplate` — it allocates but mints nothing. Use a pool that mints networks |
| Claim `Failed`, reason `NADNotOwned` / `NADNameTaken` | Something else already holds that NAD name. Change `ipam.cubestack.io/nad-name`, or delete the other object |
| Claim `Failed`, reason `RangeExhausted` | The band is full. **Admin** widens `spec.range`, or you delete an unused claim |
| Claim `Failed`, reason `RangeInvalid` | The *pool* is unusable (bad order/gateway) — **admin** fixes it; check its `Available` condition |
| VM has no IP / no network | `networkName` must be `namespace/name` and must match the minted NAD; confirm `dhcp4: true` in guest `networkData` |
| No DNS in the VM | DNS must be set explicitly in `networkData`; the NAD's DNS does not reach the guest |
| Two VMs answer on one address, intermittently | `DuplicateAddress` — on a `static` pool nothing refuses the duplicate. **Admin** checks the band against the Whereabouts window; the event names both claims |
| Migration hangs in `Scheduling` | The pool is `whereabouts` (or the VM is on the shared NAD). Use a `static` pool; delete the stuck migration |
| Cannot migrate | Root disk must be an RWX RBD block PVC, and the target node must be able to host the VM — a pinned `kubernetes.io/hostname` rules nodes out; a GPU or VF passthrough rules out migration entirely (§2b) |
| VM says more GPUs but the guest has fewer | The template was patched without recreating the VMI — PCI devices cannot be hot-plugged. `kubectl delete vmi <vm>` (§2b) |
| `lspci` shows the GPU but `mx-smi` does not exist | Expected on a fresh VM — **no golden image carries the driver**. Install it in the guest (§2b) |
| `mx-smi` worked, then broke after an apt upgrade | DKMS rebuilds per kernel, so a guest kernel bump leaves the module unloadable. Re-run the installer, or pin the kernel (§2b) |
| SSH: `Permission denied (publickey)` although the key is in `authorized_keys` | A dropped character in the key blob — it still *looks* right. Fingerprint both sides (§4) |
| SSH: password login refused even with `ssh_pwauth: true` | `60-cloudimg-settings.conf` sorts after `50-cloud-init.conf` and re-disables it. Use an SSH key (§4) |
| Locked out of a VM entirely | Use the guest agent via the virt-launcher pod — no login needed (§4) |
| Node reports 8 `vfio-gpu` but they are all allocated | `allocatable` never decrements. Read the virt-launcher pod's request, never the node (§2b) |
| GPU or RoCE VM stuck in `Scheduling` | No Ready node advertises the requested resource. GPUs are on **43 only**; RoCE VFs on **all three nodes**. Check the node's `allocatable`, and check a pinned `kubernetes.io/hostname` selector has not excluded every node that has it |
| RoCE NIC "disappeared" after a restart | It was renamed — the VF name tracks the GPU count as `enp(8+N)s0`. Check `ip -br addr`; match by driver in config, never by name (§2b) |
| RoCE interface exists but `ibv_devinfo` shows nothing | `mlx5_ib` is not loaded — install `linux-modules-extra-$(uname -r)` and `modprobe mlx5_ib` (§2b) |
| VMI reports `LIVE-MIGRATABLE: False` | Expected — any passthrough device (GPU or VF) prevents live migration (§2b) |
| Editing the pool annotation did nothing | By design — the VM controller is create-only. Delete the `<vm>-ip` `IPRequest` so it is rebuilt from the current annotations |
| Deleting or hand-editing the NAD did not stick | The controller owns it and re-mints it. Nothing to fix |
| Snapshot fails: `provided secret is empty` / `clusterID must be set` / `snapshot feature gate not enabled` | Low-level VSC/feature-gate issue; admin handles it (admin guide §4) |
| Creating a pool rejected: `vm pool feature gate not enabled` | Admin hasn't enabled the `VMPool` gate (admin guide §5) |

Why a claim failed is in its **condition**, not in a log:

```bash
kubectl get iprequest -n <ns> <vm>-ip \
  -o jsonpath='{.status.conditions[*].reason}{"  "}{.status.conditions[*].message}{"\n"}'
```

## Hard rules

1. Trust only the real output of `kubectl`; **never fabricate** VM state, IPs, or resources.
2. Confirm with the user before destructive operations (`delete`, a `stop` that affects business, migration), and
   explain the consequences (especially `reclaimPolicy: Delete` removing data).
3. If unsure about subnet / pool / NAD / ownership, query read-only first, then act.
4. **Never hand-assign an underlay IP.** No static address in the guest, no hand-written NAD (the RoCE NAD is
   not one you write — it is the shared `default/vm-roce-network`, §2b), no Whereabouts
   `ips` annotation. Name a pool and let the controller assign; the guest stays on DHCP. If the user asks for a
   specific address, explain that the pool allocator decides (lowest free) and that a reserved address is a
   smaller pool — an admin decision, not a VM field. *(The RoCE VF in §2b is the one exception, and it is not
   really one: `10.57.128.0/24` is a separate fabric with no pool and no IPAM, so its address is set inside the
   guest by design. The underlay rule still applies to that VM's underlay interface.)*
5. **Using a pool is user scope; creating one is not.** `IPPool` is cluster-scoped and shared by every VM owner,
   so a wrong band can collide with the Whereabouts window and take out VMs that are not yours. If no suitable
   pool exists, hand it to the admin (admin guide); do not create, patch, or widen a pool yourself.
6. Full YAML lives in `kubevirt-vm-user-guide.md`; lower-level details (networking, storage, snapshot
   infrastructure, feature gates) live in `kubevirt-cluster-admin-guide.md` — admin scope, this skill does not
   do them and must not steer the user to do them.
