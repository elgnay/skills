---
name: cubestack-install
description: Install a CubeStack box on KubeVirt VMs — a k8s box (a single- or multi-node Kubernetes cluster built by the CubeStack installer and proven by `verify`) plus the cubestack-operator that makes it a cubestack box, or just the k8s box on its own. Use when the user asks to install/deploy/bring up a cubestack box or cluster, build a k8s box, provision cubestack VMs, or run the cubestack installer. The heavy lifting is done by deterministic scripts under this skill's scripts/ directory; the model resolves prerequisites, runs one script per step, and follows the recovery verb on failure.
---

# CubeStack Installation

Build a **cubestack box** on KubeVirt VMs: a **k8s box** first, then the platform on top of it.
The installer runs inside a K8s pod (the bootstrap host) and SSHs into the target VM(s) to run
kubespray.

## The two boxes

Every run builds a **k8s box**, and — unless you say otherwise — the **cubestack box** on top of
it.

| Term | What it is |
|---|---|
| **k8s box** | Steps 1–6 + `verify` (+ `mount-models` when the run asked for it): N VMs running a verified Kubernetes cluster with the enabled addons, and the Provider's `/models` mounted on every host if a guide was given. **No CubeStack platform.** |
| **cubestack box** | That **k8s box**, plus the platform: `cubestack-operator` installed and a `CubeStackCluster` CR applied and Ready — Step 7's `operator-up` + `operator-wait`. |

> **`cubestack box = k8s box + cubestack-operator`**

`verify` is the boundary. It is what proves the k8s box, and its `verify-ok` stamp is exactly the
precondition `operator-up` gates on. `--no-operator` (Step 0) stops the run there and leaves you a
k8s box. Step 7's operator half stays re-runnable (`rerun:operator-up`) for as long as the
bootstrap pod lives — which is what `pod-down`'s own `operator-ok` gate exists to protect.

> **Ground truth is `kubectl`.** Never guess VM names, IPs, or config fields.

## This skill is script-backed — read the verdict, don't re-derive the logic

Every step is **one script invocation** at `<skill-base>/scripts/<name>`. The scripts own
the waits, the credential path, the redaction gates and the retry budgets. Your job is to
resolve prerequisites, invoke scripts, and act on exactly one line of output.

**Run scripts by absolute path.** The skill context reports
`Base directory for this skill: ...`; use `<base>/scripts/<name>` so cwd never matters.

```bash
S="<skill-base>/scripts"        # e.g. ~/.claude/skills/cubestack-install/scripts
export KUBECONFIG=<the KubeVirt cluster kubeconfig>   # host-specific, never hardcoded
```

### One run, one id — `--run <run-id>` goes on every call

A run is identified by **what it installs**, not by a fixed label. Step 0 mints
`run=<run-id>` (the resolved `cubestack<N>`) and prints it; **every later script takes
`--run <run-id>`**. That one rule is what makes two installs safe to run at the same time:
the run dir, the stamps, the retry counters *and the bootstrap pod name* are all scoped to
the id, so a second run can never apply to, reuse, or delete the first run's pod.

```bash
"$S/pod-up" --run <run-id>
```

There is no ambient "current run" and no shared default run dir — deliberately. Omitting
`--run` is a **loud failure** at the next step, never a silent fallback to another run's
state. Carry the value from Step 0's `run=` through the whole run.

### The verdict contract

Every script ends with exactly one line on stderr, and writes the same line to
`$CUBESTACK_RUN/verdict/<script>.verdict` (authoritative — survives truncation and a
killed `kubectl exec`):

```
RESULT: OK   nodes=1 vms=cubestack3@10.66.3.21
RESULT: FAIL E_SSH_AUTH vms=cubestack3 recover="sibling-vm:rebuild:cubestack3" hint="password auth rejected"
```

Fixed order: `CODE`, `k=v` pairs, `recover=`, `hint=` **last**. `OK` carries no code and
no `recover=`. Exit classes (redundant, the `<CODE>` token wins): 0 OK, 1 recoverable,
2 stop-and-report, 3 usage, 4 internal.

**Your entire failure logic is: read the verdict, execute `recover=`.** There is no
troubleshooting table any more, and no failure row to look up.

| Verb | What you do |
|---|---|
| `rerun:<script>` | Re-invoke that script unchanged. |
| `rerun-fresh:<script>` | Re-invoke that script with `--fresh`. |
| `sibling-vm:wait\|rebuild:<names>` | Hand those exact VM names to `suanova-dev-vm`. |
| `fix-values:<file>:<keys>` | Re-`Write` the values file, then re-invoke the script that failed. |
| `stop-report[:admin\|:provider\|:user]` | Stop. Keep everything. Report to the user. |
| `none` | OK only. |

Rules that keep this honest:
- **Never invent a code, and never loop.** Re-invocation budgets are enforced *by the
  scripts*: over budget a script prints `E_RETRY_BUDGET` and refuses to run. If you are
  tempted to retry a third time, the answer is `stop-report`, not a retry.
- **Never hand-author a wait, a poll, or a comparison loop.** Every wait is bounded and
  lives in a script. A wait that hits its ceiling reports `budget=<Ns>` and is *reported,
  not extended*.
- **Never write credentials with `sed`/`echo`/heredoc** — the tool layer redacts those to
  `***` and the scripts will (correctly) refuse them. Use `Write` → the script's
  `--values` path.

## Interaction model: one question round, then run unattended

The user is asked **exactly once**, in Step 0. After that confirmation the run proceeds
through Steps 1–7 **without further approval or prompting**.

- **Automated recovery instead of asking.** On failure, execute the verdict's `recover=`.
- **Stop only when recovery cannot clear it** — a `stop-report:*` verb, or a `rerun`
  budget exhausted. Then report; do not guess.
- **The bootstrap pod is ephemeral.** `pod-down` deletes it after a verified run. The
  k8s box lives on the VMs, not in the pod.
- **Report progress** as you go — reporting is not asking.

## Cluster facts (verify before acting)

| Item | Value |
|------|-------|
| KubeVirt cluster | v1.35.4, 3 nodes, KubeVirt v1.8.4 / CDI v1.65.0 |
| Golden images | `ubuntu-22.04/24.04/26.04-server-amd64-img` in `default` ns |
| Storage | Rook/Ceph RBD; SC `ceph-rbd-kubevirt` (RWX Block) |
| Harbor (installer img) | `harbor.isuanova.com` |
| Installer image | `harbor.isuanova.com/cubestack/cubestack-installer-cli:latest` |
| Harbor (platform) | `harbor.isuanova.com` — projects `suanova-private` (**private**: the operator chart), `suanova` (component images), `mirrors` (external images). Both of the latter answer anonymously, so only `suanova-private` strictly needs the credential |
| MinIO (offline pkgs) | endpoint `http://192.168.16.6:9000`, access key `admin`, secret key `Suanova@123`, bucket `cubestack-installer`, dir `offline-files` |

> **This document is aligned to the installer source at commit `1748dbe` (2026-09-28),** the
> tree at `~/workspaces/suanova/cubestack-installer`. `:latest` is a **mutable tag** and the
> image is not the repo, so the tag alone guarantees nothing about which of the statements below
> still hold. Before trusting any profile claim here, check what the pod actually carries:
>
> ```bash
> kubectl exec <pod> -- ls deployments/scripts/modules/03_addon/          # which modules exist
> kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].imageID}'   # which digest
> kubectl exec <pod> -- grep -n 'ENVOY_GATEWAY_ENABLED\|K8S_ENABLED' deployments/config/cluster.conf.example
> ```
>
> The failure mode this guards against is not a crash — it is a **green run against an installer
> that no longer has the components the profile was written for**. `load_config` is a plain
> `source` with no unknown-key validation, so config for a removed module is written, accepted
> and ignored, and every verdict stays `OK`. See "Components the installer no longer ships"
> under the values file.

> **MinIO credentials ARE in this file — deliberately** (the row above). They are the
> documented default: pass the endpoint to `preflight --minio-ep`, and put `admin` /
> `Suanova@123` in the values file. MinIO is therefore never a question to the user.
>
> ⚠ **Those two are live credentials committed to git** (`elgnay/skills` and
> `suanova/skills`). Do not add any *further* secret here. The SSH password, the Ceph
> keyrings and everything else still arrive through the run's values file (mode 600,
> `Write`-authored, never echoed) — this file is the single place a real secret lives,
> and keeping it that way is what bounds the exposure.
>
> **Subnets are dynamic.** Query the cluster; never assume a subnet. `preflight` picks
> the subnet with the most nodes able to host the shape (ties → lexicographically lowest
> label) and resolves the NAD itself.
>
> **All VMs go in the same subnet** — that keeps MetalLB and pod networking on one L2
> domain and allows live migration. If the user asks for multiple subnets, confirm they
> accept no cross-subnet migration.
>
> **VM IPs come from a cubestack-ipam pool claim, and you never assign one.** The cluster's
> shared NAD is gone; a VM is annotated with a pool and a controller mints it a one-address
> NAD (`default/<vm-name>-static`), which is why no NAD exists to select at Step 0. That is
> entirely the sibling `suanova-dev-vm` skill's business — **never hand-write an address, an
> NAD, or a claim.**
>
> **A *VIP* block is different, and is reserved here.** Step 1b reserves the box's MetalLB addresses
> from the same host pool, through the same ledger, before the deploy. Same pool, same allocator — the
> difference is that this one is an `IPRangeRequest` (`poolRef` + `count`), which binds a contiguous
> run of addresses and mints no network for anything.

## Step 0 — the ONLY user interaction: resolve prerequisites

Ask **once, in a single message**, for any of these the user cares about. Silence = default.

