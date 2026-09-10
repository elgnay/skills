---
name: "cubestack-install"
description: "Install CubeStack on a KubeVirt VM: VM, pod, MinIO fetch, configure, deploy kubespray. Asks the user once (Step 0 prereqs + one confirm), then runs Steps 1-7 unattended with no further approvals and auto-deletes the bootstrap installer pod once the deploy is verified. Subagents per phase keep context lean."
---

# CubeStack Installation

Install a single- or multi-node CubeStack cluster on KubeVirt VMs. The installer runs
inside a K8s pod (bootstrap host) and SSHs into the target VM(s) to run kubespray.

> **Ground truth is `kubectl`.** Verify cluster state before acting; do not guess VM
> names, IPs, or config fields. Read `cluster.conf.example` before editing — field
> names and format may differ across installer versions.

## Interaction model: one question round, then run unattended

The user is asked **exactly once** — in Step 0 — and then the run proceeds through
Steps 1–7 **without any further approval or prompting**. This is the default
operating mode.

- **Step 0 is the only interaction.** Collect prerequisites, resolve unstated
  items to defaults, and get **one** confirmation of the resolved plan. After that
  confirmation the orchestrator drives every step to completion on its own.
- **No approval gates anywhere else.** There is no "show the diff and wait", no
  per-step check-in. Quality gates that *do* exist are **automatic** (they never
  block on the user): the byte-verification gate in Step 4 and the read-only
  `kubectl` verifications are self-checking — the orchestrator blocks only if a
  gate itself fails, and then it applies the documented recovery.
- **Automated recovery instead of asking.** If a step fails, the orchestrator
  applies the recovery described in that step (re-run the subagent, rebuild the
  VM via the sibling skill, retry with `--fresh`, etc.) without consulting the
  user. It only stops and reports when a recovery fails or an external blocker
  appears that genuinely needs the user (e.g. the `VMPool` gate is off and needs
  an admin; a VM auth failure persists after a rebuild).
- **The bootstrap pod is ephemeral.** The installer pod (`cubestack-install`) is
  only deploy tooling. Once Step 7 verification passes, the orchestrator deletes
  it automatically — the deployed cluster lives on the VMs, not in the pod. What
  *is* left for the user is the running CubeStack cluster on the VMs.
- **Report at the end.** Progress is still reported to the user (subagent
  start/finish, key results) so the run is observable — reporting is not asking.

## Orchestration: subagent-per-phase

Every long or tool-heavy phase runs in its own subagent. The main session stays the
**orchestrator only**: it collects prerequisites, spawns subagents, relays results
between phases, and reports progress. It never runs `kubectl exec` loops or large
manifests directly.

**When to spawn:** any phase that will run more than ~5 `kubectl exec` calls, read
large files, or poll a long-running job.

**When to run inline:** quick single-command lookups the orchestrator needs between
spawns (e.g. confirming a pod is ready before handing off to the next phase).

**Context passing:** pass the minimum state the next phase needs (VM names, IPs,
subnet label, pod name, node roles). Do not pass full transcripts or raw `kubectl`
output. Each subagent reads live cluster state with its own `kubectl` calls.

**Progress:** update `progress_card` in the main session when a subagent starts or
finishes — one line per phase, e.g. `VM creation: done` / `Deploy: running`.

**Steps 1 and 2 run concurrently.** The installer pod (Step 2) depends only on the
Step 0 **subnet label** for its `nodeSelector` — it does **not** need the VMs to
exist. So immediately after the Step 0 confirmation the orchestrator spawns the
Step 1 (provision VMs) and Step 2 (create installer pod) subagents **at the same
time** and waits for *both* before Step 3. The pod's image pull + start (~1–2 min)
overlaps the pool provisioning (~2 min); Step 3 is the join point and needs both
(VMs + pod) Ready.

**Wait protocol: fixed commands only — nobody authors a wait loop.** Every
readiness/completion wait in this skill is a **fixed, deterministic command shown
verbatim** in its step. Subagents and the orchestrator **run those commands as-is
and report the output**; they never compose their own loop, sleep-cycle, or
comparison-based wait. A wait that is a single quick lookup runs in the
**orchestrator** inline (one `kubectl get` / `kubectl wait`, no loop — e.g. the
Step 1 by-name Ready confirm). A wait that is long-running runs in a **watch
subagent using that step's verbatim poll command**, which is written to end the
moment its fixed stop condition prints. A fixed wait that times out is **reported,
not extended**; the caller applies the step's documented recovery. An agent that
writes its own wait logic instead of running the fixed command is the one failure
mode this skill treats as a defect: every hand-authored loop that has appeared here
(a pool-VMI `owner=` poll, a banner-keyed deploy poll, a `vm_ready` case bug)
silently burned 8–13 min on healthy state. Hard rule 24.

> ⚠️ **Subagents cannot prompt the user, and neither does the orchestrator after
> Step 0.** All user-facing answers are collected in Step 0 *before* any
> subagent spawns. If a subagent reports a blocker, the orchestrator does not go
> back to the user — it applies the automated recovery for that step. The only
> exception is a blocker that recovery cannot clear and that genuinely requires a
> user decision (admin-enable a feature gate, decide whether to destroy a
> pre-existing VM, etc.); the orchestrator then stops and reports, rather than
> silently guessing.

## Cluster facts (verify before acting)

| Item | Value |
|------|-------|
| KubeVirt cluster | v1.35.4, 3 nodes, KubeVirt v1.8.4 / CDI v1.65.0 |
| Golden images | `ubuntu-22.04/24.04/26.04-server-amd64-img` in `default` ns |
| Storage | Rook/Ceph RBD; SC `ceph-rbd-kubevirt` (RWX Block) |
| MinIO (offline pkgs) | endpoint http://192.168.16.6:9000, bucket cubestack-installer, dir offline-files; alias: mc alias set minio <endpoint> admin Suanova@123 (verified working 2026-09-07) |
| Harbor (installer img) | `harbor.isuanova.com` |
| Installer image | `harbor.isuanova.com/cubestack/cubestack-installer-cli:latest` |

