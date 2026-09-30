#!/usr/bin/env bash
# shellcheck shell=bash
# lib/common.sh — shared helpers for the cubestack scripts.
#
# Source order: verdict.sh first, then common.sh.
#
# Deliberately bash-3.2 compatible (macOS /bin/bash): no associative arrays,
# no `${var^^}`, no `mapfile`. The operator-side scripts run on whatever the
# caller's machine ships; the pod side is Ubuntu 22.04 (bash 5) but must not
# rely on that either.

CS_NS="${CS_NS:-default}"
CS_POD_PREFIX="${CS_POD_PREFIX:-cubestack-install}"
CS_IMAGE_DEFAULT="harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
CS_HARBOR_DEFAULT="harbor.isuanova.com"

# There is deliberately NO golden-image default here. VM provisioning is delegated
# to the sibling `suanova-dev-vm` skill (SKILL.md Step 1), and the golden image is
# part of that skill's VM model - the same model whose default drifts whenever the
# images change. This plugin used to carry `CS_IMAGE_GOLDEN_DEFAULT` and print a
# `golden image` line in preflight's CONFIRM block, which read as a resolved
# decision while no script ever read it back: the two skills then disagreed on the
# default (kernel 5.15.0-186 here vs 5.15.0-130 in suanova-dev-vm) and nothing
# noticed. If a caller ever needs image control, it belongs on the VM invocation,
# not in run.env. Do not reintroduce it.

cs_note() { printf '[%s] %s\n' "$CS_SCRIPT" "$*"; }

# --- run identity -----------------------------------------------------------
# A run is identified by WHAT IT INSTALLS, not by a fixed label. preflight mints
# the id from the resolved target (`cubestack<N>`) and every other script takes
# `--run <id>`, so the run dir, the retry counters AND the bootstrap pod name
# are all scoped to one target. Two installs running at the same time therefore
# cannot collide on any of them — the second no longer applies to, reuses, or
# deletes the first one's bootstrap host.
#
# Threading it explicitly is deliberate. The alternatives — one shared default
# run dir, or a `~/.cubestack/current` pointer file — let a concurrent run
# silently read the OTHER run's run.env, stamps and attempt counters, which is
# the same collision one level up. Explicit means a forgotten `--run` fails
# loudly at the first run.env lookup instead of quietly joining the wrong run.
cs_run_opt() {  # $1 = run id; called from a script's argument loop
  case "${1:-}" in
    ''|'.'|'..') cs_usage_fail "--run needs a run id (e.g. cubestack3)" ;;
    *[!A-Za-z0-9._-]*) cs_usage_fail "--run id must match [A-Za-z0-9._-] (got '$1')" ;;
  esac
  export CUBESTACK_RUN="$HOME/.cubestack/runs/$1"
  # The run dirs are created here and not in cs_init, which runs before the
  # arguments are parsed and so cannot know which run this is. Without this a
  # first call for a new run id would leave `cs_logged`'s redirect — and
  # deploy-wait/diagnose's poll files — pointed at a directory that does not
  # exist; these scripts run without `set -e`, so that fails silently.
  cs_run_mkdir
}

# This run's id. The run dir's basename is the single source of truth — there is
# no separate key that could drift from the directory it names.
#
# `default` is refused on purpose: it is what cs_run_dir() falls back to when
# nothing set CUBESTACK_RUN, i.e. no run was ever established. Answering
# "default" there would recreate the fixed name this whole mechanism exists to
# remove.
cs_run_id() {
  local id
  id="$(basename "$(cs_run_dir)")"
  case "$id" in ''|'.'|'..'|'default') return 1 ;; esac
  printf '%s' "$id"
}

# The bootstrap pod name for a run — NEVER a fixed string. Two concurrent runs
# sharing one pod name would have the second delete and recreate the first's
# bootstrap host, taking its ~22GiB offline fetch and its cluster.conf with it.
# Sanitised to RFC1123 (lowercase alphanumerics and '-') so a user-chosen --run
# id can never produce an invalid object name.
cs_pod_name() {  # $1 = run id (default: this run's)
  local id="${1:-}"
  [ -n "$id" ] || id="$(cs_run_id)" || return 1
  printf '%s-%s' "$CS_POD_PREFIX" \
    "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' \
       | tr -c 'a-z0-9-' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
}

