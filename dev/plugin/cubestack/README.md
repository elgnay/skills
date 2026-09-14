# cubestack-install — CubeStack Cluster Install Skill

A Claude Code skill for installing a single- or multi-node **CubeStack** cluster onto KubeVirt VMs in the SUANOVA cluster. The installer runs inside a bootstrap **pod** and SSHes into the target VMs to run kubespray.

> Core file: `cubestack-install.md` (SKILL.md), driven by the deterministic scripts in
> `scripts/`. Both must be installed (see [Installation](#installation)).

**Scope boundary**: this skill installs a CubeStack *cluster* end to end, but it does **not** create VMs. All VM/pool mechanics belong to the sibling [`suanova-dev-vm`](../kubevirt/suanova-dev-vm.md) skill, which this one delegates to.

---

## Features

| Aspect | Behavior |
|--------|----------|
| **Interaction** | Asks the user **exactly once** (Step 0: prerequisites + one confirmation), then runs Steps 1–7 **unattended** — no per-step approvals |
| **Recovery** | Failed steps apply their documented, automated recovery instead of prompting. It stops and reports only for an external blocker (e.g. a feature gate only an admin can enable) |
| **Topology** | Single-node (`cubestack<N>`) or multi-node (`VirtualMachinePool` `cubestack<N>` with `replicas` = node count → VMs `cubestack<N>-0/-1/…`) |
| **Execution** | One script call per step. No subagents — spawning one to make a single call costs more than the call. ~10–12 model round-trips per run |
| **Failure handling** | Each script emits one machine-readable verdict line with a `recover=` verb from a closed set of six; the model executes the verb rather than diagnosing from prose |
| **Cleanup** | The bootstrap pod is **ephemeral** — auto-deleted once Step 7 verifies the cluster is healthy |
| **Run identity** | A run is scoped to what it installs (`--run cubestack<N>`): its own run dir, stamps, retry counters, **and its own bootstrap pod name**. Two installs can therefore run at the same time without applying to, reusing, or deleting each other's pod |
| **Storage** | Optional **external Ceph CSI import** (Rook external mode) — consume an existing Ceph outside the cluster for RBD / CephFS. Opt-in, off by default |

---

## How it works

| Step | What happens | Script |
|------|--------------|--------|
| **Step 0** | The only user interaction — resolve prerequisites, then one confirmation | `preflight` |
| **Step 1** | Provision VMs via the sibling `suanova-dev-vm` skill, then confirm by exact name | `vm-ready` |
| **Step 2** | Create the installer pod, named for this run *(runs concurrently with Step 1)* | `pod-up` |
| **Step 3** | Verify the environment from the pod — VM SSH, MinIO, Harbor, `sshpass` | `env-probe` |
| **Step 4** | Generate and byte-verify `cluster.conf` | `configure` |
| **Step 5** | Fetch the ~22GiB offline package set from MinIO | `fetch-offline` |
| **Step 6** | Deploy — kubespray plus the enabled addon modules, then wait | `deploy` + `deploy-wait` |
| **Step 7** | Verify cluster health, then auto-delete the installer pod | `verify` + `pod-down` |

Steps 1 and 2 are independent (the pod only needs the target **subnet label**, not the VMs), so they run concurrently and join at Step 3. `diagnose <CODE>` produces a bounded excerpt when something fails.

Two mechanical details worth knowing: `deploy-wait` must run as a **background task** (a deploy outlasts the 600 s foreground ceiling), and completion is **process exit, never the `✅` banner** — the banner is cosmetic and is the first thing lost if a deploy is killed at the end.

---

## Concurrent installs

Every script takes `--run <run-id>`, and `preflight` mints that id from the resolved target — `cubestack3` for the first free `cubestack<N>` index. One id scopes everything the run owns:

```
--run cubestack3  →  ~/.cubestack/runs/cubestack3/     run.env, stamps, attempts, verdicts, logs
                  →  pod cubestack-install-cubestack3   the bootstrap host
```

Two installs started at the same time resolve different indices, so they get different run dirs and different pod names, and neither can reach the other's state.

**There is no fixed pod name and no shared default run dir.** Both were removed deliberately. With a fixed name, the second run's `kubectl apply` targets the first run's pod, and because `kubevirt.io/subnet` is immutable that path *deletes and recreates* it — discarding the ~22 GiB offline fetch and the `cluster.conf` the first run had already paid for. Discovery had the same problem from the other side: "newest pod matching the prefix" cannot tell one run's pod from another's.

Reuse still works, and still skips the fetch — *within* a run, where the name is stable, a re-invocation finds its own pod (`reused=1 fetch=present`) and takes it as-is. To point a run at a pod it did not name, pass `--pod <name>` explicitly; the name is then recorded in `run.env` so later steps follow it.

Omitting `--run` is a **loud failure**, not a fallback: the run dir is not guessed and another run's state is never adopted.

---

## Measured timing

Three verified installs (8 vCPU / 24 GiB per VM), started from a clean state. Run 3 is the
1-node external-Ceph run; the per-step figures are the scripts' own duration, measured to a
`timings.tsv` in the run dir.

| Step | Run 1 (3 nodes, 10.66.3.0/24) | Run 2 (3 nodes, 10.66.2.0/24) | Run 3 (1 node + external Ceph) |
|------|----------------------|----------------------|----------------------|
| S1 — provision VMs | ~3 m 17 s | ~2 m 03 s | 31 s |
| S2 — installer pod | ~32 s | ~27 s | 5 s |
| S3 — verify env | ~1 m 00 s | ~47 s | 9 s *(two probes)* |
| S4 — `cluster.conf` | ~1 m 12 s | ~2 m 25 s | 6 s |
| S5 — fetch offline | ~4 m 19 s | ~1 m 57 s | 1 m 22 s |
| S6 — deploy | ~12 m 26 s | ~13 m 04 s | 15 m 54 s |
| S7 — verify | ~11 s | ~10 s | 52 s |
| S8 — cleanup | *(same call)* | *(same call)* | 43 s |
| **Total** | **~24 m 50 s** | **~25 m 42 s** | **~19 m 42 s** |

**Deploy (S6) dominates at roughly half the wall time.** Run 1's S5 includes a failed fetch plus its recovery; once the Step 5 prerequisite is met the fetch lands first try (run 2).

Three things in run 3 worth reading rather than skimming:

- **Deploy got *slower* on one node than on three** (15 m 54 s vs ~13 m). The external Ceph
  import is the reason: the Rook operator, the CSI drivers, the `CephConnection` /
  `ClientProfile` and the seven StorageClasses are all real work that scales with the
  *import*, not with the node count. A single-node cluster is not a cheaper Ceph consumer.
- **S3 runs twice.** `configure` deliberately invalidates the `env-ok` stamp (a config change
  can move the SSH password the stamp attests), so the probe is re-run before the deploy.
  9 s here is the two probes together.
- **S7 + S8 are lopsided against runs 1–2** because they were a single hand-run call there.
  `verify` spends a 30 s node-settling re-pass — kubelet is routinely not `Ready` in the
  seconds after the deploy exits, and failing on that would be a false negative.

**Script time is not wall time.** Run 3's wall clock was 29 m 45 s against 19 m 42 s of
script time; the ~10 m gap was model-side analysis of the installer while *writing* the
external-Ceph support. On a normal run the two are much closer — the scripts are what the
model waits on.

---

## Optional: external Ceph storage

By default the cluster gets **no** Ceph storage. Ask for it and the installer makes the
new cluster a **Rook external-mode consumer** — it runs the Rook operator + CSI drivers
and consumes an **existing Ceph that lives outside the cluster**, without deploying any
mon/osd/mgr itself:

| Setting | Value | Meaning |
|---------|-------|---------|
| `CEPH_ENABLED` | `false` | No Ceph storage base is deployed in this cluster |
| `CEPH_CSI_ENABLED` | `true` | The module's **gate** — enable the CSI drivers (RBD / CephFS) |
| `CEPH_MODE` | `external` | Consume an external Provider, not an in-cluster Ceph |

**The recommended path is the official one: point `preflight` at the Provider's exported
`external-ceph.env`** — the file whose content the Provider's external-Ceph import guide
documents, saved verbatim under that name (the guide's §3).

```bash
"$S/preflight" --nodes 1 --minio-ep http://<host>:9000 \
  --external-ceph-env /path/to/external-ceph.env
```

The env file already carries the monitors, the CephX keyring, the CSI secrets, the pool and
file-system names and the RGW endpoint, so the only thing the values file needs is
`CEPH_MODE='external'`. `configure` places the file at
`deployments/config/external-ceph.env` in the pod — where the installer auto-detects and
**sources** it — hash-verifies the copy, and leaves it there for the deploy to read.

> The key is `CEPH_MODE`, **not** `CEPH_NODE` — there is no `CEPH_NODE` key in the installer,
> and setting it does nothing, silently. `CEPH_NODES` / `CEPH_NODE_LABEL` are unrelated
> (internal-mode OSD placement).

**Hand-filled fallback.** Without an env file the Provider can still be configured by hand,
and then `CEPH_MONITORS` + `CEPH_KEYRING` are required. The RBD pool/user and the CephFS
filesystem/data pool are optional — on that path **setting `CEPHFS_FS` is what turns CephFS
on**, and it then also requires `CEPHFS_DATA_POOL`.

Give the user *provisioning* caps either way: the installer wires one key to **both** the CSI
node and provisioner secrets, so a read-only user (Rook's `client.healthchecker`)
configures cleanly and then fails every PVC. Step 7 verifies the `CephConnection` +
`ClientProfile`, the CephCluster reaching `Connected`, the RBD / CephFS StorageClasses, and
the CSI secrets' `userID`. These checks switch on automatically for a run that recorded an
import — you do not have to remember a flag.

> **RGW / object storage.** In *internal* mode the installer creates a CephObjectStore. On
> the **official external path** it additionally consumes the Provider's RGW at its own
> endpoint, creating the bucket StorageClass and the Model-repository ObjectBucketClaim when
> the env file carries RGW keys. An external Provider's RGW is never *configured* here.
>
> **Keyrings and CSI secrets are real secrets** — the env file and the values file are never
> committed, not to this repo and not into the skill. Only placeholders appear in the docs.

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
# 3. Link the scripts too — the skill is script-backed and cannot run without them
ln -s "$PWD/dev/plugin/cubestack/scripts" ~/.claude/skills/cubestack-install/scripts
```

> **Both symlinks are required.** The skill drives deterministic scripts that live in
> `scripts/` beside the markdown. Only `SKILL.md` is loaded as the skill body, so without
> the second symlink the scripts are not reachable at the path the skill invokes them by
> (`<skill-base>/scripts/<name>`) and every step fails immediately.

After installing via symlink, edits to the skill file take effect on the **next message** — no restart needed.

### Option 2: Copy (offline / don't want to track repo changes)

```bash
mkdir -p ~/.claude/skills/cubestack-install
cp dev/plugin/cubestack/cubestack-install.md ~/.claude/skills/cubestack-install/SKILL.md
cp -R dev/plugin/cubestack/scripts ~/.claude/skills/cubestack-install/scripts
```
(Unlike the symlink form, a copy must be repeated after every change to the scripts.)

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
| External Ceph CSI | **Disabled** (opt-in) — when enabled, supply the path to the Provider's exported `external-ceph.env` (the hand-filled mon + keyring route still works but is no longer the recommended one) |

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