> **Subnets are dynamic.** The cluster has multiple subnets (e.g. 10.66.2.0/24,
> 10.66.3.0/24) with one node per subnet or shared. The target VM's subnet determines
> the pod's `nodeSelector`, the NAD, and the MetalLB pool range. Query the cluster
> for the actual subnet labels and NADs — do not assume a specific subnet.
>
> **All cluster nodes should be in the same subnet.** This enables live migration
> between nodes and keeps MetalLB/pod networking on a single L2 domain.
> If the
> user requests multiple subnets, confirm they understand the tradeoffs (no
> cross-subnet migration, more complex LB routing).
>
> **VM IPs are managed by Whereabouts IPAM** (the cluster's IPAM component). IPs
> are allocated from per-subnet pools (e.g. 10.66.2.200–220) at VM creation and
> do not collide with each other. Do not manually assign or reserve VM IPs.

## Step 0 — The ONLY user interaction: resolve prerequisites (orchestrator, inline)

**This is the single question round for the whole run.** Every prerequisite has a
default. Take what the user specified; fill anything unstated with the defaults
below; auto-query the cluster for the defaults that can't be static (subnet, NAD,
name index). Show the resolved set to the user and get **one** confirmation
before spawning any subagent — don't block on items the user skipped. After that
confirmation, **no further user input or approval is collected** for the rest of
the run (Steps 1–7).

| # | Prerequisite | Default (used when not specified) |
|---|--------------|-----------------------------------|
| 1 | Number of nodes | `1` (single-node). >1 = multi-node master/worker split |
| 2 | Target VM shape | 8 vCPU / 24 GiB RAM / root disk 80 GiB, no extra data disk |
| 3 | Subnet | Auto-select the subnet whose nodes have the most free capacity (query below); NAD = the one bound to that subnet. All VMs go in the **same** subnet |
| 4 | VM owner label | `owner=<OS username of the person running the install>` |
| 5 | SSH password | `ubuntu` (cloud-init `passwd`, matches Step 1) |
| 6 | MinIO credentials | endpoint `http://192.168.16.6:9000`, access key `admin`, secret key `Suanova@123` (verified 2026-09-07) |
| 7 | Service expose mode | `nodeport` (skips MetalLB; no pool needed). Use `metallb` only for a fixed VIP — then ask for the pool IP range |
| 8 | Node roles (multi-node) | `cubestack<N>-0` = master; `cubestack<N>-1…` = workers (pool ordinal order) |
| 9 | VM names | Single-node: **one VM `cubestack<N>`**. Multi-node: **a `VirtualMachinePool` named `cubestack<N>`** with `replicas` = node count (it creates VMs `cubestack<N>-0`, `cubestack<N>-1`, …). N = first free index — no existing VM **or pool** named `cubestack<N>` |

Companion defaults: SSH user `ubuntu`; golden image `ubuntu-22.04-server-amd64-img`;
VM pool `replicas` = node count.

Resolution flow:

1. **Collect** — ask the user **once, in a single message**, for any of items 1–9
   they care about. Silence on an item = use its default. This is the only
   question round of the entire run.
2. **Resolve** — user-specified value wins; otherwise use the default. For the
   auto-queried defaults (subnet, NAD, free name index) run the quick lookups
   inline and pick per the rule:
   ```bash
   kubectl get nodes --show-labels | grep kubevirt.io/subnet     # subnet capacity
   kubectl get network-attachment-definitions -n default          # NAD per subnet
   kubectl get vm -n default -o name | grep 'cubestack[0-9]'             # used VM names
   kubectl get virtualmachinepool -n default -o name | grep 'cubestack[0-9]'   # used pool names
   ```
3. **Confirm** — print the resolved values (mask the MinIO secret and SSH
   password) and get one "ok". This confirmation is the **green light for the
   entire unattended run**. If the user changes anything, re-resolve only what
   changed and re-confirm. After "ok", spawn Steps 1 and 2 **together** (they are
   independent — see Orchestration) and drive all steps to completion without
   asking again.
4. **MetalLB rule** — never ask for a pool range when the mode resolves to
   `nodeport`.

> Defaults are starting points, not ground truth — the cluster decides. If the
> resolved subnet label / NAD / golden image isn't present on the live cluster,
> surface it rather than inventing one. See the Cluster facts table for the
> verified endpoints.

If the VMs don't exist yet, the Step 1 subagent delegates their provisioning to
the sibling KubeVirt skill (`suanova-dev-vm`). The orchestrator never runs
`kubectl apply` for VMs itself.

## Step 1 — Provision VMs via the sibling KubeVirt skill (subagent)

> **Runs concurrently with Step 2.** After the Step 0 confirmation, spawn Step 1
> and Step 2 at the same time and wait for both before Step 3.

> **VM provisioning is delegated — never create VMs from this skill.** The sibling
> KubeVirt skill `suanova-dev-vm` owns all VM mechanics: manifests, cloud-init
> `passwd` hashing, `kubectl apply`, the REDACTED-gate on applied objects, and
> `VirtualMachinePool` (§8). CubeStack only declares *what* it needs; it never
> writes VM YAML, generates password hashes, or applies VM/pool objects itself.

> **Subagent task:** "Using the sibling KubeVirt skill `suanova-dev-vm`, provision
> the target VMs for a CubeStack install. Requirements (resolved in Step 0):
> Single-node → one VirtualMachine named `cubestack<N>`; multi-node → one
> VirtualMachinePool named `cubestack<N>` with replicas=<node-count> (skill §8).
> All on subnet <label> with its NAD <name> (same for every VM). owner label
> `owner=<user>`. CPU <cores> / RAM <size> / root disk <size>. Golden image <image>.
> Cloud-init `passwd` for user `ubuntu` + `ssh_pwauth: true`; do NOT add
> `ssh_authorized_keys`. The sibling skill must wait until every VM is Running
> with Ready=True and has an IP **before returning** — demand that of it. **Do not
> check VM readiness yourself and do not write any wait or polling loop**: after
> the sibling skill returns, return the created VM names + IPs (+ pool name)
> immediately. (The orchestrator does the one by-name Ready confirm at the join
> point before Step 3. A self-authored check here is the #1 way this step silently
> burns minutes — a `vm_ready` case-sensitivity bug once stretched a ~3-min
> provisioning to ~13 min.)"

Hand `suanova-dev-vm` the resolved Step 0 parameters and let it drive creation
(its §2 for a single VM, §8 VirtualMachinePool for multi-node). Do not re-implement
its steps here.

Constraints to hand over:

- **Naming:** single-node VM `cubestack<N>`; multi-node pool `cubestack<N>` whose
  replicas are created as `cubestack<N>-0`, `-1`, … (ordinal order).
- **Same subnet for all VMs:** subnet + `nodeSelector` + NAD must match — a
  mismatch puts a VM on the wrong subnet.