# --- run state --------------------------------------------------------------
# run.env holds the RESOLVED Step 0 values. It is a cache, never ground truth —
# kubectl stays authoritative. It must never hold a secret.
cs_run_env_file() { printf '%s/run.env' "$(cs_run_dir)"; }

cs_run_env_get() {  # $1 = key
  local f; f="$(cs_run_env_file)"
  [ -f "$f" ] || return 1
  # shellcheck disable=SC1090
  ( . "$f" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ) 2>/dev/null
}

cs_run_env_set() {  # $@ = key=value (value shell-quoted by caller via cs_q)
  local f; f="$(cs_run_env_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}

# Same, but REPLACING any existing line for those keys. Use this for values a
# later script overwrites (POD_NAME), so a re-invocation cannot leave two
# conflicting lines in run.env — `source` would silently take the last.
cs_run_env_put() {  # $@ = key=value
  local f tmp kv k
  f="$(cs_run_env_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  tmp="$f.tmp.$$"
  cp "$f" "$tmp" 2>/dev/null || : > "$tmp"
  for kv in "$@"; do
    k="${kv%%=*}"
    grep -v "^${k}=" "$tmp" > "$tmp.next" 2>/dev/null || : > "$tmp.next"
    mv -f "$tmp.next" "$tmp"
    printf '%s\n' "$kv" >> "$tmp"
  done
  mv -f "$tmp" "$f"
}

# Single-quote a value for safe sourcing. Never use for secrets in a file that
# will be read back into a printed context.
cs_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# A short, comparable form of an image reference or digest.
#
# Accepts either shape kubectl hands back -- a full `imageID` of the form
# `repo/path@sha256:abc...`, or a bare `sha256:abc...` digest as recorded in a
# stamp -- and reduces both to `sha256:` + the first 12 hex characters. Two
# different normalizations of the same digest compare equal, which is the whole
# point: a comparison written inline once for each shape is how a "these are the
# same build" check silently answers "different". Empty in, empty out.
cs_image_short() {
  local d="${1##*@}"     # repo@sha256:...  -> sha256:...
  d="${d##*:}"           # sha256:...       -> the bare hex (a no-op on bare hex)
  [ -n "$d" ] || return 0
  printf 'sha256:%s' "$(printf '%s' "$d" | cut -c1-12)"
}

cs_stamp_path() { printf '%s/%s' "$(cs_run_dir)" "$1"; }
cs_stamp_write() { mkdir -p "$(cs_run_dir)" 2>/dev/null || true; printf '%s\n' "$2" > "$(cs_stamp_path "$1")" 2>/dev/null || true; }
cs_stamp_read()  { cat "$(cs_stamp_path "$1")" 2>/dev/null; }
cs_stamp_clear() { rm -f "$(cs_stamp_path "$1")" 2>/dev/null || true; }

# --- kubectl ----------------------------------------------------------------
# The KubeVirt cluster kubeconfig comes from the ambient KUBECONFIG (the real
# path is host-specific and deliberately kept out of this repo).
cs_kubeconfig_guard() {
  if [ -z "${KUBECONFIG:-}" ]; then
    cs_fail E_NO_KUBECONFIG recover=stop-report:admin \
      hint="export KUBECONFIG to the KubeVirt cluster kubeconfig"
  fi
  if ! kubectl version >/dev/null 2>&1 && ! kubectl get ns >/dev/null 2>&1; then
    cs_fail E_NO_KUBECONFIG "kubeconfig=$KUBECONFIG" recover=stop-report:admin \
      hint="kubeconfig present but the cluster is unreachable"
  fi
}

# Run a kubectl command, capturing all output to this script's log file.
# Nothing is forwarded to stdout: the model reads the verdict, not raw output.
#
# The mkdir is not belt-and-braces: these scripts run WITHOUT `set -e`, so a
# redirect into a missing directory fails the command silently and the script
# carries on with its output lost. The run dir can legitimately not exist yet on
# the first call for a new --run id.
cs_logged() {
  local lf; lf="$(cs_log_file)"
  mkdir -p "$(dirname "$lf")" 2>/dev/null || true
  "$@" >>"$lf" 2>&1
}

# --- pod discovery ----------------------------------------------------------
# The pod name is NEVER hardcoded and NEVER borrowed from another run.
#
# The skill used to hardcode `cubestack-install`, and discovery then matched
# `^cubestack-install(-[0-9]+)?$` and took the newest hit. Two problems, and the
# second is the one that bites:
#
#   1. A Pod never gains a `-N` suffix from `kubectl apply`, so a live
#      `cubestack-install-2` was always somebody else's pod, and a run created
#      under the bare name could never have matched it.
#   2. A pattern match is not ownership. With two runs in flight, whichever
#      created its pod last owned the name, and the other run would then exec
#      into it, `configure` would rewrite its cluster.conf, and `pod-down` would
#      delete it — taking the other run's ~22GiB fetch with it.
#
# So resolution is now scoped to THIS run: an explicit --pod, else the name this
# run recorded in run.env, else the name derived from this run's id. There is
# deliberately no fuzzy fallback — "no pod for this run" is a `rerun:pod-up`,
# not an invitation to adopt someone else's bootstrap host.
cs_pod_resolve() {  # $1 = explicit name (may be empty)
  local explicit="${1:-}" p
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  p="$(cs_run_env_get POD_NAME)"
  if [ -z "$p" ]; then
    p="$(cs_pod_name)" || return 1
  fi
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

cs_pod_ready() {  # $1 = pod
  [ "$(kubectl -n "$CS_NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

cs_pod_node() { kubectl -n "$CS_NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }

cs_pod_reason() {  # why a pod is not Ready — for the verdict hint
  kubectl -n "$CS_NS" get pod "$1" \
    -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.reason}{end}{range .status.conditions[?(@.type=="PodScheduled")]}{.reason}{end}' 2>/dev/null
}

# Resolve + require Ready, setting the global CS_POD.
#
# Sets a global rather than printing on purpose: cs_fail exits the *current*
# shell, so calling this inside `$( )` would kill only the subshell and let the
# caller continue with an empty pod name.
cs_pod_require() {  # $1 = explicit name (may be empty)
  if ! CS_POD="$(cs_pod_resolve "$1")"; then
    cs_fail E_POD_EXEC recover="rerun:pod-up" \
      hint="no bootstrap pod name for this run; pass --run <run-id> (preflight prints it as run=) or --pod <name>, then re-invoke pod-up"
  fi
  if ! cs_pod_ready "$CS_POD"; then
    cs_fail E_POD_NOT_READY "pod=$CS_POD" "reason=$(cs_pod_reason "$CS_POD")" \
      recover="rerun:pod-up" hint="pod exists but is not Ready"
  fi
  return 0
}

# kubectl exec with a hard client-side timeout. No stdin.
cs_pod_exec() {  # $1 = pod, rest = argv
  local p="$1"; shift
  kubectl -n "$CS_NS" exec "$p" -- "$@" 2>&1
}

# Same, but keeps the pod's stdout separate from kubectl's stderr.
#
# Use this for any probe whose OUTPUT is inspected, rather than its exit status.
# A question like "did this pattern match?" exits non-zero on the normal answer
# (`grep -q` finds nothing -> 1), and kubectl then writes
# `command terminated with exit code 1` to stderr. cs_pod_exec folds that into
# its output, so a caller testing `[ -n "$out" ]` reads a clean miss as a hit.
cs_pod_exec_out() {  # $1 = pod, rest = argv -> the pod's stdout only
  local p="$1"; shift
  kubectl -n "$CS_NS" exec "$p" -- "$@" 2>/dev/null
}

# --- bounded probes ---------------------------------------------------------
# Every wait in these scripts is bounded and deterministic. If a caller is
# tempted to write a loop, the right fix is to widen a budget here.

# TCP reachability from INSIDE the pod. $1 = host, $2 = port, $3 = attempts
cs_probe_tcp() {
  local host="$1" port="$2" attempts="${3:-3}" i=0
  while [ "$i" -lt "$attempts" ]; do
    if cs_pod_exec "$CS_POD" bash -c \
        "timeout 3 bash -c 'echo > /dev/tcp/${host}/${port}'" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1)); [ "$i" -lt "$attempts" ] && sleep 5
  done
  return 1
}

# Password SSH from inside the pod. $1 = ip, $2 = user, $3 = password,
# $4 = attempts. Prints the remote hostname on success.
cs_probe_ssh() {
  local ip="$1" user="$2" pw="$3" attempts="${4:-3}" i=0 out
  while [ "$i" -lt "$attempts" ]; do
    out="$(cs_pod_exec "$CS_POD" bash -c \
      "sshpass -p '$pw' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no \
         ${user}@${ip} hostname" 2>/dev/null)"
    case "$out" in
      ''|*'Permission denied'*|*'Connection refused'*|*'timed out'*|*'No route to host'*) ;;
      *) printf '%s' "$out"; return 0 ;;
    esac
    i=$((i + 1)); [ "$i" -lt "$attempts" ] && sleep 10
  done
  return 1
}