| # | Prerequisite | Default |
|---|---|---|
| 1 | Number of nodes | `1` |
| 2 | VM shape | **24 vCPU / 64 GiB RAM / 200 GiB root on a 1-node box**; 8 vCPU / 24 GiB / **100 GiB root** per VM on multi-node. The default scales with the node count because a single node carries the control plane, the worker load *and* every addon (Rook/Ceph, the registry, MetalLB, five platform components) on one VM. `--cp` / `--mem` / `--disk` override it |
| 3 | Subnet | auto-selected (most capacity); NAD follows |
| 4 | VM owner label | `owner=$USER` |
| 5 | SSH password | `ubuntu` |
| 6 | MinIO endpoint + keys | **built-in** — the Cluster facts row above; never ask |
| 7 | Service expose mode | **`metallb`** (LoadBalancer) — MetalLB is a **required** component and this is the default. The pool is **not chosen here**: **Step 1b** reserves a contiguous block of addresses from the host's cubestack-ipam (`--count`, default 2; use `1` when the registry is off) and hands that block to the installer, so every address MetalLB can reach is already bound to this box in the ledger. Nothing is patched after the deploy. `--expose nodeport` is an explicit opt-out, and it also releases the `verify` gate |
| 8 | VM names | single: `cubestack<N>`; multi: pool `cubestack<N>` |
| 9 | External Ceph | **required** — ask for the Provider's exported `external-ceph.env` path (`--external-ceph-env`). Not an optional storage extra: on the minimal profile it is what the registry's PVC binds to (see *Minimal profile*), so a run without it is not this profile |
| 10 | Model store on the nodes | off unless the user asks for it — then ask for the Provider's CephFS Linux-host mount guide path (`--cephfs-mount-guide`). Independent of #9: a run can import external Ceph without wanting `/models` on the hosts, and a guide alone does not import anything |
| 11 | Which box | **cubestack box** — after the k8s box verifies, Step 7 installs `cubestack-operator` and applies a `CubeStackCluster` CR enabling **five** components (`aiGateway` ships disabled). `--no-operator` builds **only a k8s box**: the run ends at `verify` |
| 12 | Harbor read-only robot credential | **required while #11 is on** — a file with `HARBOR_RO_USER` / `HARBOR_RO_PW`, passed as `--harbor-ro-values`. Author it with `Write` **before running `preflight`**, like the two Provider files above, so `preflight` can lint it while the user is still in the room |

Then resolve everything with one read-only call and confirm the printed plan:

```bash
"$S/preflight" --nodes 3 --minio-ep http://192.168.16.6:9000 \
  --external-ceph-env ~/.cubestack/private/external-ceph.env \
  --harbor-ro-values ~/.cubestack/private/harbor-ro.conf
```

Pass `--minio-ep` from the Cluster facts table **every time**. It is not optional in
practice: `preflight` records it as `MINIO_EP` in `run.env`, and Step 3's `env-probe`
reads that key. Omit it and `env-probe` fails `E_USAGE` with
`--minio-ip is required (not set on the command line or in run.env)`.

`--harbor-ro-values` is **not** optional unless `--no-operator` is also given: the file
*is* the switch that turns Step 7 on, so omitting it from a cubestack-box run is `E_USAGE`
rather than a silent k8s-box-only install. The two flags interact in one direction only —
passing the credential with `--no-operator` turns the step back **on**, because the file
is the thing the step cannot run without.

`preflight` is read-only and idempotent: it resolves the subnet, NAD, free `cubestack<N>`
index (across VMs **and** pools), and from that the **run id** (the run dir) and the
**bootstrap pod name**, then prints a `CONFIRM` block. **Re-run it the instant the user
changes an answer** — that is what replaces "re-resolve only what changed".

Because the run id *is* the resolved target, re-resolving an answer that does not change
the target (node count, shape, expose mode) keeps the same run dir and the same pod name;
changing which cluster you install gives a different id, which is exactly right.

Capture `run=<id>` from the verdict — every later command needs it.

Show the user the `CONFIRM` block and get one "ok". That is the green light for the whole
unattended run. Then write the values file.

## The values file

Author it with `Write` (never `sed`/`echo`/heredoc), then hand it to the scripts. Every
line is `KEY='value'` with single quotes and no embedded quote — the scripts `source` it
inside the pod, so anything else is an injection vector and is refused. Keys outside the
allow-list are refused too.

```
SSH_PW='<password>'
MINIO_EP='http://192.168.16.6:9000'
MINIO_AK='admin'
MINIO_SK='Suanova@123'
NODES_MASTER='master,<hostname>,<ip>,ubuntu,-'
NODES_WORKERS='worker,<hostname>,<ip>,ubuntu,-|worker,<hostname>,<ip>,ubuntu,-'
```

`NODES_WORKERS` is **one** line whose entries are joined by `|` (not one line per worker).
Multi-node: the `NODES_MASTER` line plus that single `NODES_WORKERS` line. Single-node:
omit `NODES_WORKERS` entirely — `NODES_MASTER` alone is the single master.

#### The Harbor robot credential (a second file)

Step 7 pulls the operator chart from Harbor and the operator pulls every component image
from it, so the run needs a **Harbor robot account with pull scope**. It lives in its own
file — `~/.cubestack/private/harbor-ro.conf`, mode 600, `Write`-authored — passed as
`--harbor-ro-values` and recorded in `run.env` as a **path only**:

```
HARBOR_RO_USER='robot$cubestack+installer'
HARBOR_RO_PW='<the robot token>'
```

Same format as the values file (`KEY='value'`, single quotes, no embedded quote), and the
same two-key lint at Step 0 — a key outside that pair is refused before anything runs.

**Why a separate file rather than two more keys in the values file.** The values file is
`sourced` with `set -a` inside the pod by `configure` and `fetch-offline`, which is what
turns its keys into the environment the installer's own scripts read. That is the right
treatment for the installer's keys and the wrong treatment for a credential the installer
has never heard of: it would become an env var of every process those scripts spawn, for a
step that runs twenty minutes later. Keeping it separate bounds the exposure to the one
script that needs it — and makes `fix-values:<file>:HARBOR_RO_USER,HARBOR_RO_PW` name the
file you must actually re-`Write`.

**Scope.** One robot account, used for both jobs against the same host: pulling the
operator chart from `suanova-private`, and pulling component images from `suanova`.
**`suanova-private` is the one that actually requires it** — probed anonymously, it returns
`UNAUTHORIZED` while `suanova` and `mirrors` both answer (the operator's own README still asks
for pull on `suanova` too, which is cheap insurance if that project is ever flipped private).
Granting **pull** on a project it did not need costs nothing; missing one it did need fails per
component, and the operator reports that as `Degraded` on the component and nowhere else.

If the account has **2FA enabled**, the password is the **CLI Secret** from the Harbor user
profile, not the account's login password — a login password authenticates to the web UI and
fails against the registry.

#### Components the installer no longer ships

`dc4f3d7` (2026-09-23) removed **Envoy Gateway, Envoy AI Gateway, Prometheus/Grafana, Perses and
the BMC exporter**, and deleted their modules, charts, offline groups and config keys outright.
There is no envoy or gateway-controller reference left anywhere in the installer.

Two consequences, and the asymmetry between them is what makes this worth reading:

- **Naming a removed module is loud.** `--steps envoy_gateway` now fails with `未知模块`. If you
  find yourself reaching for one of those names, the answer is that the component is gone.
- **Writing a removed key is silent.** `load_config` is a plain `source` (`lib-common.sh:424`)
  with no unknown-key validation anywhere, so a dead key becomes an unused shell variable — no
  error, no warning, and every verdict stays green. A cluster configured for a component that no
  longer exists looks exactly like a healthy one.

`GATEWAY_API_ENABLED` survives (`cluster.conf.example:114`), but read it carefully: it is a
kubespray addon flag that installs the **Gateway API CRDs**. It is not a gateway controller, and
nothing implements a data plane behind it.

**RDMA.** On by default.

```
RDMA_ENABLED='false'              # RDMA shared device plugin
```

**Set it to `false` on VMs with no RDMA NIC**, which is the common case for a KubeVirt-built
cluster — but note that the reason is no longer "the module would die". As of 2026-09-28 the
example ships `RDMA_HCA_MODE='by-link'` with `RDMA_PLACEHOLDER_HCAS='mlx5_0,mlx5_1,mlx5_2'`, so
an HCA-less VM comes up cleanly with a placeholder ConfigMap and **no registered resource**: the
module succeeds, the cluster advertises an RDMA capability, and nothing can use it. That silent
success is the reason to turn it off honestly rather than let it pass.

`RDMA_ENABLED='false'` is the module's own gate, so the module and its paired `verify` step skip
together. Turning it off because the hardware is absent is *not* the same as skipping it:
`--skip rdma_shared_dev_plugin` leaves `RDMA_ENABLED=true` in the config, so the cluster goes on
claiming the capability and a later `--steps verify_rdma_shared_dev_plugin` fails on it.

**GPU operator and Multus.** On by default, and independent of each other:

```
GPU_OPERATOR_ENABLED='false'      # MetaX GPU operator (node feature discovery + device plugin)
MULTUS_ENABLED='false'            # Multus CNI (secondary networks)
```

Nothing in the addon set requires either. `06_gpu_operator`, `07_gpu_lws` and `09_multus` all
declare only `k8s_deploy k8s_registry`, and `07_gpu_lws` deliberately does **not** depend on
`06_gpu_operator` — so turning these off removes modules rather than orphaning them. The GPU
operator is also the module most likely to stall on a VM; turn it off when there is no MetaX card
for it to find.

**The registry and its storage backend.** Both on by default:

```
LOCAL_PATH_ENABLED='false'        # local-path-provisioner, the default StorageClass
REGISTRY_ENABLED='false'          # the in-cluster registry + node trust/DNAT
```

They are coupled, and the coupling is the installer's, not a convention:

- **Ceph wins over local-path.** With `CEPH_ENABLED` or `CEPH_CSI_ENABLED` true — which is every
  `CEPH_MODE='external'` run — `load_config` forces `REGISTRY_STORAGE_CLASS=ceph-block` and
  `LOCAL_PATH_ENABLED=false`, and says outright that an explicit `LOCAL_PATH_ENABLED` is
  overridden by that rule (`lib-common.sh:551`). So on an external-Ceph run the key is inert and
  `local_path` is not installed; it only bites on a run with no Ceph.
- **The registry needs a backend.** Its PVC binds to `local-path` unless Ceph is on. Turn
  local-path off with no Ceph and *nothing in the installer complains*: `04_local_path.sh` exits 0
  on its own toggle and the registry module never inspects it, so the run goes green and fails
  later as a PVC that never binds. `configure` now refuses that combination before writing
  anything (`exit 14` → `E_CONF_VALUES_MISSING`, `recover=fix-values:<file>:REGISTRY_ENABLED,LOCAL_PATH_ENABLED`).