- **Disks:** RWX + Block + `ceph-rbd-kubevirt`, root 80 GiB (default shape 8 vCPU /
  24 GiB RAM unless Step 0 overrode it).
- **Owner label:** the resolved `owner=<user>` must be set on every VM (for a pool,
  on the pool's `virtualMachineTemplate` labels); never omit or invent an owner.
- **Password-only auth:** cloud-init `passwd` (`ubuntu`) + `ssh_pwauth: true`,
  **no** `ssh_authorized_keys` — the installer's `k8s_passwordless` module injects
  its own keypair via sshpass.
- **Pools are alpha:** if the sibling skill reports `vm pool feature gate not
  enabled`, this is an external blocker only a cluster admin can clear (enable the
  `VMPool` gate). Do **not** silently fall back to N separate VMs — that would
  change the resolved topology. The orchestrator stops and reports so the user can
  enable the gate, because it cannot recover this on its own.

After both the Step 1 subagent (relaying VM names + IPs) and the Step 2 pod
subagent return, the **orchestrator** does the single by-name Ready confirm at the
join point — exactly one read-only `kubectl get`, run inline before Step 3 (not a
poll; the sibling skill waited until all VMs/pool replicas were Running with
Ready=True and IPs assigned *before* the Step 1 subagent returned). Record each
VM's IP (Whereabouts IPAM allocated them at creation — never assign or reserve):

```bash
# One read-only get by EXACT NAME (the names the Step 1 subagent returned) — never -l owner=:
kubectl get vm -n default <name1> <name2> ... -o wide    # Ready column: True for each
kubectl get vmi -n default <name1> <name2> ... -o wide   # Running, Ready True, IPs
# pool: kubectl get vmi -n default cubestack<N>-0 cubestack<N>-1 -o wide
```

If every name reads Ready True with an IP, proceed to Step 3. If any name is not
Ready, the sibling skill did not finish its wait — the orchestrator re-spawns a
short subagent asking the sibling skill to finish waiting (the sibling skill owns
the wait; this run does not poll from here).

> ⚠️ **Never gate a readiness check on `kubectl get vmi -l owner=<user>`.** A pool
> puts `owner=` on its VM objects, but the VMIs those VMs create do **not** carry
> the label — so an owner-selected VMI list returns only unrelated VMs from other
> runs and looks permanently "not ready". (This false-negative once burned ~8
> minutes of polling on a healthy 2-VM pool.) VMI name == VM name, so always match
> by name.

**Map node roles for Step 4** (master/worker is decided in `cluster.conf`, not at
VM creation):

- Single-node: `cubestack<N>` is the single master.
- Multi-node: `cubestack<N>-0` = master; `cubestack<N>-1`, `-2`, … = workers.

Password SSH is confirmed later from the installer pod (Step 3), so a VM that
didn't get working password auth (`passwd: "***"` redaction, or publickey-only)
surfaces there — the orchestrator then has the sibling skill rebuild that VM
automatically (Step 3) without asking the user, since it was just created by this
run. Don't SSH-debug or rebuild it from this skill.

**Return to orchestrator:** VM names + IPs, the role map (which VM is
master/worker), subnet label, NAD name, and pool name (multi-node).

## Step 2 — Create installer pod (subagent)

> **Runs concurrently with Step 1.** This step needs only the Step 0 **subnet
> label** (for the `nodeSelector` below) — not the VMs. Spawn it at the same time
> as Step 1; the pod's image pull (~30s) + start overlaps the pool provisioning.
> Both must be Ready before Step 3.

> **Subagent task:** "Create the CubeStack installer pod. Subnet label: <label>.
> Wait for ready. Return pod name + node it's scheduled on."

> **No `hostNetwork` needed.** The Calico pod network (10.233.x.x) routes to the
> VM underlay, MinIO management network, and Harbor. Verified.

> This pod is the **bootstrap host** — deploy tooling only. It carries the
> installer image, `cluster.conf`, the ~22GiB offline files, and kubespray. It is
> **deleted automatically at the end of a successful run** (Step 7): once the
> cluster is up, the pod has no ongoing role, so leaving it running just wastes a
> node's ~483MB image and the pod's resources.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cubestack-install
  namespace: default
spec:
  nodeSelector:
    kubevirt.io/subnet: <target-subnet-label>
  restartPolicy: Never
  containers:
  - name: installer
    image: harbor.isuanova.com/cubestack/cubestack-installer-cli:latest
    command: ["sleep", "infinity"]
    tty: true
EOF
```

Pin the pod to the same subnet as the target VM(s) (so it's on a node with underlay
access). Wait for ready (image is ~483MB, pull takes ~30s). Run this exact command
verbatim — the `kubectl wait` timeout **is** the whole wait:

```bash
kubectl wait --for=condition=Ready pod/cubestack-install -n default --timeout=180s
```

If it expires before Ready, report `kubectl describe pod cubestack-install -n default`
(or `get pod`) output — do not hand-write a re-poll loop.

**Return to orchestrator:** pod name, node name, confirmation that it's Ready.

## Step 3 — Verify environment from pod (subagent)

> **Subagent task:** "Verify the installer pod can reach VMs, MinIO, and Harbor.
> Check sshpass is installed (install if missing). VM IPs: <list>, MinIO: <ip:9000>,
> Harbor: <ip>:443. Also confirm password SSH (`ubuntu`) into each VM. Return
> pass/fail per target + sshpass status."

Check reachability to all targets, and confirm `sshpass` is available (kubespray
uses it for the initial password-based SSH to the VMs):

```bash
# VM SSH (check each node IP)
kubectl exec -n default cubestack-install -- bash -c \
  'timeout 3 bash -c "echo > /dev/tcp/<vm-ip>/22" && echo "SSH OK" || echo "SSH FAIL"'

# MinIO
kubectl exec -n default cubestack-install -- bash -c \
  'timeout 3 bash -c "echo > /dev/tcp/<minio-ip>/9000" && echo "MinIO OK" || echo "MinIO FAIL"'

# Harbor
kubectl exec -n default cubestack-install -- bash -c \
  'timeout 5 bash -c "echo > /dev/tcp/<harbor-ip>/443" && echo "Harbor OK" || echo "Harbor FAIL"'

# sshpass (required for kubespray's initial SSH)
kubectl exec -n default cubestack-install -- bash -c 'command -v sshpass || echo "MISSING"'
```

If `sshpass` is missing, install it:

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'apt-get update -qq && apt-get install -y -qq sshpass'
```

**Confirm password SSH into every VM** — this is the check that delegated VM
creation actually produced working password auth (catches a `***`-redacted
cloud-init `passwd` or a publickey-only VM). Run it once per VM IP:

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'sshpass -p ubuntu ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
     -o PreferredAuthentications=password -o PubkeyAuthentication=no \
     ubuntu@<vm-ip> hostname'
```

If any VM rejects password auth, do **not** SSH-debug or rebuild it here — the
subagent returns the failing VM name(s) to the orchestrator, which then has the
sibling KubeVirt skill (`suanova-dev-vm`) rebuild *just that VM* (it was created
by this run; rebuilding is safe and needs no user approval), then re-runs this
Step 3. Only if a VM still fails after a rebuild does the orchestrator stop and
report — that is a genuine blocker.

**Return to orchestrator:** per-target pass/fail, sshpass installed or not.
The orchestrator handles a target failure with the automated rebuild above — it
does not go back to the user.

## Step 4 — Create and edit `cluster.conf` (subagent, no approval)

> **Subagent task:** "Prepare cluster.conf for a CubeStack deploy. VMs: <name=ip,
> role per VM>. MinIO: <ep>/<ak>/<sk>. SSH password: <pw>. Service expose:
> <nodeport|metallb>. MetalLB pool (if metallb): <range>. Copy the example, read it,
> apply the script-based credential rewriter + NODES block + MetalLB (if needed).
> Return the config diff + the byte-verification result."

The config example is ~39KB. **Read it first** to understand the actual field names
and format — do not assume. **Never `cat` the whole example or config into your
context** — it is ~39KB, and absorbing it is the single biggest time sink in this
step (an earlier run burned ~70s just reading it). Discover the format with the
targeted grep below; if you need a field you haven't seen, grep for its name rather
than reading the file. The rewriter below is keyed on names, so it survives most
version drift without you ever seeing the full file.

```bash
kubectl exec -n default cubestack-install -- bash -c '
cd /opt/cubestack-installer
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
'
```

Inspect the key fields (this grep, nothing more):

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'grep -E "^(SSH_DEFAULT_PASSWORD|NODES|METALLB_POOL|MINIO_|REGISTRY_|SERVICE_EXPOSE)" \
   /opt/cubestack-installer/deployments/config/cluster.conf'
```

Apply changes. **Do not pause for a user diff-approval** — the resolved values
were already confirmed in Step 0. The automated byte-verification below is the
gate that replaces human review: if it passes, proceed to Step 5 without asking.

> 🚫 **Never write credentials with inline `sed`/`echo` in a tool command.**
> The tool layer redacts certain strings (e.g. the MinIO secret) to a literal
> `***` before the command reaches the pod. Result: `MINIO_SECRET_KEY="***"`
> or `SSH_DEFAULT_PASSWORD="***"` lands in `cluster.conf` — and an unquoted `***`
> is also a YAML alias token, so it breaks the kubespray inventory. This has
> corrupted `cluster.conf` repeatedly. Use the script-based rewriter below.
>
> ⚠️ **Nested heredocs in one `kubectl exec` stdin do NOT work:** an inner
> unquoted `<<EOF` delimiter consumes the same stdin, so `bash -s` receives only
> the first heredoc and `$SSH_PW` etc. are unset (`unbound variable`). Also,
> `kubectl exec` has no `--env`/`-e` flag — host env vars do not reach the pod.
> The reliable pattern is: `write` the script + a values file locally, `kubectl cp`
> both into the pod, run the script with the values file as its only argument.

Write **one** rewriter script locally (no secrets inside). It handles the credential
fields, the `NODES=` block, and the MetalLB pool in a single atomic run — do not
author a second helper script or a separate `sed` pass; every extra script/copy/exec
is a wasted ~5–15s round-trip:

```bash
cat > /tmp/cubestack-apply-conf.sh <<'SCRIPT'
#!/usr/bin/env bash
# usage: cubestack-apply-conf.sh <values-file>
# values file format (shell assignments, single line each):
#   SSH_PW=...   MINIO_EP=...   MINIO_AK=...   MINIO_SK=...
#   NODES_MASTER='master,<hostname>,<ip>,ubuntu,-'           (required)
#   NODES_WORKERS='worker,<hostname>,<ip>,ubuntu,-'          (one per worker, joined by | )
#   METALLB_POOL='<start>-<end>'                             (ONLY if SERVICE_EXPOSE_MODE=metallb)
set -euo pipefail
set -a; source "$1"; set +a   # export sourced vars so python (os.environ) sees them
cd /opt/cubestack-installer
python3 - deployments/config/cluster.conf <<'PYEOF'
import os, re, sys
p = sys.argv[1]
s = open(p).read()

def subst(key, value, block=False):
    global s
    if block:
        pat = re.compile(rf"^{key}=\(.*?^\)", flags=re.M | re.S)
        if not pat.search(s):
            raise SystemExit(f"block {key} not found - installer format changed; grep the example for {key} and adapt")
        s = pat.sub(lambda m: value.rstrip(), s, count=1)
    else:
        if not re.search(rf"^{key}=", s, flags=re.M):
            raise SystemExit(f"field {key} not found - installer format changed; grep the example for {key} and adapt")
        s = re.sub(rf"^{key}=.+$", lambda m: f'{key}="{value}"', s, flags=re.M)

vals = {
    "SSH_DEFAULT_PASSWORD": "SSH_PW",   # config key -> values-file variable
    "MINIO_ENDPOINT":       "MINIO_EP",
    "MINIO_ACCESS_KEY":     "MINIO_AK",
    "MINIO_SECRET_KEY":     "MINIO_SK",
}
for k, env in vals.items():
    subst(k, os.environ[env])

nodes = []
if os.environ.get("NODES_MASTER"):
    nodes.append(f'  "{os.environ["NODES_MASTER"]}"')
for w in os.environ.get("NODES_WORKERS", "").split("|"):
    if w:
        nodes.append(f'  "{w}"')
if not nodes:
    raise SystemExit("NODES_MASTER is empty - supply the master node line in the values file")
subst("NODES", "NODES=(\n" + "\n".join(nodes) + "\n)", block=True)

if os.environ.get("METALLB_POOL"):
    subst("METALLB_POOL", os.environ["METALLB_POOL"])

open(p, "w").write(s)
PYEOF
SCRIPT
```

Write the values file locally, then copy both into the pod and run (one `cp` of each
file + one `exec`; the script does everything):

```bash
cat > /tmp/cubestack-values.conf <<'VALS'
SSH_PW='<ssh-password>'
MINIO_EP='http://<minio-ip>:9000'
MINIO_AK='<access-key>'
MINIO_SK='<secret-key>'
NODES_MASTER='master,cubestack-k8s-master01,<master-ip>,ubuntu,-'
NODES_WORKERS='worker,cubestack-k8s-worker01,<worker1-ip>,ubuntu,-|worker,cubestack-k8s-worker02,<worker2-ip>,ubuntu,-'
# Single-node: leave NODES_WORKERS empty (or omit it); NODES_MASTER alone = the single master.
# MetalLB: add METALLB_POOL='<start>-<end>' ONLY when SERVICE_EXPOSE_MODE=metallb; in nodeport mode leave it unset.
VALS

kubectl cp /tmp/cubestack-apply-conf.sh default/cubestack-install:/tmp/cubestack-apply-conf.sh
kubectl cp /tmp/cubestack-values.conf  default/cubestack-install:/tmp/cubestack-values.conf
kubectl exec -n default cubestack-install -- bash -c '
  bash /tmp/cubestack-apply-conf.sh /tmp/cubestack-values.conf
  rm -f /tmp/cubestack-values.conf   # never leave the values file in the pod'
```

No separate NODES or MetalLB pass is needed — they are written by the same run.
Hostname format is `role,hostname,IP,ssh_user,ssh_key` (e.g.
`master,cubestack-k8s-master01,10.66.3.208,ubuntu,-`), one `NODES=` entry per VM.

**Verify the actual bytes on disk before proceeding** — this byte-verification
is the *automated approval gate* for Step 4 (a diff can look right while the pod
holds `***`):

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'grep -E "^(SSH_DEFAULT_PASSWORD|MINIO_ENDPOINT|MINIO_ACCESS_KEY|MINIO_SECRET_KEY)=" /opt/cubestack-installer/deployments/config/cluster.conf | grep -F "***" || echo "OK: no redaction artifacts"'
```

Expected: `OK: no redaction artifacts`. If any line prints, the value was
redacted — redo that field via the script above; do **not** proceed to Step 5
until the gate is green.

> ⚠️ **If fields don't match** (installer version changed the format), the
> rewriter raises `field <KEY> not found` — read the example, adapt the keys,
> and re-run.

> **Service expose mode:** The installer defaults to `SERVICE_EXPOSE_MODE=nodeport`,
> which skips MetalLB entirely. Services are exposed via `<node-ip>:<NodePort>`.
> Switch to `metallb` in `cluster.conf` only if a fixed VIP is required.

**Return to orchestrator:** the config diff + byte-verification result, recorded
in the progress log for the user's later review. No user approval is requested —
once the byte-verification gate is green the orchestrator proceeds straight to
Step 5.

## Step 5 — Fetch offline packages (subagent)

> **Subagent task:** "First make sure the pod has `deployments/config/minio.conf`
> (seed it from the example if missing — see below), then run the offline package
> fetch. Verify ~22GiB landed. Return du output + pass/fail."

> ⚠️ **Prerequisite: `minio.conf` must exist before fetching — this script does
> NOT read `cluster.conf`.** `fetch-offline-from-minio.sh` takes the MinIO
> credentials from `deployments/config/minio.conf`. A freshly created pod ships
> only `minio.conf.example`, so the fetch exits 1 on a first run **even though
> `cluster.conf` already holds the correct MinIO credentials** — the failure looks
> nothing like a credentials problem. Observed on a real run: a failed fetch plus
> recovery cost ~2.5 min.

Seed it from the example and discover the real field names (never assume them):

```bash
kubectl exec -n default cubestack-install -- bash -c '
cd /opt/cubestack-installer
cp -n deployments/config/minio.conf.example deployments/config/minio.conf
grep -vE "^[[:space:]]*(#|$)" deployments/config/minio.conf'
```

`minio.conf` holds the MinIO secret, so it is subject to the same tool-layer
redaction hazard as `cluster.conf` (Step 4): **never create or edit it with an
inline `echo`/`sed`/heredoc in a tool command** — the secret lands as a literal
`***`. Author the file locally with the **Write tool** (keeping every
non-credential key from the example — bucket, dir, etc.), then `kubectl cp` it in:

```bash
kubectl cp /tmp/minio.conf default/cubestack-install:/opt/cubestack-installer/deployments/config/minio.conf
```

Byte-verify the secret actually landed — this is the Step 5 counterpart of Step 4's
approval gate (any redaction shows up as `***` somewhere in the file):

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'grep -F "***" /opt/cubestack-installer/deployments/config/minio.conf || echo "OK: no redaction artifacts"'
```

Expected: `OK: no redaction artifacts`. If any line prints, redo the file with the
Write tool before fetching — a redacted secret fails exactly like an absent file.

Run with `--yes` (non-interactive; no TTY in `kubectl exec`):

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'cd /opt/cubestack-installer && ./deployments/scripts/tools/offline/fetch-offline-from-minio.sh --yes 2>&1'
```

This downloads ~22GiB (kubespray, ceph, metax-gpu, envoy, lws, nginx, os).
Run in background — takes 1-2 minutes at ~300 MiB/s.

Verify completion:

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'du -sh /opt/cubestack-installer/deployments/offline-files/'
# Expected: ~22GiB total
```

**Return to orchestrator:** du output, pass/fail.

## Step 6 — Deploy (subagent, long-running)

> **Subagent task:** "Run the CubeStack deploy script in the installer pod. Monitor
> the log. Return the PLAY RECAP line, the final summary line, and any errors.
> This takes 10-30+ min — poll the log, don't block."

This is the long step (10-30 min for single-node; longer for multi-node).
Runs all enabled modules from the cluster config. The full sequence is:
sshkey → passwordless → workerbm → hosts → inventory → ntp → kubespray →
metallb → local_path → registry → gpu_operator → envoy_gateway → envoy_ai_gateway
(modules not enabled in the config are skipped automatically).

**Launch detached — never run the deploy attached to a `kubectl exec` that a tool
timeout or session close can kill.** Observed failure: a deploy left attached to a
foreground `kubectl exec` hit the tool's 120s timeout, the harness backgrounded it,
and when that exec session was later reaped (~27 min in) it took deploy-cluster.sh
down with it — right after the last module, so the final banner never printed and a
banner-keyed poll couldn't see completion. `nohup` + `disown` alone are **not
enough**: they leave the process in the exec's session/process group, so the launch
exec may never return and a later reap still kills the deploy (observed again ~40
min in on cubestack4 — killed 1s after the last module). Start it with **`setsid`**
(new session, out of the exec's kill scope) + `nohup` + `disown` and stdin from
`/dev/null`, so the deploy's lifetime is owned by the container init, not the exec
session. The launch exec must **return within ~2s** — if it does not, the detach
was incomplete and the deploy will die when that exec is eventually reaped:

```bash
kubectl exec -n default cubestack-install -- bash -c \
  'cd /opt/cubestack-installer && setsid nohup ./deployments/scripts/deploy-cluster.sh > /tmp/cubestack-cluster-install.log 2>&1 < /dev/null & disown; sleep 1; pgrep -f "[d]eploy-cluster.sh" >/dev/null && echo "launched pid $(pgrep -f "[d]eploy-cluster.sh" | head -1)" || echo "LAUNCH FAILED - head the log"'
```

> ⚠️ **Stale-state trap: use `--fresh` when the inventory was prepped for a
> different node set.** The pod's inventory carries a `.deploy.state` marker; if
> the installer pod was already used for another cluster (e.g. a 3-node run) and
> you now point `cluster.conf` at different VMs (e.g. a 1-node box), the
> `k8s_deploy` module reports "已完成,跳过" (already done, skip) and **never runs
> kubespray against the new nodes** — the deploy then dies at `local_path`
> ("未找到 StorageClass local-path") because no cluster exists. Before deploying,
> check whether an `admin.conf` already exists in
> `deployments/kubespray/.../artifacts/` *and* whether the target VM actually has
> a kubeadm cluster (`sudo kubectl get nodes` / `/etc/kubernetes/admin.conf`).
> If the inventory is stale relative to the target, run
> `./deployments/scripts/deploy-cluster.sh --fresh` to clear state and re-run
> every module.

**Completion = the process has exited, NOT the banner.** The final
`✅ 一键部署流程完成` banner is a nicety: if the deploy process is killed (or its
session reaped) it may never be printed even though the cluster is fully up — which
happened once and made a banner-keyed poll run ~8 min past an already-finished
deploy. The **only** sanctioned watch for Step 6 is this verbatim poll command, run
once per ~60s cycle by the watch subagent; it prints `EXITED` the moment the deploy
process is gone, and that print is the completion signal:

```bash
# THE Step 6 poll — run verbatim, one cycle per ~60s. Stop the instant it prints EXITED.
kubectl exec -n default cubestack-install -- bash -c '
  pgrep -f "[d]eploy-cluster.sh" >/dev/null && echo "RUNNING" || echo "EXITED"
  tail -n 5 /tmp/cubestack-cluster-install.log'
```

> ℹ️ **Why `"[d]eploy-cluster.sh"` and not `deploy-cluster.sh`?** A plain `pgrep
> -f deploy-cluster.sh` also matches its **own** `bash -c` wrapper — the poll
> command line itself contains the string `deploy-cluster.sh` — so after the real
> deploy exits it keeps printing `RUNNING` forever (observed on cubestack5: ~2 min
> of over-polling past a finished deploy; the watch had to cross-check `ps`). The
> `[d]` bracket is a self-match-exclusion trick: the wrapper's command line now
> contains the literal `[d]eploy-cluster.sh`, which the regex `[d]eploy-cluster.sh`
> does **not** match, while the real process's `./deployments/scripts/deploy-cluster.sh`
> still does. Keep the bracket whenever a `pgrep -f` may run inside a command line
> that names its own target.

Do not write any other loop, banner-watch, sleep-cycle, or fixed-iteration budget
(a fixed 9×55s block once burned ~8 min polling a static log). **Stop as soon as a
cycle prints `EXITED`** (or the banner shows). On `EXITED`, treat a `PLAY RECAP`
line with `failed=0` already in the log as **success even if the banner is
missing** — do not wait for it. If it stays `RUNNING` far past the expected window,
tail more of the log and identify the active module rather than blindly continuing
to poll.

The kubespray phase prints `PLAY RECAP` with `ok=... changed=... failed=0` on success.

**Return to orchestrator:** PLAY RECAP, the final summary *if it was printed*, any
error excerpts, and confirmation of how the deploy ended (EXITED vs banner).

**Deploy failure recovery (automatic, no user approval):** the orchestrator
diagnoses from the pod log and re-runs the deploy subagent once, applying the
documented corrective action for the failure mode — typically re-running with
`--fresh` when the inventory is stale (see the stale-state trap above), or simply
re-spawning the same task to continue monitoring. Only if the deploy fails again
after the corrective re-run does the orchestrator stop and report to the user.

## Step 7 — Verify (subagent)

> **Subagent task:** "Verify the deployed CubeStack cluster. Use the admin.conf
> kubeconfig inside the installer pod. Return: node list with IPs, namespace list,
> key services (registry, envoy)."

```bash
# Nodes (expect one line per VM, all in the same subnet)
kubectl exec -n default cubestack-install -- kubectl \
  --kubeconfig=/opt/cubestack-installer/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf \
  get nodes -o wide

# Namespaces
kubectl exec -n default cubestack-install -- kubectl \
  --kubeconfig=/opt/cubestack-installer/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf \
  get ns

# Key services (registry NodePort, Envoy Gateway)
kubectl exec -n default cubestack-install -- kubectl \
  --kubeconfig=/opt/cubestack-installer/deployments/kubespray/inventory/cubestack-cluster/artifacts/admin.conf \
  get svc -A | grep -E "registry|envoy|NAME"
```

**Return to orchestrator:** node list, namespace list, service list.

**After verification succeeds, the orchestrator deletes the bootstrap installer
pod (automatic, inline — no approval).** The pod only hosted the deploy tooling;
the deployed cluster lives on the VMs. Deleting it frees the pod + ~483MB image
off the node:

```bash
kubectl delete pod cubestack-install -n default --wait=false
kubectl get pod cubestack-install -n default 2>&1   # expect: NotFound
```

> ⚠️ **Delete only after verification reports the cluster healthy.** If Step 7
> fails, keep the pod — it holds the deploy log and `admin.conf` you need to
> diagnose and recover. A later deploy never happens from this pod, so deleting a
> *healthy* run's pod loses nothing required for operations.
>
> ℹ️ **Cluster access is unaffected.** The new cluster's `admin.conf` is also
> installed on the control-plane VM (`/etc/kubernetes/admin.conf`, kubespray
> default), so you can still manage the cluster from that VM after the pod is
> gone. If the user wants local `kubectl` access to the new cluster, copy that
> file out before this step.

The orchestrator then reports the final state to the user, noting that the
bootstrap host was removed.

## Cleanup (orchestrator, inline — VMs/pool only, always user-requested)

**The installer pod is already gone by the end of a successful run** — Step 7
deletes it automatically once the cluster verifies healthy. So manual cleanup here
means only the **VMs / pool** (the deployed cluster itself): deletion destroys the
cluster and its RBD PVCs (data unrecoverable). The orchestrator never does this
automatically; it only runs when the user explicitly asks afterward, and it
confirms the exact targets before executing. VM / pool deletion is delegated to
the sibling KubeVirt skill (`suanova-dev-vm`) like creation — ask it to delete the
VM (single-node) or the pool (multi-node; removes the pool's VMs + PVCs). Commands
for reference (see `suanova-dev-vm` §delete):

```bash
# If a failed run left the installer pod behind (normally auto-deleted in Step 7)
kubectl delete pod cubestack-install -n default

# Delete the VMs / pool (also deletes their RBD PVCs — data unrecoverable)
kubectl delete vm <vm-name> -n default                 # single-node: the one VM
kubectl delete virtualmachinepool <pool> -n default    # multi-node: deletes the pool's VMs + PVCs
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Pod stuck in `ContainerCreating` | `kubectl describe pod cubestack-install -n default` — image pull or scheduling |
| `sshpass: command not found` during deploy | Install it in the pod (Step 3); kubespray needs it for initial SSH |
| `fetch-offline-from-minio.sh` exits 1 | Three causes, in order of likelihood: (1) **`deployments/config/minio.conf` missing** — a fresh pod ships only `minio.conf.example`, and the script reads `minio.conf`, *not* `cluster.conf` (create it first — Step 5); (2) missing `--yes` flag (interactive prompt without TTY); (3) MinIO unreachable |
| `fetch-offline-from-minio.sh` exits 1 with correct MinIO credentials in `cluster.conf` | Expected — the script doesn't read `cluster.conf`. Create `deployments/config/minio.conf` from the example (Step 5) |
| `cluster.conf` contains `***` | Tool-layer redaction corrupted a credential — use the script + values-file rewrite (Step 4) and re-verify bytes before deploying |
| VM `passwd` hash shows `***` in the applied VM object | Tool-layer redaction hit the cloud-init hash during delegated creation — have the sibling KubeVirt skill (`suanova-dev-vm`) rebuild the VM; never build/rebuild a VM from this skill |
| VirtualMachinePool apply rejected: `vm pool feature gate not enabled` | Alpha `VMPool` gate is off — external blocker only a cluster admin can clear; the orchestrator stops and reports so the user can enable it. Do not silently fall back to N separate VMs |
| Step 1 readiness poll never turns green though the VMs are Ready | You matched VMI by `-l owner=<user>` — pool VMIs don't inherit the owner label, so the list looks empty. Match VMI by exact name (VMI name == VM name). Never poll owner-selected VMIs (Step 1) |
| `cubestack-apply-conf.sh: unbound variable` | You fed the script via a nested heredoc in `kubectl exec` stdin — it doesn't work. Use `kubectl cp` of the script + values file (Step 4) |
| `cluster.conf` rewriter: field not found | Field names differ in this installer version — read the example (Step 4) and adapt |
| Kubespray SSH fails | VM not reachable on port 22, or wrong `SSH_DEFAULT_PASSWORD` in config |
| Kubespray fails mid-install | Check `/tmp/cubestack-cluster-install.log`; may need to re-run or recreate VM |
| Deploy dies at `local_path`: `未找到 StorageClass local-path` right after a config change | Stale inventory state — `k8s_deploy` was skipped ("已完成,跳过") because the pod was used for a different node set. Verify the target VM has no cluster, then re-run with `--fresh` (Step 6) |
| GPU operator DaemonSet not ready | No GPU card in the VM — expected; operator is deployed, no GPU resources to schedule |
| MetalLB not deployed | `SERVICE_EXPOSE_MODE=nodeport` skips MetalLB by design; switch to `metallb` if a fixed VIP is needed |
| `REGISTRY_IP` auto-detect wrong | Script detects the pod IP (10.233.x.x) not the node IP; NodePort mode handles this correctly |
| VM SSH: `Permission denied (publickey)` after provisioning | The VM didn't get password auth (key-only, empty key, or redacted `passwd`) — have the sibling KubeVirt skill (`suanova-dev-vm`) rebuild it with password-only auth (`passwd` + `ssh_pwauth: true`, no `ssh_authorized_keys`) |
| Subagent times out or hangs | Check the subagent's last `kubectl exec` output; the deploy log in the pod is the source of truth. Re-spawn with the same task to continue monitoring. |
| Deploy finished (PLAY RECAP `failed=0`, nodes Ready) but no `✅ 一键部署流程完成` banner, or Step 6's poll keeps waiting | The deploy process was killed at the very end (typically a reaped exec session) before printing its summary. The banner is cosmetic — treat the deploy as done on **process exit**: stop polling, confirm `PLAY RECAP failed=0` in the log + live nodes Ready, and proceed to Step 7. Prevent it by launching detached with `setsid` (Step 6 / hard rule 22). |

## Hard rules

1. **Read `cluster.conf.example` before editing.** Field names and format change
   across installer versions. Never assume.
2. **Collect user input only once, in Step 0.** After the single Step 0
   confirmation, run Steps 1–7 unattended: no diff-approval, no per-step check-in,
   no mid-run questions. The byte-verification gate (Step 4) and read-only
   `kubectl` verifications are automatic quality gates, not user prompts.
3. **Confirm destructive operations** (VM delete, pool delete) before executing.
   The only destructive action that may run without a fresh user prompt is the
   rebuild of a VM created by *this run* whose password auth failed at Step 3 —
   it is part of the run's automated recovery.
4. **Trust only `kubectl` output.** Never fabricate cluster state, IPs, or component status.
5. **`--yes` flag *and* a real `minio.conf` are both required for
   `fetch-offline-from-minio.sh`.** The flag satisfies the non-interactive prompt;
   the credentials come from `deployments/config/minio.conf` — **not**
   `cluster.conf` — and a fresh pod ships only `minio.conf.example`. Create
   `minio.conf` before the first fetch (Step 5), using the Write tool + `kubectl cp`
   path (it holds the MinIO secret, so inline `echo`/`sed` would write `***`).
6. **No `hostNetwork`** on the installer pod — the Calico pod network is sufficient.
7. **Subnets are dynamic** — query the cluster for node labels and NADs; never
   hardcode a specific subnet (2.x or 3.x). The target VM's subnet drives all
   network configuration.
8. **MetalLB pool is only relevant when `SERVICE_EXPOSE_MODE=metallb`.** In
   `nodeport` mode (the default), do not ask the user for a pool range.
9. **Resolve the node count first** (default `1`, single-node). It determines VM
    creation, the `NODES=` config block, and the expected `kubectl get nodes`
    result after deploy. User input wins; unstated items fall back to the Step 0
    defaults.
10. **All cluster nodes in the same subnet.** Default to placing all VMs in one
    subnet (enables live migration, simplifies LB routing). Only split subnets
    on explicit user request, with a tradeoff explanation.
11. **VM IPs are IPAM-managed** (Whereabouts). Never manually assign or reserve
    VM IPs; they are allocated from per-subnet pools at VM creation.
12. **Verify `sshpass` is installed** in the installer pod before deploying.
    Kubespray's initial SSH to the VMs requires it for password auth.
13. **Never write credentials via inline `sed`/`echo` in a tool command** (the
    tool layer redacts certain strings to `***`), and never via nested heredocs in
    `kubectl exec` stdin. Use `kubectl cp` script + values file, run it in the pod,
    `rm` the values file, and verify bytes on disk (`grep -F "***"`) before deploying.
14. **VM auth must be password-only** (cloud-init `passwd` + `ssh_pwauth: true`).
    Require it of the sibling KubeVirt skill when it provisions the VMs; never
    inject `ssh_authorized_keys` (the installer's `k8s_passwordless` module sets up
    its own key). Confirm password SSH with `sshpass` from the installer pod
    (Step 3) before deploying.
15. **Each tool-heavy phase runs in its own subagent.** The orchestrator collects
    prerequisites, spawns subagents, relays results, and reports progress. It does
    not run `kubectl exec` loops or read large files directly — but it **does** run
    the fixed single-shot lookups the skill assigns it (the Step 1 by-name Ready
    confirm, one result grep): each is a single `kubectl get`/grep, never a loop
    (see the Wait protocol).
16. **Subagents cannot prompt the user, and neither does the orchestrator after
    Step 0.** All user-facing answers are collected in Step 0 before any
    subagent spawns. On a subagent blocker the orchestrator applies that step's
    automated recovery (re-run the subagent, rebuild a run-created VM via the
    sibling skill, retry with `--fresh`) without consulting the user. It stops
    and reports only for an external blocker it cannot clear (e.g. the `VMPool`
    gate off, or a VM still failing auth after a rebuild).
17. **Pass minimum state between phases** (names, IPs, subnet, pod name, roles).
    Do not pass transcripts or raw `kubectl` output. Each subagent reads live
    cluster state.
18. **Never create or rebuild VMs from this skill.** All VM/pool provisioning —
    manifests, cloud-init `passwd` hashing, `kubectl apply`, the REDACTED-gate —
    belongs to the sibling KubeVirt skill (`suanova-dev-vm`), driven through
    Step 1. This skill only verifies the outcome (VMs Running, password SSH at
    Step 3) and reports failures back for the sibling skill to fix.
19. **Deploy state is per-pod and per-node-set.** If the installer pod's
    inventory was prepped for different VMs than the current `cluster.conf`,
    re-run with `--fresh` — a skipped `k8s_deploy` silently produces a dead
    cluster that fails at `local_path` (Step 6).
20. **Delete the bootstrap installer pod once the deploy is verified.** After
    Step 7 reports the cluster healthy, the orchestrator deletes
    `pod/cubestack-install` automatically (no approval) and confirms it is gone.
    The pod is deploy tooling only — the running cluster lives on the VMs and is
    unaffected. If Step 7 verification fails, keep the pod for diagnosis (its log
    is the source of truth) and clean it up only after recovery.
21. **Never match pool VMIs by `owner=`; never run a long readiness poll in
    Step 1.** A VirtualMachinePool puts `owner=` on its VM objects but not on the
    VMIs they create, so `kubectl get vmi -l owner=` silently misses them. VMI name
    == VM name — the orchestrator verifies by name exactly once at the join point
    (the sibling skill already waited until Ready before returning). If something is
    not Ready, hand it back to the sibling skill rather than polling from here.
22. **Launch the deploy detached and key completion on process exit, not on the
    final banner.** Run deploy-cluster.sh with `setsid nohup ... & disown` and stdin
    from `/dev/null` so it becomes a new session owned by the container init —
    `nohup`+`disown` alone leave it inside the exec's session, where a later reap
    still kills it (Step 6). The launch exec must return within ~2s; never attach
    the deploy to a long-lived `kubectl exec` that a tool timeout or session reap
    can kill. Poll with short `pgrep -f "[d]eploy-cluster.sh"`/`tail` cycles (the
    `[d]` bracket stops `pgrep` matching its own wrapper — never poll with a bare
    `pgrep -f deploy-cluster.sh`) and **stop the
    moment the process exits**; a missing `✅ 一键部署流程完成` banner is NOT a
    failure when the PLAY RECAP shows `failed=0` (the banner is the first thing lost
    if the deploy is killed at the very end). Do not loop on the banner and do not
    use long fixed poll budgets (Step 6).
23. **Nobody — subagent or orchestrator — writes a wait loop; waits use each step's
    fixed command, run verbatim.** Provisioning subagents do **zero** readiness
    checks: the sibling skill waits until the VMs are Running/Ready with IPs and
    only then returns, and the orchestrator does the single by-name Ready confirm
    at the join point (one `kubectl get`, no loop). Step 6's watch runs the verbatim
    poll command and stops on process exit. A hand-authored loop is the top cause
    of steps silently burning minutes (a pool-VMI `owner=` poll ~8 min; a `vm_ready`
    case bug stretched a ~3-min provisioning to ~13 min while the VM sat Ready; a
    banner-keyed deploy poll ran ~8 min past done).
24. **A fixed wait that times out is reported, not extended.** If `kubectl wait`
    expires or a step's verbatim poll exceeds its window, report the state and apply
    that step's documented recovery — do not loop again, widen the budget, or invent
    a new completion signal.