# --- misc -------------------------------------------------------------------
cs_join() {  # join remaining args with a comma; used for batching failures
  local IFS=, out="$*"
  printf '%s' "${out// /,}"
}

cs_kv_nonnumeric() { case "$1" in ''|*[!0-9]*) return 0 ;; esac; return 1; }

# Host-side sha256, used as an integrity gate on files copied INTO the pod.
# macOS ships `shasum`, Linux ships `sha256sum`; accepting whichever exists is
# what keeps this callable from either. Prints the bare hex digest, or nothing
# if neither tool is present (the caller must treat empty as "cannot verify",
# never as "matches").
cs_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# --- values-file validation -------------------------------------------------
# The values file is `source`d INSIDE the pod, so an unrecognised key or an
# unquoted line is an injection vector, not merely a typo. Requiring
# KEY='value' (single quotes, no embedded quote) makes sourcing safe.
#
# Every key here must exist in the installer's cluster.conf.example, because
# the rewriter can only substitute a key the example carries. That invariant is
# what the list is FOR, and it is worth re-checking against the installer
# source whenever the image moves: a key the installer has dropped is accepted
# here and then silently discarded (load_config is a plain `source`, with no
# unknown-key validation), so the run stays green while the toggle does nothing.
# Three such keys - ENVOY_GATEWAY_ENABLED, ENVOY_AI_GATEWAY_ENABLED and
# PROMETHEUS_ENABLED - were carried here until 2026-09-28, when the installer
# had already removed their modules entirely (commit dc4f3d7).
#
# Kept deliberately narrow: the toggles this skill's profiles and recovery paths
# actually name, not the installer's whole ~20-toggle surface.
CS_VALUES_ALLOWED="SSH_PW MINIO_EP MINIO_AK MINIO_SK NODES_MASTER NODES_WORKERS \
METALLB_POOL REGISTRY_IP SERVICE_EXPOSE_MODE METALLB_ENABLED \
LOCAL_PATH_ENABLED REGISTRY_ENABLED \
K8S_ENABLED KUBE_VIP_ENABLED LWS_ENABLED NETSHOOT_ENABLED \
RDMA_ENABLED GPU_OPERATOR_ENABLED MULTUS_ENABLED \
CEPH_MODE CEPH_EXTERNAL_PROVISION_SMOKE CEPH_MONITORS CEPH_KEYRING CEPH_POOL CEPH_USER \
CEPHFS_FS CEPHFS_DATA_POOL CEPHFS_META_POOL CEPHFS_USER CEPHFS_KEYRING \
HARBOR_RO_USER HARBOR_RO_PW"