- **Turning the registry off removes a BASE module.** No addon, no `certificates.d` trust, no
  DNAT; nodes take their images from the offline preload instead. `verify` reads what the run
  asked for and only demands the registry Service when it was requested — a run dir predating the
  key has no record and keeps the old, stricter behaviour.

These toggles are written into `cluster.conf` as **literals** by the rewriter. The example
ships them as `KEY="${KEY:-true}"`, deferring to the ambient environment — but `cluster.conf`
is sourced by `deploy-cluster.sh` in a *different process* from the one that sourced your
values file, so that indirection can resolve back to the default and silently ignore the
toggle. The literal removes the ambiguity; these are the only values keys that do not pass
through as-is.

#### Minimal profile

A VM-hosted cluster with no GPU and no RDMA NIC needs none of those addons. This is the
**minimal profile** — seven keys in the values file, and nothing else changes:

```
K8S_ENABLED='true'                 # see below: the default installs no Kubernetes at all
RDMA_ENABLED='false'
GPU_OPERATOR_ENABLED='false'
MULTUS_ENABLED='false'

SERVICE_EXPOSE_MODE='metallb'      # LoadBalancer — already the default; stated, not changed
REGISTRY_ENABLED='true'            # the in-cluster registry — already the default; stated
CEPH_MODE='external'               # required, with --external-ceph-env at Step 0
```

The first four shed addons this box has no hardware for. The last three describe the box itself:
**a LoadBalancer, an in-cluster registry, and Ceph underneath both.** The expose mode and the
registry are already the installer's defaults, so writing them changes nothing about a run that
follows this document — they are in the list so the profile reads off the page instead of having
to be inferred from three different sections. What they *do* change is the failure mode of
omitting them: an explicit key in the values file beats the resolved default, so a file that says
`SERVICE_EXPOSE_MODE='nodeport'` wins, and the box then comes up with no `metallb-system`, no
registry VIP and no LoadBalancer at all — silently, because `deploy-wait` reads an ansible recap
and has no opinion on which mode you meant.

The three are coupled, and the coupling is the installer's:

- **`--count 2` at Step 1b.** With MetalLB on *and* the registry on there are two consumers of the
  reserved block — the registry takes its low address, the gateway's data plane the high one. That
  is Step 1b's default, so the profile needs no flag; a box with the registry off reserves
  `--count 1` instead, which is why the flag exists.
- **External Ceph is where the registry lives.** Its PVC binds to `local-path` unless Ceph is on
  (*The registry and its storage backend* above), and requiring Ceph is what turns local-path off.
  So on this profile the import is not a storage extra bolted on beside the registry — it is the
  registry's backend, and the two arrive together or not at all.
- **`REGISTRY_IP` stays unset.** The registry's address is derived from the pool's first address,
  so there is exactly one source of truth for where it is. See *VIPs come from the host's IPAM*.

This is the first version of the profile that is **entirely expressible from the values file**.
`K8S_ENABLED` is now plumbed through, so the pod-side `cluster.conf` patch procedure that earlier
versions of this document required is gone. Nothing needs editing inside the pod.

Two keys that used to need mentioning no longer do: `LWS_ENABLED` and `KUBE_VIP_ENABLED` both
default to `false` as of 2026-09-28, so a stock deploy has neither `lws-system` nor a kube-vip
manifests step. Do not add them to the values file to "match" an older run.

**What is verified, and what is not.** Every part of this profile has been measured, but not in
this combination: no run on the current build has yet come up with MetalLB and the registry on
together.

| evidence | covers | build |
|---|---|---|
| `cubestack1` (2026-09-29) | the addon keys (`RDMA` / `GPU_OPERATOR` / `MULTUS` off), `K8S_ENABLED`, the external-Ceph import, and a full deploy through `verify` | **current** |
| `cubestack5` (2026-09-18), `cubestack9` (2026-09-24) | the metallb module and the registry behind it | superseded |
| Step 1b, against the live host (2026-09-29) | the `IPRangeRequest` reservation | **current** |

`cubestack1` is the current-build run, and it is the profile's **opt-out** rather than the profile:
`SERVICE_EXPOSE_MODE='nodeport'` and `REGISTRY_ENABLED='false'`, built with `--no-operator` so it
ends at `verify`. It measured, on 1 node:

- `deploy-wait` `OK recap=ok=804,changed=195,failed=0`, no module aborted. Modules run:
  `k8s_deploy`, `kube_vip`, `metallb`, `ceph`, `ceph_csi` — `ceph_csi` last.
- `verify` `OK nodes=1 namespaces=5 ceph_state=Connected sc=ceph-block,cephfs-durable pvc=0/0`
- The five namespaces: `default`, `kube-node-lease`, `kube-public`, `kube-system`, `rook-ceph`.
  `metallb-system` and the registry are absent *because the run turned them off*; `cubestack-system`
  is absent because `--no-operator` skips Step 7. Neither is a fault.

So it is evidence for the addon keys, `K8S_ENABLED` and the Ceph import on this build — and
**not** evidence for the profile's metallb/registry half. That half comes from `cubestack5` and
`cubestack9`, which predate `dc4f3d7` and `1748dbe`: they prove the *modules* work, not that the
current build comes up with them.

**`verify` is a real gate on that half, though**, and it is the reason to run it rather than trust
`deploy-wait`. Its checks default to *requiring* both (a run dir with no `METALLB_REQUESTED` /
`REGISTRY_REQUESTED` is held to the stricter behaviour), and then: `metallb-system` must be in the
namespace list; an `IPAddressPool` must exist in it; that pool's addresses must **equal the block
Step 1b reserved** — a placeholder pool or a widened one fails `E_VERIFY_SERVICE`, because either
could announce an address the host's ledger has already given to a VM; every LoadBalancer Service
that has an address must sit inside that block; and the registry Service must exist. One Service
still `<pending>` is reported rather than failed: on a k8s box the gateway does not exist yet, and
a Service with no address has collided with nothing.

Two things it does **not** check, so look at them yourself on a first run: that an
`L2Advertisement` exists in `metallb-system` (a pool with no advertisement reserves addresses and
announces none of them), and that the registry took the block's **low** address rather than merely
some address inside it.

⚠ **`K8S_ENABLED` is the one key a full deploy cannot do without** — and it now comes from the
values file, so the warning is simply: *do not omit it*. It ships as `${K8S_ENABLED:-false}` and
gates `02_k8s/06_k8s_deploy.sh`. Left alone, a full deploy installs **no Kubernetes at all**.

⚠ **`pod-up --recreate` wipes everything on the pod's filesystem** — `cluster.conf` and the whole
`deployments/offline-files/` tree. Re-run `configure` *and* Step 5 (the offline fetch) after a
recreate; an image-not-found error after a recreate usually means the fetch was skipped, not that
the image is absent.

#### MetalLB / the expose mode — the default, and required

**MetalLB is not a component toggle.** It is gated by the *global* expose mode, and getting this
wrong is invisible: in `nodePort` mode the installer **force-disables MetalLB** (自动关闭). A
cluster can therefore carry `METALLB_ENABLED=true`, ship the
`quay.io_metallb_{controller,speaker}_v0.13.9.tar` images in `PRELOAD_IMAGE_PATTERNS`, and still
come up with no `metallb-system` namespace at all — with no error anywhere. That is how
`cubestack1` (2026-09-29) came up. It is why this mode is now the default and no longer optional.

**The default is a LoadBalancer, and its pool is reserved before the deploy.** `preflight` resolves
the mode, `metallb`. It does **not** resolve a pool: the addresses are claimed at **Step 1b**
(`reserve-vips`) from the host's cubestack-ipam, and `configure` feeds them to the rewriter so the
resolved mode and the reserved block both reach `cluster.conf`:

```
SERVICE_EXPOSE_MODE='metallb'              # the default; 'loadbalancer' normalises to this
METALLB_POOL='10.66.3.206-10.66.3.207'     # from run.env's POOL_RANGE (Step 1b); REQUIRED in this mode
METALLB_ENABLED='true'                     # already the default
```

`REGISTRY_IP` is deliberately **not** set, and that is a decision rather than an omission: with it
empty the installer derives the registry's address from the pool's own first address — see
**VIPs come from the host's IPAM** below — so there is exactly one source of truth for where the
registry lives.

Only an explicit key in the values file overrides the resolved mode: the injection fills a gap the
file left, it never fights the user. A values file that sets `SERVICE_EXPOSE_MODE='nodeport'` wins,
and the run then behaves as an opt-out (below).

> **The plumbing is newer than the flags.** Until 2026-09-29 `preflight --expose` was recorded in
> `run.env` and read by nothing at all — the rewriter reads `SERVICE_EXPOSE_MODE` from the *values
> file*, so `--expose metallb` deployed nodeport anyway, silently. A run dir older than this change
> carries an `EXPOSE` that proved nothing.

`--expose nodeport` is the explicit opt-out. It drops MetalLB from the build and **releases the
`verify` gate**: `verify` fails a run that asked for metallb and has no `metallb-system`, but does
not demand MetalLB of a run that opted out. Only the run's own recorded mode distinguishes the
two, which is why `configure` writes `METALLB_REQUESTED` into `run.env` — a deliberate nodeport
run and a metallb install that did nothing look identical from the cluster.

- **The in-cluster registry moves to a LoadBalancer VIP**, and it takes **the reserved block's low
  address** — not by being pinned, but because that is the address the installer derives from
  `METALLB_POOL` when `REGISTRY_IP` is empty. It never moves afterwards.
- ingress-nginx and the Ceph expose mode would follow the same mode if they were enabled (both
  are off in the minimal profile).

**Why the pool is reserved instead of chosen.** MetalLB and the host's cubestack-ipam allocate from
the same subnet, and on a `static` IPAM pool **nothing refuses a duplicate**: two hosts answer for
one address, connectivity goes intermittent, and the only detector is the `DuplicateAddress` audit
event. A hand-picked band is therefore a bet that the IPAM never hands those addresses to a VM — and
on this cluster that bet loses by default. The live pool is `dev-ip-pool` =
`10.66.3.200-10.66.3.230`; this skill used to recommend `10.66.3.221-10.66.3.240` for MetalLB.
**Ten addresses — `.221` through `.230` — are in both.** That is the entire failure mode, and no
amount of care in picking a range removes it: which addresses the IPAM hands out is not this run's
decision to make.

