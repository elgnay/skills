# cubestack-install — k8s box → cubestack box

A Claude Code skill for building a **cubestack box** on KubeVirt VMs in the SUANOVA cluster: a **k8s box** first, then the platform on top of it. The installer runs inside a bootstrap **pod** and SSHes into the target VMs to run kubespray.

> Core file: `cubestack-install.md` (SKILL.md), driven by the deterministic scripts in
> `scripts/`. Both must be installed (see [Installation](#installation)).

**Scope boundary**: this skill builds both boxes end to end, but it does **not** create VMs. All VM/pool mechanics belong to the sibling [`suanova-dev-vm`](../kubevirt/suanova-dev-vm.md) skill, which this one delegates to.

---

## The two boxes

| Term | What it is |
|------|------------|
| **k8s box** | Steps 1–6 + `verify` (+ `mount-models` when asked for): N VMs running a verified Kubernetes cluster with the enabled addons. **No CubeStack platform.** |
| **cubestack box** | That k8s box **plus** `cubestack-operator` and a `CubeStackCluster` CR, applied and Ready — Step 7's `operator-up` + `operator-wait`. |

> **`cubestack box = k8s box + cubestack-operator`**

`verify` is the boundary: it proves the k8s box, and its `verify-ok` stamp is the precondition `operator-up` gates on. `--no-operator` stops the run there and leaves you a k8s box. The full definitions are in [`cubestack-install.md`](cubestack-install.md).

---

## Features

| Aspect | Behavior |
|--------|----------|
| **Interaction** | Asks the user **exactly once** (Step 0: prerequisites + one confirmation), then runs Steps 1–7 **unattended** — no per-step approvals |
| **Recovery** | Failed steps apply their documented, automated recovery instead of prompting. It stops and reports only for an external blocker (e.g. a feature gate only an admin can enable) |
| **Topology** | Single-node (`cubestack<N>`) or multi-node (`VirtualMachinePool` `cubestack<N>` with `replicas` = node count → VMs `cubestack<N>-0/-1/…`) |
| **Execution** | One script call per step. No subagents — spawning one to make a single call costs more than the call. ~10–12 model round-trips per run |
| **Failure handling** | Each script emits one machine-readable verdict line with a `recover=` verb from a closed set of six; the model executes the verb rather than diagnosing from prose |
| **Cleanup** | The bootstrap pod is **ephemeral** — auto-deleted once Step 7 verifies the k8s box |
| **Run identity** | A run is scoped to what it installs (`--run cubestack<N>`): its own run dir, stamps, retry counters, **and its own bootstrap pod name**. Two installs can therefore run at the same time without applying to, reusing, or deleting each other's pod |
| **Storage** | **External Ceph CSI import** (Rook external mode) — consume an existing Ceph outside the cluster for RBD / CephFS. Required by the minimal profile, where it is the in-cluster registry's backend; the Provider exports an `external-ceph.env` and `preflight --external-ceph-env` takes it. Independent of the model store below |
| **Model store** | Optional **host-level CephFS mount** — the Provider's `/models` mounted read-only at `/models` on every node host, from the Provider's own mount guide. Opt-in, and independent of the CSI import |
| **Deliverable** | **cubestack box** by default — after the k8s box verifies, Step 7 installs `cubestack-operator` and applies a `CubeStackCluster` CR enabling five components (`lws`, `envoyGateway`, `cubestackControllerManager`, `cubepilot`, `cubestackPortal`; `aiGateway` ships `enabled: false`). `--no-operator` builds **only a k8s box**, which ends at `verify` |

---

## How it works

| Step | What happens | Script |
|------|--------------|--------|
| **Step 0** | The only user interaction — resolve prerequisites, then one confirmation | `preflight` |
| **Step 1** | Provision VMs via the sibling `suanova-dev-vm` skill, then confirm by exact name | `vm-ready` |
| **Step 1b** | *(metallb runs — the default)* Reserve the box's VIP block from the host's cubestack-ipam, **before** the deploy | `reserve-vips` |
| **Step 2** | Create the installer pod, named for this run *(runs concurrently with Step 1)* | `pod-up` |
| **Step 3** | Verify the environment from the pod — VM SSH, MinIO, Harbor, `sshpass` | `env-probe` |
| **Step 4** | Generate and byte-verify `cluster.conf` | `configure` |
| **Step 5** | Fetch the offline package set from MinIO (tens of GiB; the script's own floor decides) | `fetch-offline` |
| **Step 6** | Deploy — kubespray plus the enabled addon modules, then wait | `deploy` + `deploy-wait` |
| **Step 7** | Verify the k8s box, *(opt-in: mount the Provider's `/models` on every node)*, *(default on: turn it into a cubestack box — `cubestack-operator` + `CubeStackCluster` CR)*, then auto-delete the installer pod | `verify` + `mount-models` + `operator-up` + `operator-wait` + `pod-down` |

Steps 1 and 2 are independent (the pod only needs the target **subnet label**, not the VMs), so they run concurrently and join at Step 3. `diagnose <CODE>` produces a bounded excerpt when something fails.

Three mechanical details worth knowing: `deploy-wait` must run as a **background task** (a deploy outlasts the 600 s foreground ceiling), and completion is **process exit, never the `✅` banner** — the banner is cosmetic and is the first thing lost if a deploy is killed at the end. `operator-wait` is the same shape for the same reason, and unlike `operator-up` it stages nothing into the pod and holds no credential, so re-invoking it is free.

---

## Concurrent installs

Every script takes `--run <run-id>`, and `preflight` mints that id from the resolved target — `cubestack3` for the first free `cubestack<N>` index. One id scopes everything the run owns:

```
--run cubestack3  →  ~/.cubestack/runs/cubestack3/     run.env, stamps, attempts, verdicts, logs
                  →  pod cubestack-install-cubestack3   the bootstrap host
```

Two installs started at the same time resolve different indices, so they get different run dirs and different pod names, and neither can reach the other's state.

**There is no fixed pod name and no shared default run dir.** Both were removed deliberately. With a fixed name, the second run's `kubectl apply` targets the first run's pod, and because `kubevirt.io/subnet` is immutable that path *deletes and recreates* it — discarding the whole offline fetch and the `cluster.conf` the first run had already paid for. Discovery had the same problem from the other side: "newest pod matching the prefix" cannot tell one run's pod from another's.

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

The optional model-store step was added after these three runs, so it has no column above. Measured separately on a 2-node cluster against the Provider's CephFS: **~20 s** when the nodes already have `ceph-common`, and about **+23 s per node** on the first run, which installs it. It runs in Step 7 and is off unless asked for.

The cubestack-box step (the platform operator) **postdates all three runs**, so it has no column
either — and no
five-component bring-up has been timed. What is structural: `operator-up` returns in ~30 s (a
helm install, an apply, and a Deployment roll), and the time is the operator's own 30 s requeue
driving five components to `Ready`, which is why `operator-wait` carries its own 1800 s budget. Treat the
first run as a first-run experiment on capacity too: five components plus the operator on a
single-node 8 vCPU / 24 GiB VM alongside Rook/Ceph was the tightest shape this skill builds.
**That default has since been raised** — a 1-node box now provisions 24 vCPU / 64 GiB / 200 GiB
(see *What it asks you* below), so a new single-node run is no longer sized like the one measured
here. The timings above remain the record of what 8/24 did.

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

## Optional: the Provider's `/models` on every node

Separately from the CSI import, and independently opt-in, the nodes can be given a
**host-level kernel mount** of the Provider's CephFS `/models`. This is not a Kubernetes
volume: it is what a workload expects when it looks for `/models` *on the machine*, and the
two are orthogonal — the CSI import gives **pods** a filesystem, this gives the **node hosts**
one, and either can be present without the other.

Point `preflight` at the Provider's Linux-host mount guide:

```bash
"$S/preflight" --nodes 2 --minio-ep http://<host>:9000 \
  --cephfs-mount-guide /path/to/cephfs-linux-host-mount.md
```

Then, in Step 7 — after `verify`, before `pod-down`:

```bash
"$S/mount-models" --run <run-id> --vms <the Step 3 verdict's vms= list>
```

**The guide is the credential store, and the only one.** The script parses it for its `fsid`,
its `mon host`, and the `[client.…]` user and key — there is no second secret file to keep in
sync, and no new values-file key. The key is staged in a mode-700 temp dir, hash-verified
after `kubectl cp` into the pod, and streamed to each node over ssh **stdin**, so it never
appears in an argument list or a process list on either host. All copies are removed on every
exit path, and `pod-down` shreds the pod staging directory as a backstop. Only the guide's
**path** is recorded in the run dir.

What it does per node: installs `/etc/ceph/{ceph.conf,ceph.client.<user>.keyring,.secret}`,
mounts `<mon>:/models` at `/models` **read-only**, appends an `/etc/fstab` line with `_netdev`
(so a reboot waits for the network instead of hanging on an unreachable mon), then proves the
mount is genuinely read-only by asserting a write **fails**. It is idempotent — a re-invocation
reports `already=<n>` and re-asserts the files and the fstab line.

> `--dry-run` parses the guide and prints the resolved plan without touching a pod or a node.
> It is local and read-only, so it never spends a retry; the key is never printed.

Two failure modes are worth recognising, because both are external: `ceph-common` (which
provides `mount.ceph`) may be absent on nodes built offline, and the read-only user's caps
must actually cover the path being mounted. The first is
`E_MODELS_NO_CEPH_COMMON` → `stop-report:admin`; the second surfaces as a mount errno and is
a `stop-report` for the Provider, not something a retry fixes.

---

## Building the cubestack box (on by default)

A verified Kubernetes cluster is a **k8s box**, not yet a **cubestack box**. What turns one into
the other is the **platform** — `cubestack-operator` plus a `CubeStackCluster` CR that names which
components to run — and Step 7 installs it, on by default, from the same pod that ran everything
else.

```bash
"$S/preflight" --nodes 2 --minio-ep http://<host>:9000 \
  --harbor-ro-values ~/.cubestack/private/harbor-ro.conf
```

`--harbor-ro-values` **is** the switch: the step cannot run without the credential, so naming
the file turns it on, and `--no-operator` without one leaves a k8s box that ends at
`verify`. Neither flag is a separate "install the operator?" question — ask the user for the
credential, or don't.

Then, in Step 7 — after `verify`, alongside `mount-models`, before `pod-down`:

```bash
"$S/operator-up"   --run <run-id>        # chart + Secret + CR + operator roll; ~30 s
"$S/operator-wait" --run <run-id>        # run_in_background: true
```

On a **metallb** run (the default) there is nothing more to do here. The VIP block was reserved back
at **Step 1b**, before the deploy — a contiguous block of addresses reserved from the **host** KubeVirt
cluster's cubestack-ipam as a single `IPRangeRequest` (owned by the box's master node's VM, so
deleting that VM frees the addresses). `configure` hands that block to the installer as
`METALLB_POOL`, so the
registry's VIP is settled during the deploy and the gateway takes the block's second address by
`autoAssign`. No pool is replaced and no Service is pinned afterwards.

```bash
"$S/reserve-vips" --run <run-id>     # Step 1b: after the VMs exist, before Step 4's configure
```

`verify` asserts that the cluster's pool holds exactly the reserved block. Full rationale in
`cubestack-install.md` § *VIPs come from the host's IPAM*.

**Which components are enabled is the skill's profile, not a question.** They live in
`scripts/lib/cubestack-cluster.yaml` — a reviewable file rather than a `--set` argument list:

| Component | What it is (the CRD's own description) | Profile |
|-----------|------------|---------|
| `lws` | LWS (`kubernetes-sigs/lws`) — workload autoscaling for LeaderWorkerSets | on |
| `envoyGateway` | Envoy Gateway + Gateway API CRDs | on |
| `aiGateway` | Envoy AI Gateway controller + its CRDs — **requires `envoyGateway`** | **off** |
| `cubestackControllerManager` | The platform's workload operator + CRDs | on |
| `cubepilot` | CubePilot | on |
| `cubestackPortal` | The web portal | on |

`aiGateway` is the one component the profile disables, and the only one it could: the catalog has
six, but nothing depends on this one. `cubestackControllerManager` hard-depends on `lws` and
`envoyGateway`, and the AI gateway needs `envoyGateway`'s data plane — never the reverse. Leaving
it on would buy the platform nothing it uses, at the cost of an extra controller, its CRDs and a
chart pull on every bring-up. It is kept in the file, disabled, rather than deleted, so the
profile reads as a decision and turning it back on is a one-line change.

**`cubestackPortal` carries a `values` block, and enabling the component is not enough without
it.** The portal chart creates its login Secret only when `secrets.htpasswd.content` is non-empty
(`templates/portal/htpasswd.yaml` opens with `{{- if .Values.secrets.htpasswd.content -}}`), so a
profile that enables the portal and stops there builds a UI with **no account to log in with** —
and nothing in the run fails, because no component is unhealthy. The manifest therefore ships one
`user:bcrypt-hash` line. That hash is the operator chart's own published default for its bundled
`clusterCR` (and the example in the portal chart's README): a **shared, publicly known** credential,
which is what makes it acceptable as a default that leaves a fresh box loggable and unacceptable
for anything reachable. To replace it, override the same path — the operator deep-merges
`spec.components.<name>.values` **last**, after catalog defaults and global injection, so an
explicit override always wins. Generate a line with `htpasswd -nB <user>`.

Install **order** is not in the manifest — each component's `order` comes from the operator's
own catalog, and the operator reconciles on a 30 s requeue. A disabled component **drops out of
the CR's status** entirely, which is why `operator-wait` derives its total from the status rather
than from a count here: it polls five.

**One credential, two jobs.** The robot account pulls the operator chart from
`harbor.isuanova.com/suanova-private` *and* the component images from `suanova`. Probed
anonymously, **`suanova-private` is the one that genuinely requires it** (`UNAUTHORIZED`, where
`suanova` and `mirrors` both answer); the operator's own README still asks for pull on `suanova`
too. It is staged into the pod as a mode-600 file, verified by hash, read **inside** the pod —
so it never appears in an argument list, an environment variable, or a process list on either
host — and shredded on every exit path, with `pod-down`'s glob as the backstop. Only the file's
**path** is recorded in the run dir.

**The Secret that credential becomes has two consumers with two different rules, and only
getting one right is a silent failure:**

| Consumer | Reads it from | If it is missing |
|---|---|---|
| The operator | its **own** namespace (`cubestack-system`) | `registryauth.Resolve` errors on every reconcile — the CR never converges and names **no component** |
| The kubelet | **each pod's** namespace | `ImagePullBackOff` on that component's pods only — the CR reports that component `Degraded` |

So `operator-up` writes the Secret into `cubestack-system`, `lws-system`,
`envoy-gateway-system` and `ai-gateway-system` — the catalog's four component namespaces, read
from the catalog rather than guessed. It creates the component namespaces
**up front** rather than copying the Secret in after the operator makes them (which is what the
upstream README documents): the operator's `EnsureNamespace` is a server-side apply that merges
into an existing namespace, so pre-creating is safe, and it closes the window in which the
operator renders a Deployment the kubelet cannot yet pull into. `ai-gateway-system` is staged
even though the profile disables `aiGateway`; it then stands empty, and having it ready is what
makes re-enabling that component a one-line CR change.

**Two pull policies, because the images are rolling `:latest` and the charts default to
`IfNotPresent`** — a node that cached one would keep running that build with no signal.
`image.pullPolicy=Always` covers the operator's own image; the CR's `global.imagePullPolicy:
Always` covers the platform's own components. Third-party components keep their own chart's
policy either way.

**A pull policy only governs a pod that is *created*, so `operator-up` also rolls the operator
Deployment.** A re-invocation renders a byte-identical Deployment; Kubernetes sees no
pod-template change, creates no pod, and the policy never fires — `helm --wait` returns
immediately because the old Deployment is already ready, and the box keeps running the previous
operator binary. Since the operator's component catalog and extra assets are compiled into its
image (`//go:embed`), that stale binary is not cosmetic. The roll is unconditional (the tag is a
rolling `latest`, so there is nothing here to compare against), the verdict reports the digest as
`image=sha256:…`, and it is what makes re-running `operator-up` the way to pick up a republished
operator image.

The ordering inside `operator-up` is the part worth reading: it creates the `harbor-credentials`
Secret in `cubestack-system` **before** the chart. `registryauth.Resolve` errors outright when
the Secret the CR names is absent, so skipping that step yields a CR that never converges and
names **no component at all** — a failure with nothing to point at.

> `--dry-run` lints the credential, asserts the CR manifest and prints the resolved plan with no
> pod and no cluster. It is local and read-only, so it never spends a retry. `operator-wait` has
> no dry run: it applies nothing, and re-invoking it is free.

**The chart tag is confirmed, not derived.** The tag in use is **`1.0.0-latest`** — the
operator's own quickstart (PR #13) uses exactly that. Its publish workflow pushes a rolling
`<Chart.yaml version>-latest` on every main push and a bare `X.Y.Z` only when a release tag is
cut, and no release tag exists; the `-latest` suffix is deliberate, so a main push can never
clobber a released chart. Pass `--version X.Y.Z` once a release is cut.

`helm-push` depends on `helm-package`, which runs `make helm-sync` — so the **published chart
always carries `crds/`**, even though the repo tree's is absent. That closes the packaging
question. Two things are still **unverified on a first run**. First, whether the deployed
**nodes** can reach `harbor.isuanova.com` at all: the installer's own design is the opposite
shape — the pod pulls to an offline tar, the module pushes into the **in-cluster** registry
(`registry.cubestack.io:5000`), and the nodes pull from there, so that the cluster "永远不需要
访问公网" (its `docs/harbor-mirror.md` §2). Every run so far has a `registry` Service and the
addon modules push to it themselves; this CR is the first thing to ask a node for Harbor
directly, and `env-probe` only proves Harbor from the pod. If a node has no route it surfaces as
`E_OPERATOR_IMAGE_PULL`, which reads like a bad credential — tell them apart by curling
`https://harbor.isuanova.com/v2/` **from the VM**, where any HTTP status (even `401`) means the
network is fine. Second, capacity: whether a five-component bring-up fits inside the 1800 s
budget, and whether it fits on one VM alongside Rook/Ceph — a 1-node box used to be the 8 vCPU /
24 GiB shape this was an open question about, and is now provisioned at 24 vCPU / 64 GiB / 200 GiB
by default (the 8/24 figure is what the operator bring-up was *first* exercised against, not what
a new 1-node box gets). `operator-up` asserts
the CRD reached `Established` anyway, so a packaging surprise fails loudly rather than as
`no matches for kind "CubeStackCluster"`.

---

## Prerequisites

- **kubectl** and a kubeconfig that can reach the SUANOVA KubeVirt cluster
- The CubeStack installer image reachable from the cluster (`harbor.isuanova.com/cubestack/cubestack-installer-cli:latest`)
- Access to the internal **MinIO** endpoint holding the offline packages (tens of GiB)
- **Cubestack box only (on by default):** a **Harbor robot account with pull scope** — it pulls the operator chart from `suanova-private`, which is private and the one project that strictly needs the credential (`suanova` and `mirrors` answer anonymously). If the account has 2FA, use the **CLI Secret** from the Harbor user profile, not the login password. Put the username and token in a `Write`-authored file and pass it as `--harbor-ro-values`; `--no-operator` skips both the account and the step.
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
2. Say something like "**install a 3-node cubestack box**" — the skill triggers automatically (its description carries the trigger phrases).

---

## Usage

### Trigger phrases (natural language works)

> "install a cubestack box" / "build a 3-node k8s box" / "deploy a cubestack cluster" / "install cubestack" / "装一套 cubestack" / "spin up cubestack on the 10.66.3 subnet"

A request that names **only the k8s box** ("build a k8s box", "just the Kubernetes cluster") is
the same run with `--no-operator` — it stops at `verify` and installs no platform. Everything
else is a cubestack box.

### What it asks you (Step 0 — the only question round)

| Item | Default |
|------|---------|
| Number of nodes | `1` |
| VM shape | **24 vCPU / 64 GiB RAM / 200 GiB root disk on a 1-node box**; 8 vCPU / 24 GiB / **100 GiB root** per VM on multi-node. The default scales with the node count: a single node carries the control plane, the worker load *and* every addon on one VM. `--cp` / `--mem` / `--disk` override it |
| Subnet | Auto-selected by free capacity; all VMs share one subnet |
| VM owner label | `owner=<your OS username>` |
| SSH password | `ubuntu` |
| Service expose mode | **`metallb`** (LoadBalancer) — MetalLB is a required component. The pool is **not chosen here**: **Step 1b** reserves a contiguous block of addresses from the host's cubestack-ipam (`--count`, default 2; `1` when the registry is off) and hands that block to the installer, so no address MetalLB can reach is one a VM holds. Nothing is patched after the deploy. `--expose nodeport` opts out. **Needs cubestack-ipam ≥ 0.4.0 on the host and write RBAC on `iprangerequests`** — the chart ships only a Viewer role for that kind, and Step 1b pre-checks both |
| Node roles (multi-node) | `cubestack<N>-0` = master; `-1…` = workers |
| External Ceph CSI | **Disabled** (opt-in) — when enabled, supply the path to the Provider's exported `external-ceph.env` (the hand-filled mon + keyring route still works but is no longer the recommended one) |
| Model store on the nodes | **Disabled** (opt-in) — when enabled, supply the path to the Provider's CephFS Linux-host mount guide; Step 7 then mounts its `/models` read-only at `/models` on every node host |
| Which box | **cubestack box** — Step 7 installs `cubestack-operator` and applies a `CubeStackCluster` CR enabling five components (`aiGateway` ships disabled). `--no-operator` builds **only a k8s box**, which ends at `verify` |
| Harbor robot credential | **Required while the operator is on** — the `Write`-authored file with `HARBOR_RO_USER` / `HARBOR_RO_PW`, passed as `--harbor-ro-values`. Write it **before** the `preflight` call, so `preflight` lints it while you are still there |

Answer only what you care about — anything you skip uses the default. You get **one** confirmation, and then it runs to completion.

---

## Cluster facts at a glance

| Item | Value |
|------|-------|
| KubeVirt / CDI | v1.8.4 / v1.65.0 |
| Storage | Rook/Ceph RBD, StorageClass `ceph-rbd-kubevirt` (RWX block) |
| Golden images | `default` ns: `ubuntu-22.04/24.04/26.04-server-amd64-img` |
| Subnets | `10.66.3.0/24` only — 3 nodes, all labeled `kubevirt.io/subnet=10-66-3-0`, all migratable. The `10.66.2.0/24` subnet and both shared underlay NADs are gone |
| VM IPs | Claimed from `dev-ip-pool` via the `ipam.cubestack.io/pool` annotation; a controller mints a per-VM NAD. Never assign or reserve an address manually |

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