# HARBOR_RO_USER / HARBOR_RO_PW are the ONE exception to the invariant above:
# they are THIS SKILL's keys, not the installer's. The rewriter never sees them
# and neither does cluster.conf.example - they are read by `operator-up` (Step
# 7), which sources the file inside the pod to log helm in to the Harbor OCI
# repository and to build the deployed cluster's `harbor-credentials` Secret.
# They are listed here because the lint is shared, and an unlisted key is
# refused outright. Removing them is therefore NOT the "fix" it looks like.

# LOCAL_PATH_ENABLED and REGISTRY_ENABLED are the two BASE-module storage toggles
# (local_path, k8s_registry). Both are the installer's own keys and both really
# change the cluster, so they are plumbed rather than merely accepted:
#   * LOCAL_PATH_ENABLED is OVERRIDDEN whenever Ceph is on - with either
#     CEPH_ENABLED or CEPH_CSI_ENABLED true, load_config forces it to false and
#     switches the registry backend to ceph-block (lib-common.sh:556-565,
#     which says outright that an explicit LOCAL_PATH_ENABLED is overridden).
#     So an external-Ceph run gets local-path=false whatever this says; the key
#     only bites on a run with no Ceph.
#   * REGISTRY_ENABLED is the in-cluster registry itself (upstream default 1).
#     Turning it off removes the addon, the node certs.d trust and the DNAT, and
#     makes `verify`'s registry-Service check a false failure - which is why
#     configure records what was asked for and verify reads it back.

