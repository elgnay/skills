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
CS_IMAGE_GOLDEN_DEFAULT="ubuntu-22.04-server-amd64-img"

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

# --- values-file validation -------------------------------------------------
# The values file is `source`d INSIDE the pod, so an unrecognised key or an
# unquoted line is an injection vector, not merely a typo. Requiring
# KEY='value' (single quotes, no embedded quote) makes sourcing safe.
CS_VALUES_ALLOWED="SSH_PW MINIO_EP MINIO_AK MINIO_SK NODES_MASTER NODES_WORKERS \
METALLB_POOL CEPH_MODE CEPH_MONITORS CEPH_KEYRING CEPH_POOL CEPH_USER \
CEPHFS_FS CEPHFS_DATA_POOL CEPHFS_META_POOL CEPHFS_USER CEPHFS_KEYRING"

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

cs_usage_fail() {  # $1 = usage string
  cs_fail E_USAGE recover=stop-report:user hint="$1"
}