Step 1b removes the bet: it **reserves** the addresses from the host's ledger first, so every address
in the MetalLB pool is already bound to this box. MetalLB can still choose freely inside the pool —
and that is now fine, because there is nothing left in it that belongs to anyone else.

**What the installer does with the block.** `sync-kubespray-config.sh` writes `METALLB_POOL`
verbatim as one `- <value>` line under `metallb_config.address_pools.primary.ip_range`, and there is
**no key for `autoAssign`**, so `primary` is rendered with it unset (i.e. **true**). That is
harmless here and only here, for the reason above. The installer rewrites **every** `ip_range:` block
with that value, so a second pool is not reachable through the installer — which is the point:
there is exactly one pool and it is exactly the reserved block.

**Rules the block obeys.** It must be on the same L2 as the nodes. `reserve-vips` checks that after
reserving, comparing the block against the run's subnet label (`10-66-3-0`), and **deletes the
request and fails** if they disagree (`E_VIP_OFF_SUBNET`) — off-L2 means MetalLB never announces, the
registry VIP is unreachable, and every node pull fails with nothing naming the cause. The check runs
only when the label has the 4-octet /24 shape these clusters use: a wider netmask cannot be judged
from the label (which carries no prefix length), and guessing there would reject legitimate runs.
`--expose nodeport` sidesteps the pool entirely.

`configure` **refuses a metallb run with no pool** (`E_VIP_POOL_MISSING`, `recover="rerun:reserve-vips"`),
because the installer would otherwise silently keep the example's placeholder
`10.66.1.131-10.66.1.132` — off-L2 for these clusters, so MetalLB never announces and the registry
VIP is unreachable. The only real cause of an empty pool is that Step 1b has not run for this run
id; a `preflight` re-run also resets it.

#### VIPs come from the host's IPAM, not from MetalLB

**The reservation happens once, before the deploy, and nothing moves afterwards.**

`reserve-vips` (Step 1b) reserves a **contiguous block** of addresses from the host's cubestack-ipam
and records the range as `POOL_RANGE`. `configure` feeds that to the installer as `METALLB_POOL`.
That is the whole flow — one step, before the box exists, and nothing touches MetalLB or any
Service after the deploy finishes. The block is **as many addresses as the box has LoadBalancer
consumers** (`--count`, default 2): two for a box with the registry on, one for a box with
`REGISTRY_ENABLED='false'`, where the gateway is the only consumer.

1. **One `IPRangeRequest`, not a claim per address.** `poolRef` + `count`, which is the whole spec.
   It carries an `ownerReferences` entry pointing at the box's **master node's `VirtualMachine`**
   (`run.env`'s `VM_NAMES` entry ending in `-0`, or the single node's name), so deleting that VM
   garbage-collects the request and returns the addresses — the same lifecycle a real VM claim has. A
   namespaced owner requires its dependent in the same namespace, which is why the request lands in the
   VM's namespace.
2. **A run of addresses, chosen by the controller.** There is no way to ask for a specific or aligned
   range: the controller takes the **lowest free contiguous run** of that length, and once recorded it
   never re-derives or moves it. So a re-invocation reads the block back rather than searching again,
   and the addresses are unknowable until the create. `spec.count` is **immutable** — the API server
   refuses a change — so `--count` is first-invocation-only: the recorded/live count always wins, a
   re-run with no `--count` reuses it silently, and an explicit `--count` that disagrees fails with
   `E_VIP_COUNT_IMMUTABLE`. Before the deploy, changing the size means `--release` and a re-draw,
   which may land on a different block.
3. **`REGISTRY_IP` stays empty on purpose.** The installer then derives the registry's address from
   the pool's first address (`first_pool_addr` splits the range on `-` and takes the low end), and
   writes it both to the registry Service's `spec.loadBalancerIP` and to each node's `/etc/hosts`.
   One source of truth, so nothing ever has to move it — and leaving it empty also leaves
   `REGISTRY_IP_EXPLICIT=0`, which keeps `deploy-registry.sh`'s collision probe armed: it curls the
   address before the deploy commits and **aborts** if anything answers. On a reserved address that
   probe should be silent, and if it is not, the run stops early with a real signal instead of
   twenty minutes later with a mysterious one.

The host kubeconfig arrives as a **path** (`--ipam-kubeconfig`, default `$KUBECONFIG`, which is
already the KubeVirt cluster), so no host-specific config lands in the skill. `reserve-vips` touches
only the host cluster: it needs no pod and no deployed-cluster kubeconfig, which is why it can run
at Step 1b, before the bootstrap pod even exists.

> **This does not collide with `suanova-dev-vm`'s "never hand-write a claim".** That rule guards a
> *VM* claim against a controller that is create-only and keys off VM annotations; an
> `IPRangeRequest` names a pool, a count and an owner, has no VM annotation to desync from, and
> mints no NAD. It is the one kind this skill creates by name — and `--release` deletes exactly the
> one object it created.

> **`--release` is the escape hatch, and it is destructive.** The ownerRef is the normal lifecycle:
> delete the master VM and the request goes with it. `--release` exists for the one window that does
> not cover — **deleting the master VM while the box still runs**, which frees the addresses back to
> the pool while MetalLB still announces them, so another VM could be handed one. Tear the box down
> first, or release first.

> **Prerequisite: cubestack-ipam chart 0.4.0 or later, and write RBAC.** The kind did not exist
> before 0.4.0, and the chart ships only a **Viewer** role for it, so the kubeconfig Step 1b runs
> with needs `create` on `iprangerequests`. Both are pre-checked before any attempt is spent and
> reported by name — `E_VIP_NO_CRD` and `E_VIP_RANGE_DENIED`, both `stop-report:admin` — because
> neither is something a re-invocation fixes.

> **Status: the module is verified, and the reservation step is verified against the live host —
> but no install has yet run with it.** Both existing metallb runs used the superseded build —
> `cubestack5` (2026-09-18, the first metallb run) and `cubestack9` (2026-09-24, pool
> `10.66.3.225-.230`) — and both came up with `metallb-system` really installed, an
> `IPAddressPool primary` and a matching `L2Advertisement primary`, and a working in-cluster
> registry: on `cubestack9` the registry took `10.66.3.225` — **the pool's first address, with
> `REGISTRY_IP` left empty, exactly as described above** — and answered HTTP 200 on `/v2/`.
> `01_metallb.sh` is untouched by `dc4f3d7` and `1748dbe`, so that module behaviour still holds;
> those runs are evidence for the module, not for the current build as a whole.
>
> **What Step 1b itself has been shown to do** (2026-09-29, against the live host cluster, using
> scratch run ids that were released afterwards — `cubestack2` and its `IPRequest` were read-only
> throughout). A first invocation created one `IPRangeRequest`, `Bound` at the lowest free run
> (`.208–.209`), with the box's VM as its owner; a second invocation returned `reused=1` **and left
> `resourceVersion` unchanged**, which is the proof that it read rather than re-applied; a second
> scratch run got a disjoint higher block (`.210–.211`) while `kubectl get iprequests` stayed
> unchanged; `--count` disagreeing with the live request failed `E_VIP_COUNT_IMMUTABLE`; `--release`
> freed the block immediately — no finalizer — and the *next* run was handed it straight back; and a
> block deleted out from under a run that had already deployed failed `E_VIP_CLAIMS_LOST` instead of
> re-reserving. A run reserved by the earlier build was reused read-only (`legacy=1`) and did **not**
> create a request.
>
> **Still unexercised: the install.** No run has yet gone out with metallb as the default, and no
> `configure`→`deploy` has consumed a reserved block. `cubestack1` (2026-09-29) is the run that
> established the failure mode this section opens with, and it was a *nodeport* run — the old
> default. The first default-mode run is therefore a first-run experiment: check `metallb-system`,
> the pool CR (its `addresses` must be exactly the reserved block) and the registry endpoint
> directly. `verify` asserts the first two for you, but that gate has never been exercised against a
> cluster that actually has them.
>
> **Arithmetic worth watching on that first run:** `deploy-registry.sh`'s collision probe fires for
> the first time on a reserved address. Silence is the pass. A third LoadBalancer Service against a
> two-address pool sits `<pending>` — visible, never silent — which is the honest outcome.
>
> **The controller leaves it alone, and no longer needs watching.** cubestack-ipam is create-only for
> this kind — its RBAC is get/list/watch plus a status update — so it can neither adopt nor delete a
> request it did not create, and it has **no finalizers**, which makes deleting the object the release
> itself, immediate. It shares one ledger with `IPRequest`, so a reserved block can never overlap a
> VM's address or another block. The one asymmetry to remember when reading the host cluster:
> `kubectl get iprequests` does **not** show these — they are a separate kind.

### A failed addon module is a partial install that `deploy-wait` still calls OK

Modules run in **numeric order** and a module failure **aborts the rest of the addon phase**
(`部署中断: 模块 <name> 失败`). `deploy-wait` reads ansible's recap — which counts *task*
failures and reports `failed=0` — so it returns `RESULT: OK` even though the phase died
partway. Likewise `verify` checks the cluster's shape (nodes, namespaces, Ceph) and a short list of
things the run's **own record** says it asked for — the registry Service, and MetalLB's namespace
and `IPAddressPool` — rather than which addons were enabled in general: it has no opinion on your
addon toggles. Two consequences to hold onto:

- **`deploy-wait: OK` does not mean every addon is installed.** It means the steps that ran
  succeeded. Check the thing you asked for, not only the verdict — for a Ceph import, that the
  StorageClasses exist; for the registry, that its Service is in the cluster. MetalLB is the one
  addon `verify` now covers for you, because it is required and because its failure is otherwise
  completely silent.
- **A module that aborts early silently removes everything after it.** Modules run in numeric
  order, so a failure at `10_rdma_shared_dev_plugin.sh`, say, means every later module never
  executes at all — and there is no error anywhere naming the modules that did not run. The run
  dir's `logs/deploy-wait.log` survives the pod (the pod's own
  `/tmp/cubestack-cluster-install.log` does not), so that is where to look for
  `模块 [<name>] 执行失败`; `grep -i <addon> logs/deploy-wait.log` returning nothing while its
  module is in the plan is the signature of a module that never ran.