# On success sets CS_VALUES_KEYS (space-separated key names actually present).
# Calls cs_fail on any problem, so invoke it DIRECTLY — never inside $( ).
cs_values_lint() {  # $1 = file, remaining = required keys
  local f="$1"; shift
  local line key allowed a bad="" seen="" lineno=0 mode

  [ -f "$f" ] || cs_fail E_CONF_VALUES_MISSING "values=$f" \
    recover="fix-values:$f:all" hint="values file does not exist"

  # The path is embedded in every recover= verb this lint produces, and the
  # contract forbids whitespace in a verb (it would make the line unparseable
  # with no way to quote out of it). Refusing here keeps that invariant true by
  # construction instead of relying on every caller to sanitize.
  case "$f" in *[[:space:]]*)
    cs_fail E_USAGE recover=stop-report:user \
      hint="the values path contains whitespace, which breaks the recover= token grammar; move it somewhere without spaces" ;;
  esac

  # A world-readable file holding a keyring is a leak the redaction layer
  # cannot protect. Tighten it rather than refusing: the model authored it.
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)"
  case "$mode" in 600|400) ;; *) chmod 600 "$f" 2>/dev/null || true ;; esac

  if grep -qF '***' "$f"; then
    cs_fail E_CONF_REDACTED "where=values" "file=$f" \
      recover="fix-values:$f:all" \
      hint="tool-layer redaction corrupted the values file; re-Write it, never sed/echo/heredoc"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    key="$(printf '%s' "$line" | sed -n "s/^\([A-Z_][A-Z0-9_]*\)='[^']*'$/\1/p")"
    if [ -z "$key" ]; then
      cs_fail E_CONF_VALUES_MISSING "file=$f" "line=$lineno" \
        recover="fix-values:$f:line$lineno" \
        hint="every line must be KEY='value' with single quotes and no embedded quote"
    fi
    allowed=0
    for a in $CS_VALUES_ALLOWED; do [ "$key" = "$a" ] && { allowed=1; break; }; done
    [ "$allowed" -eq 1 ] || bad="$bad${bad:+,}$key"
    seen="$seen $key"
  done < "$f"

  if [ -n "$bad" ]; then
    cs_fail E_CONF_VALUES_MISSING "file=$f" "keys=$bad" \
      recover="fix-values:$f:$bad" \
      hint="key not in the allow-list; the values file is sourced in the pod"
  fi

  for a in "$@"; do
    case " $seen " in
      *" $a "*) ;;
      *) cs_fail E_CONF_VALUES_MISSING "file=$f" "missing=$a" \
           recover="fix-values:$f:$a" hint="required key absent from the values file" ;;
    esac
  done

  CS_VALUES_KEYS="$seen"
  return 0
}

