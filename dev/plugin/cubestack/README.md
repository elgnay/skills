# cubestack-install — CubeStack Cluster Install Skill

A Claude Code skill for installing a single- or multi-node **CubeStack** cluster onto KubeVirt VMs in the SUANOVA cluster. The installer runs inside a bootstrap **pod** and SSHes into the target VMs to run kubespray.

> Core file: `cubestack-install.md` (SKILL.md).

**Scope boundary**: this skill installs a CubeStack *cluster* end to end, but it does **not** create VMs. All VM/pool mechanics belong to the sibling [`suanova-dev-vm`](../kubevirt/suanova-dev-vm.md) skill, which this one delegates to.

---

## Features

| Aspect | Behavior |
|--------|----------|
| **Interaction** | Asks the user **exactly once** (Step 0: prerequisites + one confirmation), then runs Steps 1–7 **unattended** — no per-step approvals |
| **Recovery** | Failed steps apply their documented, automated recovery instead of prompting. It stops and reports only for an external blocker (e.g. a feature gate only an admin can enable) |
| **Topology** | Single-node (`cubestack<N>`) or multi-node (`VirtualMachinePool` `cubestack<N>` with `replicas` = node count → VMs `cubestack<N>-0/-1/…`) |
| **Execution** | Subagent-per-phase; the orchestrator only collects prerequisites, spawns subagents, relays results, and reports progress |
| **Cleanup** | The bootstrap pod is **ephemeral** — auto-deleted once Step 7 verifies the cluster is healthy |

---

## How it works

| Step | What happens |
|------|--------------|
| **Step 0** | The only user interaction — resolve prerequisites, then one confirmation |
| **Step 1** | Provision VMs via the sibling `suanova-dev-vm` skill |
| **Step 2** | Create the installer pod *(runs concurrently with Step 1)* |
| **Step 3** | Verify the environment from the pod — VM SSH, MinIO, Harbor, `sshpass` |
| **Step 4** | Generate and byte-verify `cluster.conf` |
| **Step 5** | Fetch the ~22GiB offline package set from MinIO |
| **Step 6** | Deploy — kubespray plus the enabled addon modules |
| **Step 7** | Verify cluster health, then auto-delete the installer pod |

Steps 1 and 2 are independent (the pod only needs the target **subnet label**, not the VMs), so they run concurrently and join at Step 3.

---

## Measured timing

Two verified 3-node installs (8 vCPU / 24 GiB per VM), started from a clean state:

| Step | Run 1 (10.66.3.0/24) | Run 2 (10.66.2.0/24) |
|------|----------------------|----------------------|
| S1 — provision VMs | ~3 m 17 s | ~2 m 03 s |
| S2 — installer pod | ~32 s | ~27 s |
| S3 — verify env | ~1 m 00 s | ~47 s |
| S4 — `cluster.conf` | ~1 m 12 s | ~2 m 25 s |
| S5 — fetch offline | ~4 m 19 s | ~1 m 57 s |
| S6 — deploy | ~12 m 26 s | ~13 m 04 s |
| S7 — verify + cleanup | ~11 s | ~10 s |
| **Total** | **~24 m 50 s** | **~25 m 42 s** |

**Deploy (S6) dominates at roughly half the wall time.** Run 1's S5 includes a failed fetch plus its recovery; once the Step 5 prerequisite is met the fetch lands first try (run 2).

---

## Prerequisites

- **kubectl** and a kubeconfig that can reach the SUANOVA KubeVirt cluster
- The CubeStack installer image reachable from the cluster (`harbor.isuanova.com/cubestack/cubestack-installer-cli:latest`)
- Access to the internal **MinIO** endpoint holding the offline packages (~22GiB)
- **Multi-node only:** the alpha `VMPool` feature gate enabled — otherwise pool creation is rejected. This is cluster-admin scope and the skill stops and reports rather than falling back to N separate VMs.
- Claude Code (the host for this skill)

---

## Installation

### Option 1: Symlink (recommended — changes take effect immediately)

```bash
# 1. Clone the repo
git clone git@github.com:suanova/skills.git suanova-skills
cd suanova-skills

# 2. Create the entry in ~/.claude/skills/ (skill name = directory name)
mkdir -p ~/.claude/skills/cubestack-install
ln -s "$PWD/dev/plugin/cubestack/cubestack-install.md" ~/.claude/skills/cubestack-install/SKILL.md
```

After installing via symlink, edits to the skill file take effect on the **next message** — no restart needed.

### Option 2: Copy (offline / don't want to track repo changes)

```bash
mkdir -p ~/.claude/skills/cubestack-install
cp dev/plugin/cubestack/cubestack-install.md ~/.claude/skills/cubestack-install/SKILL.md
```

---

## Verifying the install

1. After restarting / reopening a Claude Code session, type `/` — `cubestack-install` should be listed.
2. Say something like "**install a 3-node cubestack cluster**" — the skill triggers automatically (its description carries the trigger phrases).

---

## Usage

### Trigger phrases (natural language works)

> "install cubestack" / "deploy a cubestack cluster" / "create a 3-node cubestack box" / "装一套 cubestack" / "spin up cubestack on the 10.66.3 subnet"

### What it asks you (Step 0 — the only question round)

| Item | Default |
|------|---------|
| Number of nodes | `1` |
| VM shape | 8 vCPU / 24 GiB RAM / 80 GiB root disk |
| Subnet | Auto-selected by free capacity; all VMs share one subnet |
| VM owner label | `owner=<your OS username>` |
| SSH password | `ubuntu` |
| Service expose mode | `nodeport` (no MetalLB pool needed) |
| Node roles (multi-node) | `cubestack<N>-0` = master; `-1…` = workers |

Answer only what you care about — anything you skip uses the default. You get **one** confirmation, and then it runs to completion.

---

## Cluster facts at a glance

| Item | Value |
|------|-------|
| KubeVirt / CDI | v1.8.4 / v1.65.0 |
| Storage | Rook/Ceph RBD, StorageClass `ceph-rbd-kubevirt` (RWX block) |
| Golden images | `default` ns: `ubuntu-22.04/24.04/26.04-server-amd64-img` |
| Subnets | `10.66.2.0/24` (NAD `vm-underlay-10-66-2-0`, 1 node — no migration), `10.66.3.0/24` (NAD `vm-underlay-10-66-3-0`, 2 nodes — migratable) |
| VM IPs | Whereabouts IPAM, allocated at creation — never assign or reserve manually |

---

## Safety notes

- **Deletes are irreversible.** Deleting a VM or pool removes its RBD PVC and the underlying image. The skill re-confirms before any destructive VM/pool action.
- **All nodes should share one subnet.** This enables live migration and keeps MetalLB/pod networking on a single L2 domain. Splitting subnets is possible but adds constraints.
- **Credentials are never written inline.** Tool-layer redaction turns secrets into a literal `***`; the skill writes config through a values file and byte-verifies the result on disk before proceeding.
- **The alpha `VMPool` gate** is required for multi-node installs — check with your cluster admin first.

---

## Reference docs

- `cubestack-install.md` — this skill (SKILL.md), the full procedure
- [`../kubevirt/suanova-dev-vm.md`](../kubevirt/suanova-dev-vm.md) — the sibling VM skill that provisions the target machines
- [`../kubevirt/README.md`](../kubevirt/README.md) — KubeVirt VM management (create / inspect / migrate / delete)
