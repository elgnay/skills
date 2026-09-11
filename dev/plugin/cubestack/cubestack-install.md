---
name: cubestack-install
description: Install a single- or multi-node CubeStack cluster on KubeVirt VMs. Use when the user asks to install/deploy/bring up a cubestack cluster, provision cubestack VMs, or run the cubestack installer. The heavy lifting is done by deterministic scripts under this skill's scripts/ directory; the model resolves prerequisites, runs one script per step, and follows the recovery verb on failure.
---

# CubeStack Installation

Install a single- or multi-node CubeStack cluster on KubeVirt VMs. The installer runs
inside a K8s pod (the bootstrap host) and SSHs into the target VM(s) to run kubespray.

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
  deployed cluster lives on the VMs, not in the pod.
- **Report progress** as you go — reporting is not asking.

## Cluster facts (verify before acting)

| Item | Value |
|------|-------|
| KubeVirt cluster | v1.35.4, 3 nodes, KubeVirt v1.8.4 / CDI v1.65.0 |
| Golden images | `ubuntu-22.04/24.04/26.04-server-amd64-img` in `default` ns |
| Storage | Rook/Ceph RBD; SC `ceph-rbd-kubevirt` (RWX Block) |
| Harbor (installer img) | `harbor.isuanova.com` |
| Installer image | `harbor.isuanova.com/cubestack/cubestack-installer-cli:latest` |
| MinIO (offline pkgs) | endpoint `http://192.168.16.6:9000`, access key `admin`, secret key `Suanova@123`, bucket `cubestack-installer`, dir `offline-files` |

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
> **VM IPs are managed by Whereabouts IPAM.** Never assign or reserve one.

## Step 0 — the ONLY user interaction: resolve prerequisites

Ask **once, in a single message**, for any of these the user cares about. Silence = default.

| # | Prerequisite | Default |
|---|---|---|
| 1 | Number of nodes | `1` |
| 2 | VM shape | 8 vCPU / 24 GiB RAM / 80 GiB root |
| 3 | Subnet | auto-selected (most capacity); NAD follows |
| 4 | VM owner label | `owner=$USER` |
| 5 | SSH password | `ubuntu` |
| 6 | MinIO endpoint + keys | **built-in** — the Cluster facts row above; never ask |
| 7 | Service expose mode | `nodeport` (no MetalLB pool needed) |
| 8 | VM names | single: `cubestack<N>`; multi: pool `cubestack<N>` |
| 9 | External Ceph | off unless the user asks to import one |

Then resolve everything with one read-only call and confirm the printed plan:

```bash
"$S/preflight" --nodes 3 --minio-ep http://192.168.16.6:9000
```

Pass `--minio-ep` from the Cluster facts table **every time**. It is not optional in
practice: `preflight` records it as `MINIO_EP` in `run.env`, and Step 3's `env-probe`
reads that key. Omit it and `env-probe` fails `E_USAGE` with
`--minio-ip is required (not set on the command line or in run.env)`.

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

**External Ceph** — add these *only* when importing an external Provider, and re-run
`preflight --external-ceph` so `verify --ceph` knows to check the consumer side:

```
CEPH_MODE='external'
CEPH_MONITORS='<ip:port,ip:port,ip:port>'            # required with CEPH_MODE
CEPH_KEYRING='<base64 keyring>'                      # required with CEPH_MODE
CEPH_POOL='rbd'          CEPH_USER='admin'           # optional defaults
CEPHFS_FS='<fs name>'                                # optional; makes DATA_POOL required
CEPHFS_DATA_POOL='<pool>'                            # BOTH-OR-NEITHER with CEPHFS_FS
```

`CEPHFS_FS` is itself the external-CephFS switch; setting it without `CEPHFS_DATA_POOL`
hard-fails *mid-deploy*, so `configure` rejects that combination up front instead of
12 minutes in. RGW is internal-mode only — an external Provider's RGW is used directly and
is never configured here.