# --- external-Ceph env-file validation --------------------------------------
# The Provider exports `external-ceph.env` and the INSTALLER SOURCES IT
# (03_ceph_csi.sh:178 — `source "${_env_file}"`). That makes this file
# executable content inside the bootstrap pod, so the checks below are a
# security control, not hygiene: a line that is not an assignment runs.
#
# Format reality (measured 2026-09-11 against a real Provider export, 39 lines):
#   line 1  `ARGS="`  opens a quote that CLOSES on line 14, with the provider's
#           twelve `--namespace=...`-style arguments indented in between;
#   lines 15-39  twenty-five plain `export KEY=value` lines.
# So the shape test MUST tolerate a multi-line double-quoted value. A naive
# "every line is KEY=value" rule rejects a perfectly valid provider file — the
# exact mistake this comment exists to prevent.
#
# Value-free by construction: reports line NUMBERS and key NAMES, never content.
cs_ceph_env_lint() {  # $1 = path to a provider external-ceph.env
  local f="$1" out key missing=""

  [ -f "$f" ] || cs_fail E_CEPH_ENV_MISSING "file=$f" recover=stop-report:user \
    hint="no external-ceph.env at that path; the Provider exports one (ceph-expose-external.sh) - pass its real path"

  # The path rides in recover= and in a k=v below, and the contract forbids
  # whitespace in either. Same rationale as cs_values_lint.
  case "$f" in *[[:space:]]*)
    cs_fail E_USAGE recover=stop-report:user \
      hint="the external-ceph.env path contains whitespace, which breaks the verdict token grammar; move it somewhere without spaces" ;;
  esac

  [ -s "$f" ] || cs_fail E_CEPH_ENV_INVALID "file=$f" recover=stop-report:provider \
    hint="the external-ceph.env is empty; re-export it from the Provider"

  # A real export is ~2 KB. Anything far larger is not one, and does not get
  # read into a shell on a guess.
  if [ "$(wc -c < "$f" | tr -d ' ')" -gt 65536 ]; then
    cs_fail E_CEPH_ENV_INVALID "file=$f" recover=stop-report:provider \
      hint="far larger than a Provider export; refusing to source it - re-export and pass the real file"
  fi

  if grep -qF '***' "$f"; then
    cs_fail E_CEPH_ENV_INVALID "file=$f" recover=stop-report:provider \
      hint="contains *** redaction artifacts; re-export it from the Provider (never sed/echo/heredoc)"
  fi

  # The load-bearing control: the installer `source`s this file, so `$(...)` or
  # a backtick is arbitrary code execution in the bootstrap pod. A Provider
  # export contains neither.
  if out="$(grep -nF -e '`' -e '$(' "$f" 2>/dev/null | head -1 | cut -d: -f1)"; then
    [ -n "$out" ] && cs_fail E_CEPH_ENV_INVALID "file=$f" "line=$out" recover=stop-report:provider \
      hint="line $out contains command substitution; the installer sources this file, so it would execute as a command"
  fi

  # Shape + quote balance, one pass. A line is judged by the quote state the
  # PREVIOUS line left behind: inside an open quote it is a continuation and may
  # be anything; outside, it must be an assignment or a comment. An unbalanced
  # quote at EOF is how a truncated copy shows up — the hazard that makes a
  # half-written file silently sourceable.
  out="$(awk '
    BEGIN { inq = ""; bad = ""; esc = 0 }
    {
      if (inq == "") {
        s = $0
        if (s !~ /^[ \t]*$/ && s !~ /^[ \t]*#/ && \
            s !~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) { if (bad == "") bad = NR }
      }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (esc) { esc = 0; continue }
        if (inq == "\"") { if (c == "\\") esc = 1; else if (c == "\"") inq = "" }
        else if (inq == "'"'"'") { if (c == "'"'"'") inq = "" }
        else { if (c == "\"") inq = "\""; else if (c == "'"'"'") inq = "'"'"'" }
      }
    }
    END { if (bad != "") print "BADLINE:" bad; else if (inq != "") print "UNTERMINATED"; else print "OK" }
  ' "$f" 2>/dev/null)"

  case "$out" in
    OK) ;;
    BADLINE:*) cs_fail E_CEPH_ENV_INVALID "file=$f" "line=${out#BADLINE:}" recover=stop-report:provider \
                 hint="line ${out#BADLINE:} is not an assignment; the installer sources this file, so it would run as a command" ;;
    UNTERMINATED) cs_fail E_CEPH_ENV_INVALID "file=$f" recover=stop-report:provider \
                 hint="unbalanced quotes - the file is truncated or corrupt; re-export it from the Provider" ;;
    *) cs_fail E_CEPH_ENV_INVALID "file=$f" recover=stop-report:provider \
                 hint="could not parse the external-ceph.env as a shell-assignment file" ;;
  esac

  # The four the installer itself refuses to proceed without
  # (03_ceph_csi.sh:182-186). Names only — these are variable names, not secrets.
  for key in ROOK_EXTERNAL_FSID ROOK_EXTERNAL_CEPH_MON_DATA \
             ROOK_EXTERNAL_USERNAME ROOK_EXTERNAL_USER_SECRET; do
    grep -qE "^[ \t]*(export[ \t]+)?$key=" "$f" || missing="$missing${missing:+,}$key"
  done
  # Instruction FIRST: cs_fail cuts the hint at 160 chars, and the key list is
  # already carried in full by the `missing=` field above.
  [ -n "$missing" ] && cs_fail E_CEPH_ENV_INVALID "file=$f" "missing=$missing" recover=stop-report:provider \
    hint="re-export it from the Provider - the installer requires these and they are absent: $missing"

  return 0
}