**External Ceph** — the Provider's external-Ceph import guide documents an `external-ceph.env`
in full; its §3 says to save that content verbatim under that name ("保持原样、一行不改"). Take
the file so saved and point `preflight` at it — that is the whole of the setup:

```bash
"$S/preflight" --nodes 1 --minio-ep http://<host>:9000 \
  --external-ceph-env /path/to/external-ceph.env
```

`preflight` validates the file locally, records its path in the run dir, and switches on the
consumer-side checks in `verify` (`ceph_env=official` in the verdict). `configure`
then places it at `deployments/config/external-ceph.env` in the pod — where the installer
auto-detects and **sources** it — and hash-verifies the copy landed intact. The values file
needs exactly **one** extra line:

```
CEPH_MODE='external'
```

Everything else the import needs is already inside the env file: the monitors, the keyring,
the CSI secrets, the pool and file-system names, the RGW endpoint. So when you pass
`--external-ceph-env`, **`CEPH_MONITORS`, `CEPH_KEYRING` and the `CEPHFS_*` keys are not
needed** — the rewriter does not ask for them on that path.

Three things worth knowing before you run it:

- **The key is `CEPH_MODE`, not `CEPH_NODE`.** There is no `CEPH_NODE` key in the installer at
  all; `CEPH_NODES` and `CEPH_NODE_LABEL` are unrelated (they place *internal*-mode OSDs).
  Setting `CEPH_NODE` does nothing, silently, and the run installs no Ceph.
- **The env file is placed, not shredded.** Every other credential path shreds its pod-side
  copy on exit; this one cannot, because the installer sources the file ~12 minutes later,
  mid-deploy. `pod-down` removes it, and `deploy` re-checks it is still there before
  launching (the pod's filesystem is ephemeral — a recreate between the two steps loses it).
- **The file is `source`d inside the pod**, so `configure` refuses one containing command
  substitution, a non-assignment line, unbalanced quotes or `***` artifacts, and will not
  deploy against a copy whose hash does not match the local file.

**Hand-filled fallback.** Without `--external-ceph-env` the installer still supports
configuring the Provider by hand. Then, and only then, `CEPH_MONITORS` + `CEPH_KEYRING` are
required — the rewriter refuses the run without both:

```
CEPH_MONITORS='<ip:port,ip:port,ip:port>'            # hand-filled path only
CEPH_KEYRING='<base64 keyring>'                      # hand-filled path only
CEPH_POOL='rbd'          CEPH_USER='admin'           # optional defaults
CEPHFS_FS='<fs name>'                                # optional; makes DATA_POOL required
CEPHFS_DATA_POOL='<pool>'                            # BOTH-OR-NEITHER with CEPHFS_FS
```

`CEPHFS_FS` is itself the CephFS switch on that path; setting it without `CEPHFS_DATA_POOL`
hard-fails *mid-deploy*, so `configure` rejects that combination up front instead of
12 minutes in. On the official path CephFS is decided by the env file's `CEPHFS_FS_NAME`,
which `configure` reads to decide whether `verify` should expect a CephFS StorageClass. RGW is
internal-mode only — an external Provider's RGW is used directly and is never configured here.

⚠ **A green `deploy-wait` on an external-Ceph run no longer proves the Provider works.**
`CEPH_EXTERNAL_PROVISION_SMOKE` defaulted to `true` until 2026-09-28 and is now `false`, which
turns off the module's end-to-end provisioning test (a 1 Gi PVC written and read back through a
busybox pod). With it off, the deploy imports the Provider's config, writes the CSI secrets and
creates the StorageClasses — and never asks the Provider to provision anything. A broken mon
path, a stale keyring or a wrong pool name then surfaces **later**, as images failing to push
through `k8s_registry`'s 600 s gate, hours after the step that should have caught it.

```
CEPH_EXTERNAL_PROVISION_SMOKE='true'   # restore the end-to-end provisioning test
```

Set it on any run where the Provider is new or has changed. It is opt-in rather than default
because it costs a couple of minutes, not because it is unsafe — the module hard-fails on a
smoke-test failure, with the provisioning pod's events in the log, which is exactly the loud
failure you want. Empty (absent from the values file) leaves the installer's default alone.

⚠ **The object layer is outside every check either step makes.** The external RGW is *consumed*,
not configured: the installer creates the bucket StorageClass and the Model-repository OBC, and
nothing verifies them. `verify` looks at the `CephConnection` / `ClientProfile`, the CephCluster
reaching `Connected`, the RBD / CephFS StorageClasses and the CSI secrets' `userID` — all
block-layer. On `cubestack1` (2026-09-29) every one of those passed (`ceph_state=Connected`,
`HEALTH_OK`, `pvc=0/0`) while the `model-repo` OBC sat `Pending` for the rest of the run. Read
the OBC yourself; a green `verify` is silent about it.

When it does not bind, **do not take the installer's hint at face value.** It prints
`多为 rgw-admin-ops-user caps 不足` (usually insufficient RGW admin-ops caps), but the operator
log is the ground truth, and on `cubestack1` it was:

```
unable to create Ceph object user "...": Get "http://<rgw-endpoint>/admin/user?...":
dial tcp <rgw-endpoint>: connect: connection refused
```

`connection refused` is a **reachability** failure, not a capability one — nothing was listening
on the Provider's RGW endpoint, so no caps question arose. The two diagnoses take opposite
actions, and this one is the Provider's to fix: the skill never configures an external RGW.
Read the log line before acting on the hint.

```bash
kubectl -n rook-ceph logs deploy/rook-ceph-operator | grep -i "object user" | tail
kubectl -n rook-ceph get obc model-repo -o jsonpath='{.status.phase}{"\n"}'
```

**Model store on the node hosts.** Separate from all of the above, and **opt-in only**, there
is a step that mounts the Provider's CephFS `/models` at `/models` on every node *host*:

```bash
"$S/preflight" --nodes 2 --minio-ep http://<host>:9000 \
  --cephfs-mount-guide /path/to/cephfs-linux-host-mount.md
```

This is a **host-level kernel mount**, not a Kubernetes volume — it is what a workload that
expects `/models` to already exist on the machine is looking for. It is orthogonal to the
StorageClasses the Ceph import creates: those give *pods* a filesystem, this gives the *node*
one, and either can be present without the other.

**No new values-file key** — this needs nothing in the values file, and the guide path is
recorded in the run dir (`CEPHFS_GUIDE_FILE`), never in this repo.

The credential never leaves the Provider's guide: at mount time the script parses the guide
for its `fsid`, `mon host`, and the `[client.…]` user and key, stages them in a mode-700 temp
dir, verifies the copy inside the pod by hash, and streams it to each node over ssh **stdin** —
never as an argument, so it cannot appear in a process list. Both the host and pod copies are
removed on every exit path, and `pod-down` shreds the pod staging directory as a backstop.
Only the guide's **path** is recorded; its contents are never copied here or into `run.env`.

#### Adding or restoring one component on a live cluster

Steps 1–7 build a box, so they are the wrong tool for adding a single addon to one that
already exists — a full `deploy` re-runs the base *and* every module whose toggle defaults on for
that image. The installer's own targeted path does one component plus its non-base dependencies:

```bash
kubectl exec <pod> -- sh -c 'cd deployments/scripts && ./deploy-cluster.sh --steps netshoot'
```

- **Dependencies come along, but only the non-base ones.** `--steps ceph_csi` pulls in `ceph`
  (its `REQUIRES`) and drops `k8s_deploy` — the pull-in runs *before* the exclusion, so a real
  dependency is never lost, and the base is never accidentally reinstalled.
- **The excluded set is base plus every `env`/`k8s`-phase module.** That is
  `BASE_MODULES=(k8s_deploy k8s_scale metallb local_path k8s_registry)` *plus* everything under
  `modules/01_env/` and `modules/02_k8s/` — so `vm_sshkey`, `k8s_passwordless`, `kube_vip` and
  the rest do not run either, unless you name them explicitly (an explicit name always wins).
  That exclusion is what makes it safe on a live cluster.
- **The deploy now provisions its own cluster access first.** `ensure_cluster_access`
  (`lib-module.sh:538`) runs for **any** `--steps`, before the modules: if the pod already has a
  working kubeconfig it uses it and touches nothing; otherwise it generates an SSH keypair,
  injects the public key into every node with the `cluster.conf` password, and fetches
  `admin.conf` from the first master. **Any of those three failing fails the whole run.** So a
  `--steps` invocation is no longer just "the component module" — it depends on the pod's NODES
  being reachable and correct, and a component install can die with an access error before its
  own module ever starts. Read the log for `集群接入:` before blaming the component.
- **It takes no run id**, unlike every script in Steps 1–7. It acts on whatever `cluster.conf`
  the pod you exec into holds, so it is only as safe as that pod. Confirm the pod first — the run
  id is in its name.
- **It bypasses the verdict contract.** You get module stdout, not a `RESULT:` line, and nothing
  reaches `verdict/`. So **the independent cluster check is the only evidence** — inspect the
  namespaces and the control-plane pods yourself; do not read the closing banner as proof.

Follow it with the module's own verify step where one exists — `verify_metallb`,
`verify_ceph`, `verify_multus`, `verify_rdma_shared_dev_plugin`, `verify_registry_storage`,
`verify_metax_gpu`, `verify_lws`, `verify_kube_vip`:

```bash
kubectl exec <pod> -- sh -c 'cd deployments/scripts && ./deploy-cluster.sh --steps verify_ceph'
```

That path also honours `CEPH_ENV_CONFIRM_SLEEP=0`, which skips the external-Ceph 60-second
countdown — worth setting once you have reviewed those parameters yourself.

## Step 1 — Provision VMs (delegate; never create VMs here)

> **VM provisioning is delegated.** The sibling skill `suanova-dev-vm` owns all VM
> mechanics: manifests, cloud-init `passwd` hashing, `kubectl apply`, the REDACTED gate,
> and `VirtualMachinePool`. Never write VM YAML or apply VM/pool objects from this skill.