## Step 1 — Provision VMs (delegate; never create VMs here)

> **VM provisioning is delegated.** The sibling skill `suanova-dev-vm` owns all VM
> mechanics: manifests, cloud-init `passwd` hashing, `kubectl apply`, the REDACTED gate,
> and `VirtualMachinePool`. Never write VM YAML or apply VM/pool objects from this skill.

Hand `suanova-dev-vm` the resolved parameters: single-node → `VirtualMachine` named
`cubestack<N>`; multi-node → `VirtualMachinePool` named `cubestack<N>` with
`replicas=<node-count>` (its §8). Same subnet + NAD + `nodeSelector` for every VM, owner
label set, RWX/Block/`ceph-rbd-kubevirt` disks, cloud-init `passwd` + `ssh_pwauth: true`
and **no** `ssh_authorized_keys` (the installer injects its own keypair via sshpass).

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

## Step 2 — Create the installer pod

```bash
"$S/pod-up" --run <run-id>          # --subnet defaults to run.env SUBNET
```

> **Omit `--subnet` once `preflight` has run.** `run.env` already holds it, and passing the
> wrong value is costly rather than merely wrong. The value is the **label** preflight
> printed as `subnet=` (e.g. `10-66-3-0`) — *not* the NAD it printed as `nad=` on the same
> line (`vm-underlay-10-66-3-0`). A label mismatch reads as subnet drift, so `pod-up`
> deletes the healthy pod and recreates it against a `nodeSelector` that matches no node,
> discarding whatever the run had already fetched. `pod-up` now refuses a label no node
> carries — before anything is deleted, and without spending an attempt.

**The pod name is never fixed — it is `<pod-prefix>-<run-id>`, e.g.
`cubestack-install-cubestack3`.** A shared, fixed name is not merely cosmetic: with two
runs in flight the second run's `apply` targets the first run's pod, and because
`kubevirt.io/subnet` is immutable that apply path **deletes and recreates it** — throwing
away the ~22 GiB offline fetch and the `cluster.conf` the first run had already paid for.
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

> A real run **rewrites the pod's live `cluster.conf`**, replacing whatever credentials it
> holds with the ones in your values file. To inspect or smoke-test against a live pod
> without mutating it, add `--dry-run`: it validates and prints the resolved plan, then
> stops before any write.

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
`cluster.conf`) via a repo helper, byte-gates it, then fetches ~22 GiB. Idempotent: `du` on
`offline-files/` is the only evidence a prior fetch completed, so a re-run above the floor
returns `skipped=1`. A partial tree is `E_FETCH_PARTIAL`, never silently accepted.

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

`deploy` records the sorted VM-name set on first launch and auto-`--fresh` only on a
mismatch (`E_DEPLOY_STALE_STATE` / `E_DEPLOY_STATE_MISMATCH` → `rerun-fresh:deploy`). This
is the **only** place `--fresh` is ever prescribed.

## Step 7 — Verify, then clean up

```bash
"$S/verify" --run <run-id> --expect-nodes 3   # add --ceph when an external Ceph was imported
```

One call replaces ~10 independent `kubectl get`s. It refuses vacuity explicitly — zero
nodes is `E_VERIFY_NODES`, not a vacuous OK — and on success writes the `verify-ok` stamp.

```bash
"$S/pod-down" --run <run-id>           # refuses without a verify-ok stamp
```

Deletes the bootstrap pod; the deployed cluster lives on the VMs and is unaffected.

## When something fails

```bash
"$S/diagnose" --run <run-id> E_DEPLOY_KUBESPRAY_SSH   # bounded excerpt, returns a path
```

`diagnose` never dumps a log into context — it prints an excerpt and a path. Prefer it over
reading raw logs, which is what used to make a failed run expensive.

**Never delete another run's resources.** VM/pool deletion is destructive (it takes the RBD
PVCs and the data with it) and is **always** user-requested.

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