# --- CephFS host-mount guide ------------------------------------------------
# The Provider documents its Linux-host CephFS mount in a markdown guide, and
# that guide holds the ONLY copy of the host-mount credential available to us:
# the fsid, the mon, and the CephX user and key. So `mount-models` PARSES the
# guide instead of asking for yet another secret file. Only the guide's PATH is
# recorded in the run dir; its contents never enter the repo, the skill, or the
# values file.
#
# Extraction is narrow and anchored to the guide's own config blocks, so the
# illustrative `mount -t ceph 10.66.3.46:6789:/ ...` commands the same guide
# contains cannot be mistaken for the real values:
#
#   [client.<user>]              the keyring section header
#   <ws>key = <base64>           the key, inside that section
#   fsid = <uuid>                the ceph.conf block
#   mon host = <ip>:<port>       the ceph.conf block
#
# Each field must appear EXACTLY once. A guide carrying two keys or two mons is
# not one we can pick from safely — silently taking the first would mount
# against whichever happened to sit nearer the top.
#
# Value-free by construction: reports field NAMES and counts, never content.
# The parse globals it sets ARE the secret (CS_GUIDE_KEY); a caller must never
# print them, log them, or put them in a verdict.
cs_count_lines() {  # count non-blank lines in $1
  [ -n "$1" ] || { printf '0'; return 0; }
  printf '%s\n' "$1" | grep -c '[^[:space:]]'
}