Hand `suanova-dev-vm` the resolved parameters: single-node → `VirtualMachine` named
`cubestack<N>`; multi-node → `VirtualMachinePool` named `cubestack<N>` with
`replicas=<node-count>` (its §8). Same subnet label and `nodeSelector` for every VM, owner
label set, RWX/Block/`ceph-rbd-kubevirt` disks, cloud-init `passwd` + `ssh_pwauth: true`
and **no** `ssh_authorized_keys` (the installer injects its own keypair via sshpass).

> **Do not hand it a network name.** Every VM gets its underlay address from a cubestack-ipam
> pool claim and its own minted NAD (`default/<vm-name>-static`); for the pool case the
> `VirtualMachinePool` template must carry **no** `networks[]`/`interfaces[]` at all — the
> admission policy injects each member's own reference. A template that names one NAD gives
> every member the same one, and on a `static` pool that duplicate is silent.

**Demand that the sibling skill wait until every VM is Running, Ready=True with an IP
before it returns. Do not write your own wait or poll loop here.**

Then confirm by exact name and let `vm-ready` produce the address list:

```bash
"$S/vm-ready" --run <run-id> --pool cubestack3 --expect 3   # or: … cubestack3-0 cubestack3-1 …
```

`vm-ready` matches **by exact name** — it has no `-l owner=` mode, because a pool puts
`owner=` on its VM objects but the VMIs those VMs create do **not** carry the label, so an
owner-selected list silently returns other runs' VMs and looks permanently not-Ready. The
verdict carries `vms=<name>@<ip>,…` plus the master/worker split, so you never re-resolve
names, ordinals or addresses.

If the VM pool feature gate is off, that is `E_POOL_GATE_OFF` → `stop-report:admin`.
**Never silently fall back to N standalone VMs** — that changes the resolved topology.

## Step 1b — Reserve the box's VIP block from the host's IPAM

**On a metallb run only** (the default), and once the VMs exist:

```bash
"$S/reserve-vips" --run <run-id>
```

It reserves a **contiguous block** of addresses from the host's cubestack-ipam as a single
`IPRangeRequest` and records the block as `POOL_RANGE` in `run.env`; `configure` (Step 4) then feeds
that block to the installer as `METALLB_POOL`. See **VIPs come from the host's IPAM** above for why
the addresses are reserved rather than chosen, and what the request is.

**How many addresses is `--count`, and it is a property of the run.** The default is 2: that is the
shape of a box with the in-cluster registry **on**, where the registry takes the block's low address
and the gateway's data plane takes the high one. A box with `REGISTRY_ENABLED='false'` has no
registry, so its only consumer is the gateway and reserving two would strand an address for the life
of the box — pass `--count 1`.

> **It cannot be derived here.** `configure` sets `run.env`'s `REGISTRY_REQUESTED` from the values
> file, but it runs at Step 4 and this runs at Step 1b, so the count has to be passed in. Read it off
> the values file you are about to hand `configure`.
>
> **It is first-invocation-only, because `spec.count` is immutable.** The API server refuses to
> change it, so the live request always wins: a re-run with no `--count` reuses the recorded one
> silently, and an explicit `--count` that disagrees fails with `E_VIP_COUNT_IMMUTABLE` →
> `stop-report:user` rather than dying on a confusing patch error. To change the size **before** the
> deploy, `--release` and re-run — the re-drawn block may land somewhere else. After the deploy has
> baked the range into `cluster.conf` the size cannot change at all, and the step says so.

**Why here, and why not later.** Three mechanical reasons, none of them stylistic:

- The request's `ownerReferences` points at the box's **master `VirtualMachine`**, so it needs that
  VM's `uid` — which means Step 1 has to have run.
- The VMs must have claimed their own underlay addresses first, so the box's own consumers are out
  of the search space.
- `configure` reads `POOL_RANGE` from `run.env` at Step 4, so the block has to exist by then.

It needs **no pod** and no deployed-cluster kubeconfig — it talks only to the host cluster — so it
can be issued any time after Step 1, in parallel with Steps 2 and 3 if you like.