# On success sets CS_GUIDE_USER, CS_GUIDE_KEY, CS_GUIDE_FSID, CS_GUIDE_MON.
# Calls cs_fail on any problem, so invoke it DIRECTLY — never inside $( ).
cs_cephfs_guide_lint() {  # $1 = path to the CephFS host-mount guide
  local f="$1" users keys fsids mons nu nk nf nm

  [ -f "$f" ] || cs_fail E_MODELS_GUIDE_INVALID "file=$f" recover=stop-report:user \
    hint="no CephFS mount guide at that path; the Provider documents one - pass its real path"

  # The path rides in k=v fields, and the contract forbids whitespace there.
  case "$f" in *[[:space:]]*)
    cs_fail E_USAGE recover=stop-report:user \
      hint="the guide path contains whitespace, which breaks the verdict token grammar; move it somewhere without spaces" ;;
  esac

  [ -s "$f" ] || cs_fail E_MODELS_GUIDE_INVALID "file=$f" recover=stop-report:user \
    hint="the mount guide is empty"

  # A real guide is a few KB. Anything far larger is not one, and does not get
  # parsed on a guess.
  if [ "$(wc -c < "$f" | tr -d ' ')" -gt 65536 ]; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" recover=stop-report:user \
      hint="far larger than a mount guide; refusing to parse it - pass the real guide"
  fi

  # A *** artifact means the guide passed through the tool layer's redaction, so
  # the "key" in it is literally three asterisks. Mounting with that fails EACCES,
  # which is indistinguishable from a wrong key and wastes the whole debugging
  # path in the guide's troubleshooting section.
  if grep -qF '***' "$f"; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" recover=stop-report:user \
      hint="the guide carries *** redaction artifacts where the key belongs; re-fetch it unredacted"
  fi

  users="$(sed -n 's/^\[client\.\([^]]*\)\][[:space:]]*$/\1/p' "$f")"
  keys="$(sed -n 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*//p' "$f" | sed 's/[[:space:]]*$//')"
  fsids="$(sed -n 's/^[[:space:]]*fsid[[:space:]]*=[[:space:]]*//p' "$f" | sed 's/[[:space:]]*$//')"
  mons="$(sed -n 's/^[[:space:]]*mon host[[:space:]]*=[[:space:]]*//p' "$f" | sed 's/[[:space:]]*$//')"

  nu="$(cs_count_lines "$users")"
  nk="$(cs_count_lines "$keys")"
  nf="$(cs_count_lines "$fsids")"
  nm="$(cs_count_lines "$mons")"

  local missing=""
  [ "$nu" -eq 1 ] || missing="$missing${missing:+,}user($nu)"
  [ "$nk" -eq 1 ] || missing="$missing${missing:+,}key($nk)"
  [ "$nf" -eq 1 ] || missing="$missing${missing:+,}fsid($nf)"
  [ "$nm" -eq 1 ] || missing="$missing${missing:+,}mon($nm)"
  [ -z "$missing" ] || cs_fail E_MODELS_GUIDE_INVALID "file=$f" "fields=$missing" \
    recover=stop-report:user \
    hint="the guide must carry each of [client.x], key, fsid and mon host EXACTLY once; got $missing - pass the Provider's real guide"

  CS_GUIDE_USER="$users"
  CS_GUIDE_KEY="$keys"
  CS_GUIDE_FSID="$fsids"
  CS_GUIDE_MON="$mons"

  # Shape checks. A fsid that is not a UUID means the wrong line was matched; a
  # mon that is not host:port would be passed to `mount -t ceph` verbatim.
  case "$CS_GUIDE_FSID" in
    *[!0-9a-fA-F-]*) cs_fail E_MODELS_GUIDE_INVALID "file=$f" "field=fsid" recover=stop-report:user \
      hint="the fsid line is not a UUID; the guide's fsid block was not parsed as expected" ;;
  esac
  if ! printf '%s' "$CS_GUIDE_FSID" | grep -qE '^[0-9a-fA-F-]{36}$'; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" "field=fsid" recover=stop-report:user \
      hint="the fsid is not 36 characters of UUID; re-check the guide"
  fi
  if ! printf '%s' "$CS_GUIDE_MON" | grep -qE '^[0-9.]+:[0-9]+(,[0-9.]+:[0-9]+)*$'; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" "field=mon" recover=stop-report:user \
      hint="the mon host is not ip:port (or a comma-separated list); re-check the guide"
  fi
  if ! printf '%s' "$CS_GUIDE_KEY" | grep -qE '^[A-Za-z0-9+/=]+$'; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" "field=key" recover=stop-report:user \
      hint="the key is not base64-shaped; the guide's keyring block was not parsed as expected"
  fi
  # A CephX user name is passed to `mount -o name=`, so it must not be able to
  # carry whitespace or a comma into the option list.
  if ! printf '%s' "$CS_GUIDE_USER" | grep -qE '^[A-Za-z0-9._-]+$'; then
    cs_fail E_MODELS_GUIDE_INVALID "file=$f" "field=user" recover=stop-report:user \
      hint="the CephX user is not a plain client name; re-check the guide's keyring header"
  fi

  return 0
}

cs_usage_fail() {  # $1 = usage string
  cs_fail E_USAGE recover=stop-report:user hint="$1"
}

# Guard for a value-taking flag, called as `cs_need_val "$@"` from inside the
# argument loop BEFORE the arm reads "$2" and shifts.
#
# WHY IT MUST EXIST. `shift 2` on a trailing flag — `--count` with nothing after
# it — FAILS WITHOUT SHIFTING: $# is 1, so bash refuses, returns 1 (a status the
# `case` arm discards), and leaves $1 pointing at the same flag. The loop re-tests
# `[ $# -gt 0 ]`, matches the same arm, and shifts nothing again — forever: no
# output, no verdict, killed only by whatever timeout wraps the call.
#
# It is not only a typo hazard. An UNQUOTED variable that expanded to nothing
# disappears from argv entirely, so `--run $RUN` with RUN empty arrives as a bare
# `--run` and hangs. `--run "$RUN"` does not, because the empty word survives as a
# real argument and the downstream validation rejects it — which is why this is
# seen on resumed runs, where a value was expected to come from the run's own
# record and did not.
#
# Testing $# HERE is the point: "$@" hands the caller's remaining arguments to
# this function as its own, so $# is the caller's real count. A helper cannot
# shift for the caller — `shift` inside a function moves the FUNCTION's
# positional parameters, never the caller's — so this validates only, and the
# arm's own `shift 2` is then reached only when it is guaranteed to succeed.
cs_need_val() {  # $1 = the flag, as the caller saw it
  [ "$#" -ge 2 ] || cs_usage_fail "$1 requires a value"
}