`--ipam-kubeconfig` is the **path** to the KubeVirt cluster's kubeconfig and defaults to
`$KUBECONFIG`, so exporting that once at the top of the run is enough. `--ipam-pool` names the pool
(default: the host's only one). Add `--dry-run` to report what is already reserved and what would be
requested — it creates nothing, touches nothing, and spends no retry. The block itself is the
controller's choice (the lowest free contiguous run), so a dry run cannot preview the addresses.

It is **idempotent**: a re-invocation reads the recorded block back and never re-draws it
(`reused=1`), and it re-reads rather than re-applies, so it cannot silently repoint the request's
owner at a stale `uid`. That matters because a re-draw after the deploy would put MetalLB off-ledger,
so a re-run whose request has gone missing *and* whose run has already deployed fails loudly with
`E_VIP_CLAIMS_LOST` → `stop-report:user` rather than silently reserving a different block.

> **A `preflight` re-run resets `POOL_RANGE`** (it owns that key), so re-run Step 1b afterwards.
> `reserve-vips` recovers the block from the live request rather than reserving again, and
> `configure` refuses a metallb run with an empty pool (`E_VIP_POOL_MISSING` →
> `rerun:reserve-vips`), so a missed Step 1b is caught before the deploy rather than by it.

> **A run reserved by an earlier build of this script keeps working.** Those runs hold their block as
> individual `IPRequest`s; Step 1b reuses those too, read-only, and never converts them — converting
> would make the ledger hand back a *different* run of addresses while the deploy still had the old
> range baked in. The verdict says `legacy=1` when that happens.

> **`--release` gives the addresses back** (destructive, never implicit, never part of the flow).
> The normal lifecycle is the ownerRef: delete the master VM and the request goes with it. `--release`
> is for a box torn down *without* its VM being deleted.

## Step 2 — Create the installer pod

```bash
"$S/pod-up" --run <run-id>          # --subnet defaults to run.env SUBNET
```

> **Omit `--subnet` once `preflight` has run.** `run.env` already holds it, and passing the
> wrong value is costly rather than merely wrong. The value is the **label** preflight
> printed as `subnet=` (e.g. `10-66-3-0`). A label mismatch reads as subnet drift, so `pod-up`
> deletes the healthy pod and recreates it against a `nodeSelector` that matches no node,
> discarding whatever the run had already fetched. `pod-up` now refuses a label no node
> carries — before anything is deleted, and without spending an attempt.
>
> There is no longer an NAD name to confuse it with: `preflight` used to print a `nad=` field
> alongside `subnet=`, and passing that by mistake is what cost a run its pod. That field is gone
> as of 2026-09-29 (the shared underlay NAD was deleted, and a VM's network attachment is now
> resolved by the `suanova-dev-vm` skill, not here). The guard stays because the failure was
> expensive, not because the hazard is still reachable.

**The pod name is never fixed — it is `<pod-prefix>-<run-id>`, e.g.
`cubestack-install-cubestack3`.** A shared, fixed name is not merely cosmetic: with two
runs in flight the second run's `apply` targets the first run's pod, and because
`kubevirt.io/subnet` is immutable that apply path **deletes and recreates it** — throwing
away the whole offline fetch (an hour of pulling, tens of GiB) and the `cluster.conf` the first
run had already paid for.
Discovery is scoped the same way: no run adopts a pod it did not name, and `--pod <name>`
is the only way to point a run at an existing pod (it is then recorded in `run.env` so
later steps follow it).

Within one run, reuse still works and still skips the fetch: the name is stable for the
life of the run, so a re-invocation finds its own pod, reports `reused=1 fetch=present`,
and takes it as-is. On drift it deletes and recreates.

**Run Step 1 and Step 2 concurrently** — `pod-up` needs only the subnet label, not the
VMs, so the image pull overlaps provisioning. Step 3 is the join point.

## Step 3 — Verify the environment from the pod

```bash
"$S/env-probe" --run <run-id> --vms cubestack3@10.66.3.21 --password '<ssh password>'
```

One call covers, in fixed order: pod exec, `sshpass` (installing it if missing), VM port
22, password SSH per VM, MinIO, Harbor. Failing VMs are batched into a single verdict, and
the verdict reports `checked=<n>` so "0 of 3 probes ran" can never look like OK. On success
it writes the `env-ok` stamp.

A VM that rejects password auth is `E_SSH_AUTH` → `sibling-vm:rebuild:<names>` (it was
created by this run). Do not SSH-debug it yourself.

## Step 4 — Write `cluster.conf`

```bash
"$S/configure" --run <run-id> --values <values file>
```

`configure` owns the whole credential path: local lint (refusing `***` **before anything
crosses the wire**) → `chmod 600` → `kubectl cp` → run the repo rewriter → byte-gate the
result on disk → shred the pod-side copy on any exit path.

It regenerates an existing `cluster.conf` **in place**. It never re-copies
`cluster.conf.example` over an existing config — that would wipe Ceph/MetalLB/NODES from a
prior attempt. The rewriter ships as `scripts/lib/cubestack-apply-conf.py`; you neither
author nor edit it.

> **The MetalLB pool reaches `cluster.conf` from `run.env`.** A values-file `METALLB_POOL` always
> wins; otherwise `configure` fills it from Step 1b's `POOL_RANGE`. Neither key is set by hand — the
> reserved block is the only pool this design has, and a hand-set range would not be ledger-reserved,
> which re-opens the collision the reservation closes. A metallb run with **no** pool fails here as
> `E_VIP_POOL_MISSING` → `rerun:reserve-vips` (Step 1b), rather than at the rewriter twenty minutes
> into the deploy.

When Step 0 was given `--external-ceph-env`, `configure` also places that file — it reads the
path from the run dir, so **you do not pass it again** — and hash-verifies the copy. It is left
in place deliberately: the installer sources it mid-deploy. `pod-down` removes it.

> A real run **rewrites the pod's live `cluster.conf`**, replacing whatever credentials it
> holds with the ones in your values file. To inspect or smoke-test against a live pod
> without mutating it, add `--dry-run`: it validates and prints the resolved plan, then
> stops before any write. A dry run is read-only and never spends a retry; the real one does.

> **`configure` invalidates `env-ok`, so `env-probe` must run a second time before Step 6.**
> The stamp attests the SSH password and VM digest the deploy will actually use, and a
> config change can invalidate the password env-probe already proved — so `configure` clears
> it on purpose. `deploy` refuses to launch without a current stamp
> (`E_DEPLOY_PRECOND_ENV`), so the real order is **Step 3 → 4 → 3 again → 6**. The second
> `env-probe` is expected, not a recovery: re-issue the identical command. Budget for it —
> a healthy run invokes `env-probe` twice.

Steps 4 and 5 are independent — issue them as parallel tool calls. Each copies its values
file to its own pod-side temp path (`/tmp/cubestack-values.<script>.conf`), so neither
deletes the other's; a shared path would have one script `rm` the file the other is about to
`source`.

## Step 5 — Fetch the offline packages

```bash
"$S/fetch-offline" --run <run-id> --values <values file>
```

Seeds `deployments/config/minio.conf` (which is what the fetch actually reads — *not*
`cluster.conf`) via a repo helper, byte-gates it, then fetches the offline tree. Idempotent: `du`
on `offline-files/` is the only evidence a prior fetch completed, so a re-run above the floor
returns `skipped=1`. A partial tree is `E_FETCH_PARTIAL`, never silently accepted.

**The floor is the operative number, not any GiB figure in this document.** `deploy` refuses to
launch below **15360 MiB** (`CS_FETCH_FLOOR_MB`); the fetch script carries its own `--floor`
(15000 MiB). The ~26 GiB this document used to quote was measured on a build whose tree still
contained the envoy and observability image groups, which no longer exist — so treat it as an
upper bound, not a target, and check the actual size with
`kubectl exec <pod> -- du -sh deployments/offline-files` rather than comparing against a number
here.

**The images are never baked into the installer image — they only ever come from here.** So a
fresh pod has an empty `offline-files/` and every module will fail on a missing image until this
step runs. That matters most after `pod-up --recreate`, which discards the tree: an
image-not-found error from a module is far more likely to mean *this step was skipped* than that
the image does not exist. Re-run it before diagnosing anything else.

The per-component layout is worth knowing when one addon is missing rather than all of them.
`offline-files/` is split by group — `lws/`, `metax-gpu/`, `multus/`, `netshoot/`, `nginx/`,
`rdma/`, and `kubespray/images/` for the base **and** the Ceph images (those two share a
directory deliberately: both are preloaded into the nodes' containerd) — so
`ls offline-files/multus/` answers directly whether the Multus images are present.
`fetch-offline-from-minio.sh` defaults to the deployment-necessary subset.

## Step 6 — Deploy

```bash
"$S/deploy" --run <run-id> --vms cubestack3
```

Launches `deploy-cluster.sh` detached in the pod and returns immediately. It re-asserts
cheap preconditions first (no `***` in `cluster.conf`, offline files above the floor,
`sshpass` present, `env-ok` current), turning a 12-minute `local_path` death into a
1-second failure. It refuses to launch if a deploy is already running
(`E_DEPLOY_ALREADY_RUNNING` → `recover="rerun:deploy-wait"`).

Then wait for it **as a background task**:

```bash
"$S/deploy-wait" --run <run-id>          # run_in_background: true
```

> **`deploy-wait` MUST be a background task.** A deploy takes 12–40 min and the Bash
> tool's foreground ceiling is 600 s. The harness re-invokes you when it exits — that *is*
> the no-polling behaviour. Do not poll, and do not re-run it in a loop.
>
> **Completion is process exit, never the banner.** The `✅ 一键部署流程完成` banner is
> cosmetic and is the first thing lost if a deploy is killed at the end. `deploy-wait` keys
> on the process and grades the `PLAY RECAP`; a missing banner is not a failure.
>
> If background tasks are unavailable, the fallback is **not** a model loop: use
> `--chunk 540`, which returns `RESULT: OK running=1` for a bounded number of
> re-invocations.

`deploy` records the sorted VM-name set on first launch, and **auto-applies `--fresh`** when a
later invocation presents a different set — a resumable state prepped for one set of VMs makes
`k8s_deploy` report `已完成,跳过` and the deploy then dies at `local_path` with no cluster at all.
That drift is not a failure and produces no code: it is a `cs_note`, and the `OK` verdict carries
`fresh=1`. So the normal action on any `deploy` recovery verb stays `rerun:deploy` — it detects the
drift itself and no verdict ever asks you to pass `--fresh` to it. `--fresh` is a manual escape
hatch for the case the drift check cannot see (same node set, a state you need discarded anyway).

## Step 7 — Verify the k8s box, build the cubestack box, clean up

```bash
"$S/verify" --run <run-id> --expect-nodes 3   # external-Ceph checks turn on by themselves for an importing run
```

One call replaces ~10 independent `kubectl get`s. It refuses vacuity explicitly — zero
nodes is `E_VERIFY_NODES`, not a vacuous OK — and on success writes the `verify-ok` stamp.

**On a metallb run, `verify` also asserts the reservation.** When `run.env` carries `POOL_RANGE`
(Step 1b ran), it checks that the cluster's `IPAddressPool` holds exactly the reserved block and
that every `LoadBalancer` Service with an `EXTERNAL-IP` sits inside it, reporting `pool_range=` and
`vip=` in the verdict. There is **nothing to do here for the registry** — its VIP was settled at
Step 1b and the installer applied it during the deploy, so no Service is patched and no pool is
replaced after the fact.

**Only if Step 0 was given `--cephfs-mount-guide`** — mount `/models` on every node, *here*,
after the k8s box is proven and before the pod goes away:

```bash
"$S/mount-models" --run <run-id> --vms <the Step 3 verdict's vms= list>
```

The pod is the only host that can reach the nodes, so this step cannot run later —
`pod-down` deletes it. `--guide` is read from the run dir, so it is not passed again.
The mount is read-only, persisted in `/etc/fstab` with `_netdev` so it survives a reboot, and
idempotent: a re-invocation reports `already=<n>` and re-asserts the files and the fstab line.

> Add `--dry-run` to parse the guide and print the resolved plan **without** touching a pod or
> a node. It is local and read-only, so it never spends a retry — the cheap way to check the
> guide is the right one before committing to the step.

**Only if Step 0 was given `--harbor-ro-values`** (i.e. this run is building a cubestack box) —
turn the k8s box into a cubestack box, *here*, for the same reason as the mount: the pod is the
only host that can reach it.

```bash
"$S/operator-up" --run <run-id>          # chart + Secret + CR + operator roll; ~30 s
```

`operator-up` also **rolls the operator Deployment** onto whatever image the chart's rolling
tag resolves to, and reports the digest as `image=sha256:…`. That is what makes re-invoking it
the way to pick up a republished operator image (`rerun:operator-up`, the recovery for a
component `Degraded` by a bug upstream has since fixed) — a re-run that only re-applied the
chart would leave the old binary running and the same Degraded state behind it.

```bash
"$S/operator-wait" --run <run-id>        # run_in_background: true
```

> **`operator-wait` MUST be a background task.** A five-component bring-up installs dozens of
> objects and pulls five OCI charts, on the operator's own 30 s requeue — minutes, not seconds,
> and past the 600 s foreground ceiling. The harness re-invokes you when it exits — that *is*
> the no-polling behaviour. Do not poll, and do not re-run it in a loop.
>
> If background tasks are unavailable, the fallback is **not** a model loop: use
> `--chunk 540`, which returns `RESULT: OK running=1` for a bounded number of re-invocations.
> Unlike `operator-up`, re-invoking it is free — it is read-only against the k8s box
> and holds no credential.

What the pair does, in order, and why the order is not negotiable:

- **`operator-up` pulls the chart** `oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart`,
  using the robot credential from the run's file — staged into the pod as a mode-600 file,
  hash-verified, and shredded on every exit path. The credential is read **inside** the pod, so
  the password never reaches an argument list, an environment variable, or a process list on
  either host — the four chokepoints a chart pull normally opens (`kubectl cp`, the `bash -c`
  text, the pod's process list, and `kubectl create secret`) are each closed.
  The tag is **`1.0.0-latest`** — confirmed, not guessed: the operator's own quickstart uses it
  (`--version 1.0.0-latest`), and its publish workflow pushes a rolling `<Chart.yaml version>-latest`
  on every main push and a bare `X.Y.Z` only for a release tag, of which none has been cut.
  `--version` is the lever when one is.
- **It then creates the `harbor-credentials` Secret before the chart — in the operator's
  namespace *and* in every component namespace.** Two consumers, two different rules:
  - The **operator** reads it in its **own** namespace, and this is the step that is easy to
    skip and impossible to notice: `registryauth.Resolve` errors outright when the Secret the
    CR names is absent, so the CR would never converge and would name no component at all — a
    failure with no component to point at.
  - The **kubelet** reads pull secrets only from the namespace a pod runs in, so the
    `cubestack-system` copy does nothing for a pod in `lws-system`. The three component
    namespaces are therefore created **up front**, with the Secret, rather than copied into
    after the operator makes them — the operator's `EnsureNamespace` is a server-side apply,
    so it merges its own labels into a namespace that already exists. Doing it up front is what
    closes the window where the operator renders a Deployment into a namespace the kubelet
    cannot yet pull into.
  The namespaces come from the operator's catalog, not from guessing: its components live
  in `cubestack-system`, `lws-system`, `envoy-gateway-system` and `ai-gateway-system`. The list is
  the catalog's, so `ai-gateway-system` is staged even though the profile ships `aiGateway`
  disabled — the namespace is then empty and the Secret unused, which costs nothing and keeps
  re-enabling the component a one-line CR change. The Secret
  is built from the values file inside the pod (`--from-file`, never the `--docker-password`
  flag, which would put the token in the pod's process list).
- **Two pull policies are set, and they cover different things.** `image.pullPolicy=Always` for
  the **operator's own** image, and `imagePullPolicy: Always` in the CR's `global` for the
  **platform's own components**. Both exist for the same reason: these images are tagged
  `:latest`, and the charts default to `IfNotPresent`, so a node that cached one would keep
  running that build forever without any signal. Third-party components keep their own chart's
  policy either way.
- **`operator-up` then ROLLS the operator Deployment, and the policy above is not a substitute
  for it.** A pull policy governs only a pod that is **created**, and a re-invocation renders a
  byte-identical Deployment — so Kubernetes sees no pod-template change, creates no pod, the
  policy never fires, and `helm --wait` returns at once because the *old* Deployment is already
  ready. Without the roll, a re-run prints `RESULT: OK` while the box keeps running the previous
  operator binary. That is not cosmetic: the operator's component catalog and every extra asset
  are compiled into its image (`//go:embed all:components all:observability all:charts`), so an
  asset fixed upstream has **no effect on a box until the pod is replaced**. The roll is
  deliberately unconditional — the chart's tag is a rolling `latest`, and the only registry
  access on this path is helm's, inside the pod, so there is no current digest on this host to
  compare against. It is also what makes **re-running `operator-up` the way to pick up a
  republished operator image**, which is the recovery for a component Degraded by a bug that
  upstream has since fixed. The verdict names the digest it rolled onto
  (`image=sha256:…`), and records it in the `operator-applied` stamp: under a rolling tag the
  digest is the only thing that distinguishes two builds.
- **Only then the CR**, from `scripts/lib/cubestack-cluster.yaml` — a versioned file rather than
  a `--set` string, so "which components are enabled" is reviewable rather than an argument list:
  `lws`, `envoyGateway`, `cubestackControllerManager`, `cubepilot`, `cubestackPortal` — plus
  `aiGateway` listed and set `enabled: false`, the one component nothing else depends on. Install
  *order* is not in the manifest: each component's `order` comes from
  the operator's own catalog, and the operator reconciles on a 30 s requeue.
  The portal entry carries a `values` block holding its login credential
  (`secrets.htpasswd.content`, one `user:bcrypt-hash` line), and it is **not decoration** — the
  portal chart creates the htpasswd Secret only when that value is non-empty, so enabling the
  component without it yields a UI with no account, and no verdict anywhere goes red. The shipped
  hash is the operator chart's own published default, i.e. a publicly known credential: adequate
  as a default that leaves a fresh box loggable, not for anything reachable. Override the same
  path to replace it — the operator deep-merges `spec.components.<name>.values` **last**, after
  catalog defaults and global injection.
- **`operator-wait` then polls `status.conditions[type=Ready]`** every 30 s and reports
  `ready=1 components=<n>/<n>`. A component the operator marks `Degraded` is observed **twice**
  before it fails — a fresh rollout's first health check legitimately lands there for one cycle,
  and failing on first sight would report a healthy bring-up as broken. A Degraded component
  whose message names an image pull or an auth failure is `E_OPERATOR_IMAGE_PULL`
  (`recover="fix-values:<file>:HARBOR_RO_USER,HARBOR_RO_PW"` — the one Degraded cause a
  re-`Write` can clear); anything else is `E_OPERATOR_COMPONENT_DEGRADED` → `stop-report:user`,
  because the operator's message is naming a real problem and a retry does not clear it.
  That verdict names the operator's build — `image=` is the digest of the **live** operator pod
  and `installed=` is the one `operator-up` last rolled onto — precisely so the reader can tell a
  live defect from a stale binary. Under a rolling `latest` tag the two look identical otherwise,
  and a fix that never reached the box presents exactly as a fix that did not work: `installed=unrecorded`
  means the stamp predates the roll and the binary may predate the fix, and a mismatch between the
  two means the operator has since been replaced.

> **Unverified, and the first thing to check if a component cannot pull: whether the deployed
> *nodes* can reach Harbor at all.** The installer's own design has the opposite shape — the pod
> pulls an image, the module pushes it into the **in-cluster** registry
> (`registry.cubestack.io:5000`), and the nodes pull from there, so that "集群永远不需要访问公网"
> (`docs/harbor-mirror.md` §2). Every run so far follows it: `verify` lists a `registry` Service,
> and the addon modules push to it themselves (`skopeo copy docker-archive:… → docker://…`,
> `07_gpu_lws.sh` step 1). This CR is the first thing that asks a **node** for
> `harbor.isuanova.com` directly — and `env-probe` only proves Harbor **from the pod**
> (`env-probe:268`, both the DNS and the TCP probe). If a node has no route, the symptom is
> `E_OPERATOR_IMAGE_PULL` with an `ImagePullBackOff` message that reads exactly like a bad
> credential. **Tell the two apart before re-`Write`ing anything**: SSH to the run's VM
> (`ubuntu@<vm-ip>`, the run's SSH_PW) and
> `curl -sS -o /dev/null -w '%{http_code}\n' https://harbor.isuanova.com/v2/` — *any* status,
> `401` included, means the node reaches Harbor and the credential is the real problem; a
> resolution or connect failure means it does not, and no new password will fix it.

> Add `--dry-run` to `operator-up` to lint the credential, assert the CR manifest and print the
> resolved plan **without** a pod or a cluster. It is local and read-only, so it never spends a
> retry — and it deliberately sits *above* the `verify-ok` gate, because it is a check on a
> cluster it does not touch. `operator-wait` has no dry run: it applies nothing.

**On a metallb run the gateway needs no step at all.** Its data-plane Service does not exist until
the component charts have run, so under the old design this was the last step that still needed the
pod — it had to find that Service and pin a second address to it. Now it simply takes the block's
**high address** by `autoAssign`, because that address is already reserved and sitting unused in a
two-address pool. Nothing is patched and nothing is claimed here.

> **Check it once `operator-wait` returns**: `kubectl -n <gateway-ns> get svc` should show the
> gateway's `EXTERNAL-IP` equal to the reserved block's high address. This is the one assignment in
> the run that MetalLB makes on its own, so it is the one worth looking at — `verify` ran before the
> gateway existed and could not have asserted it.
>
> **A third LoadBalancer Service sits `<pending>` forever** against a two-address pool. That is the
> honest outcome — no address is invented — and it is strictly better than the old design, where
> MetalLB would have silently handed out an address inside the host's IPAM band.

> **Undoing a reservation.** Deleting the box's master node VM garbage-collects the request and frees
> the addresses — the ownerRef is the normal lifecycle, and it is what happens on a normal teardown.
> `reserve-vips --release` is the escape hatch for a box torn down *without* its master VM being
> deleted: it deletes the request and forgets the block. It is destructive, never implicit, never
> part of the flow — and it does **not** touch the running cluster, so a box that is still up keeps
> announcing addresses the pool has already handed back. Tear the box down first, or release first.

```bash
"$S/pod-down" --run <run-id>           # refuses without a verify-ok (and operator-ok) stamp
```

Deletes the bootstrap pod; the k8s box lives on the VMs and is unaffected.

> **`pod-down` now gates on `operator-ok` too, on a cubestack-box run.** The pod
> is the only host that can reach the k8s box, so deleting it before the operator
> converges leaves no way to retry at all — neither `operator-up` nor `operator-wait` has
> anywhere left to run from. It refuses rather than warns, and `--force` is the deliberate
> override for a run you have decided to abandon.

## When something fails

```bash
"$S/diagnose" --run <run-id> E_DEPLOY_KUBESPRAY_SSH   # bounded excerpt, returns a path
```

`diagnose` never dumps a log into context — it prints an excerpt and a path. Prefer it over
reading raw logs, which is what used to make a failed run expensive.

**Never delete another run's resources.** VM/pool deletion is destructive (it takes the RBD
PVCs and the data with it) and is **always** user-requested.

**Reserve through the ledger, never by hand.** A VIP address comes from Step 1b's reservation and
from nowhere else: never hand-set `METALLB_POOL`, never hand-write an `IPRangeRequest`, and never
pin a `LoadBalancer` Service to an address you picked. The whole design rests on every address
MetalLB can reach being one the host's IPAM has already bound to this box, and a hand-chosen address
is exactly the bet that removes.

**The two range codes that look alike are a *compact* and a *widen*, and both are the controller's
verdict now.** `E_VIP_RANGE_FRAGMENTED` (`stop-report:admin`) means the pool has free addresses but
none `count` of them adjacent — a bound address sits in the middle, so the remedy is to compact or
widen the pool, and retrying cannot help. `E_VIP_RANGE_EXHAUSTED` (`stop-report:admin`) means there
are too few free addresses left at all. They used to be told apart by claiming a probe address and
inferring; the controller now reports the reason directly, so the verdict carries the enum rather
than a guess. `E_VIP_CLAIMS_LOST` is `stop-report:user`: the request behind the recorded block is
gone but the run has already deployed, so re-reserving could hand MetalLB an address the ledger no
longer binds to this box.

## Hard rules

1. Ground truth is `kubectl` — never fabricate cluster state.
2. **Never create, rebuild or delete VMs from this skill** — delegate to `suanova-dev-vm`.
3. Never write credentials with `sed`/`echo`/heredoc; use `Write` + `--values`.
4. Never re-author a script's logic inline because it "should be simple" — if a script is
   wrong, fix the script, and never substitute a hand-written loop for a bounded wait.
5. Never run a wait in the foreground if it can exceed ~60 s — a foreground child defers the
   verdict trap, so a killed script would emit nothing for minutes.
6. Never retry past `E_RETRY_BUDGET`; that is a `stop-report`.
7. Never advance past a `stop-report:*` verdict.
8. No host-specific infra config in this skill (kubeconfig path, secrets, IPs).
9. **Pass `--run <run-id>` on every script invocation, and never invent one.** It comes from
   Step 0's `run=`. It is what keeps two concurrent installs apart; a wrong or missing id
   points a step at another run's state, and the scripts will not stop you from doing that
   if the id happens to name a real run.
10. **Never hand-author the `CubeStackCluster` CR, and never build a `dockerconfigjson` in a
    shell.** The profile's components live in `scripts/lib/cubestack-cluster.yaml`, which
    `operator-up` copies into the pod and applies; the pull Secret is built from the values
    file inside the pod, by `kubectl create secret --from-file`. Both are reviewable files
    and deterministic scripts for the same reason the rest of this skill is: an ad-hoc
    `kubectl apply -f -` here would leave the cluster in a state nothing in the run dir
    records, and a heredoc'd credential is refused by the redaction gate anyway.
11. **Never hand-assign a VIP, and never patch the cluster's MetalLB config after the deploy.**
    The pool is exactly the block Step 1b reserved; `autoAssign` staying true inside it is
    deliberate and safe *only* because every address in it is already ledger-bound to this box.
    Widening the pool, pinning a Service, or replacing the pool all restore the collision this
    design removes. `reserve-vips --release` is the only supported way to give an address back.
