#!/usr/bin/env bash
# shellcheck shell=bash
# lib/verdict.sh — the cubestack verdict contract.
#
# Every cubestack script sources this, calls `cs_init`, and terminates through
# `cs_ok` or `cs_fail`. Exactly one verdict line is emitted per invocation:
#
#   RESULT: OK   [k=v ...]
#   RESULT: FAIL <CODE> [k=v ...] recover="<verb>" [hint="<free text>"]
#
# Fixed field order: CODE, then k=v pairs, then recover=, then hint= LAST (hint
# is the only field allowed spaces). Values are [A-Za-z0-9._:@/+,-] — no
# whitespace, no quoting — except the two quoted fields. That makes the line
# trivially tokenizable and impossible to mis-parse.
#
# The line goes to BOTH stderr and <run-dir>/verdict/<script>.verdict (written
# atomically, previous attempt rotated to .prev). The file is authoritative:
# it survives a killed `kubectl exec`, interleaving with noisy kubectl output,
# and harness output caps. stderr is the convenience path so the common case
# costs the caller nothing.
#
# An EXIT trap guarantees a line even if the script dies from `set -e` or a
# signal — so a *missing* verdict is itself meaningful (E_NO_VERDICT).
#
# This file never prints a credential, a keyring, or a hash of one.

CS_SCRIPT="${CS_SCRIPT:-$(basename "${0:-cubestack}")}"
CS_VERDICT_EMITTED=0

# --- exit classes ------------------------------------------------------------
# The <CODE> token is authoritative. The exit status is a redundant hint that
# survives output truncation.
#   0 OK | 1 recoverable-by-model | 2 stop-and-report | 3 usage | 4 internal
cs_exit_class() {
  case "$1" in
    E_USAGE) echo 3 ;;
    # E_INTERRUPTED is deliberately class 1, not 4: being killed is recoverable
    # by re-attaching, and it must never be confused with a script defect.
    E_INTERNAL|E_NO_VERDICT) echo 4 ;;
    E_NO_KUBECONFIG|E_SUBNET_UNRESOLVED|E_POD_UNSCHEDULABLE|E_POD_IMAGE_PULL| \
    E_HARBOR_DNS|E_HARBOR_UNREACHABLE|E_MINIO_UNREACHABLE|E_POOL_GATE_OFF| \
    E_NAME_SPACE_EXHAUSTED|E_CONF_FIELD_MISSING|E_DEPLOY_LAUNCH| \
    E_DEPLOY_EXITED_NONZERO|E_DEPLOY_KUBESPRAY_SSH|E_VERIFY_CEPH_PROFILE| \
    E_VERIFY_CEPH_PVC_PENDING|E_RETRY_BUDGET|E_LOCK_HELD| \
    E_CEPH_ENV_MISSING|E_CEPH_ENV_INVALID| \
    E_MODELS_NO_CEPH_COMMON|E_MODELS_GUIDE_INVALID| \
    E_OPERATOR_PRECOND_VERIFY|E_OPERATOR_PRECOND_CLUSTER|E_OPERATOR_PRECOND_HELM| \
    E_OPERATOR_HARBOR_AUTH|E_OPERATOR_HARBOR_DENIED|E_OPERATOR_CHART_MISSING| \
    E_OPERATOR_CRD_MISSING|E_OPERATOR_COMPONENT_DEGRADED|E_OPERATOR_IMAGE_PULL| \
    E_VIP_NO_POOL|E_VIP_RANGE_EXHAUSTED|E_VIP_OWNER|E_VIP_CLAIMS_LOST| \
    E_VIP_OFF_SUBNET|E_VIP_NO_CRD|E_VIP_RANGE_DENIED|E_VIP_RANGE_FRAGMENTED| \
    E_VIP_RANGE_INVALID|E_VIP_RANGE_PENDING|E_VIP_COUNT_IMMUTABLE)
      echo 2 ;;
    # E_MODELS_MOUNT is deliberately NOT here: a mount that failed on a
    # reachable node is worth exactly one re-invocation, which is what the
    # class-1 default gives it.
    #
    # E_OPERATOR_HARBOR_LOGIN, E_OPERATOR_APPLY_FAILED, E_OPERATOR_NO_CR,
    # E_OPERATOR_ROLLOUT and E_OPERATOR_STILL_PROVISIONING are deliberately NOT
    # here either, for the same shape of reason: each is worth exactly one
    # re-invocation. A rejected login is not the same as an unreachable Harbor;
    # an apply that failed on a transient API error is not a deterministic one; a
    # CR that vanished is re-applied; a Deployment that would not roll is
    # overwhelmingly a slow image pull, which the re-invocation's own 5-minute
    # wait re-issues; and a bring-up that hit its budget is a wait that needs
    # re-issuing, not a run that is wrong. The class-1 default gives all five
    # that one re-invocation.
    *) echo 1 ;;
  esac
}

# --- run dir ----------------------------------------------------------------
# Operator-side state. `run.json` inside it is a CACHE, never ground truth —
# kubectl stays authoritative.
cs_run_dir() { printf '%s' "${CUBESTACK_RUN:-$HOME/.cubestack/runs/default}"; }
cs_verdict_file() { printf '%s/verdict/%s.verdict' "$(cs_run_dir)" "$CS_SCRIPT"; }
cs_log_file() { printf '%s/logs/%s.log' "$(cs_run_dir)" "$CS_SCRIPT"; }

# Create this run's directories. Called by cs_run_opt the moment a run id is
# known — deliberately NOT from cs_init, which runs before the arguments are
# parsed. Making them there would create them under whatever run dir was in
# effect at that instant, i.e. the used-by-nobody `runs/default`, leaving a
# ghost run dir sitting beside the real one.
cs_run_mkdir() { mkdir -p "$(cs_run_dir)/verdict" "$(cs_run_dir)/logs" 2>/dev/null || true; }

cs_init() {
  # When the caller pinned the run dir (CUBESTACK_RUN in the environment) it is
  # already final, so make the dirs now; otherwise cs_run_opt does it.
  [ -n "${CUBESTACK_RUN:-}" ] && cs_run_mkdir
  trap cs_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# 128+n for signal n. A trap-installed `exit 143` and a bare SIGTERM are
# indistinguishable here, and that is fine — both mean "killed from outside".
cs_signal_name() {
  case "$1" in
    129) echo HUP ;;
    130) echo INT ;;
    131) echo QUIT ;;
    137) echo KILL ;;
    143) echo TERM ;;
    *)   echo "SIG$(( $1 - 128 ))" ;;
  esac
}

cs_on_exit() {
  local rc=$? sig
  # A script may define cs_cleanup() to shred pod-side copies of secrets. It
  # runs on EVERY exit path, including cs_ok and cs_fail — so it must be cheap
  # and must tolerate its own inputs being unset.
  #
  # Do NOT install a second `trap ... EXIT` in a script: that replaces this
  # one and the verdict guarantee is silently lost.
  if declare -F cs_cleanup >/dev/null 2>&1; then
    cs_cleanup >/dev/null 2>&1 || true
  fi
  if [ "$CS_VERDICT_EMITTED" -eq 0 ]; then
    # Died before producing a verdict: set -e, a signal, or an unhandled error.
    # cs_fail sets CS_VERDICT_EMITTED first, so this cannot recurse.
    if [ "$rc" -ge 129 ] && [ "$rc" -le 165 ]; then
      # Killed from outside. This is NOT an internal error: the pod-side work
      # (a detached deploy, a fetch) is still running and is deliberately
      # orphaned. Reporting E_INTERNAL here would send the model to
      # stop-report:user and abandon a healthy run, so classify it as the
      # resume it actually is. Use cs_wait_cmd for long waits, or this code
      # will not arrive until the foreground child returns (see above).
      sig="$(cs_signal_name "$rc")"
      cs_fail E_INTERRUPTED "signal=$sig" "rc=$rc" \
        recover="rerun:$CS_SCRIPT" \
        hint="killed while waiting; any pod-side work was left running — re-invoke to re-attach"
    fi
    cs_fail E_INTERNAL "rc=$rc" recover=stop-report:user \
      hint="exited without emitting a verdict; see $(cs_log_file)"
  fi
  return "$rc"
}

# --- interruptible waits ----------------------------------------------------
# Run a long-running command as a background child and wait for it.
#
# A FOREGROUND child defers bash's EXIT trap until it returns: `sleep 300` under
# a TERM trap holds for the full 300 s (measured). For a wait whose ceiling is
# hundreds of seconds — deploy-wait blocks on a 12-40 min deploy — that means a
# killed waiter emits NO verdict for up to an hour, which is indistinguishable
# from a hang. That is the exact failure this contract exists to prevent.
#
# `wait` IS interruptible by traps (measured: trap runs in ~1 s), so a signal is
# handled immediately and the verdict still lands.
#
# Returns the child's exit status. On signal the trap exits and cs_cleanup runs;
# the child is deliberately LEFT RUNNING — pod-side work is detached on purpose
# and must survive a killed operator-side waiter.
cs_wait_cmd() {
  "$@" &
  local p=$!
  wait "$p"
}

# --- emission ---------------------------------------------------------------
cs_emit_line() {
  local line="$1" f tmp
  f="$(cs_verdict_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  if [ -f "$f" ]; then mv -f "$f" "$f.prev" 2>/dev/null || true; fi
  tmp="$f.tmp.$$"
  if printf '%s\n' "$line" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  # Leading newline guarantees column 0 even if the previous output lacked a
  # trailing newline.
  printf '\n%s\n' "$line" >&2
}

cs_ok() {
  CS_VERDICT_EMITTED=1
  local line="RESULT: OK" kv
  for kv in "$@"; do line="$line $kv"; done
  cs_emit_line "$line"
  exit 0
}

# cs_fail <CODE> [k=v ...] [recover=<verb>] [hint=<free text>]
cs_fail() {
  CS_VERDICT_EMITTED=1
  local code="$1"; shift
  local line="RESULT: FAIL $code" kv hint="" rc
  for kv in "$@"; do
    case "$kv" in
      recover=*) line="$line recover=\"${kv#recover=}\"" ;;
      hint=*)    hint="${kv#hint=}" ;;
      *)         line="$line $kv" ;;
    esac
  done
  if [ -n "$hint" ]; then
    hint="${hint//\"/\'}"
    hint="$(printf '%s' "$hint" | tr -d '\n' | cut -c1-160)"
    line="$line hint=\"$hint\""
  fi
  cs_emit_line "$line"
  rc="$(cs_exit_class "$code")"
  exit "$rc"
}

# --- re-invocation budget ---------------------------------------------------
# The guard that makes "the model may not loop" enforceable rather than
# aspirational: once a script has been invoked more times than its budget
# allows, it refuses to run and says so.
#
# The budget exists to stop a RUN-AWAY LOOP, not to block a legitimate re-run.
# That distinction matters for the read-only/idempotent scripts: budget is only
# consumed on invocation, and it is never refunded on success, so a tight limit
# on a script that is *supposed* to be re-run repeatedly would refuse to run
# partway through a perfectly healthy session.
#
#   preflight — the design is "re-run it the instant the user changes an answer"
#               (it is what replaces 're-resolve only what changed'). On a
#               default of 2, changing two answers bricks Step 0 into
#               E_RETRY_BUDGET with no way forward.
#   diagnose  — consulted repeatedly during triage, once per failure code.
#   pod-down  — idempotent ('already=1') and routinely retried after a transient
#               API error.
# None of the three mutate cluster state destructively, so a generous ceiling
# still bounds a pathological loop while never blocking real work.
cs_attempt_limit() {
  case "$1" in
    # deploy is invoked ONCE by a healthy run — but its own recover verbs point
    # back at it (rerun:deploy, rerun-fresh:deploy), and it is the step most
    # exposed to transients: image pulls, apt, a module timing out mid-run. At
    # the old default of 2, one deterministic precondition failure left a single
    # attempt for the actual deploy (see the ordering note in scripts/deploy).
    # 4 = the one the flow needs, plus the two its own recoveries prescribe.
    deploy)      echo 4 ;;
    # deploy-wait is invoked once by a healthy run, but its own false negative —
    # E_DEPLOY_NO_RECAP on a resumed run, where the log can never carry a recap
    # because kubespray legitimately did not re-run — has burned an attempt on
    # every resume. 5 covers that recurring loss plus a genuine retry.
    deploy-wait) echo 5 ;;
    preflight|diagnose|pod-down) echo 50 ;;
    # verify is invoked ONCE by a healthy run, but Step 7's operator gate
    # prescribes rerun:verify when there is no verify-ok stamp - so verify now
    # has a caller that re-invokes it, the same way deploy and env-probe do.
    # 3 = the one the flow needs plus the recovery its own caller prescribes.
    verify)      echo 3 ;;
    # env-probe is invoked TWICE by a healthy run, not once: Step 3 proves the
    # environment, then `configure` clears the env-ok stamp ("a config change can
    # invalidate the SSH password env-probe already proved") and deploy refuses to
    # launch without it, so the probe must run again. At a ceiling of 2 that
    # leaves no slack at all, and the second mandatory invocation is the run's
    # last — one transient failure anywhere turns a healthy run into
    # E_RETRY_BUDGET with a stale-but-destroyed stamp. 4 = the two the flow
    # requires, plus the rerun:env-probe its own E_SSHPASS_INSTALL recovery needs.
    env-probe)   echo 4 ;;
    # mount-models is invoked once by a healthy run, but its failure mode is a
    # flaky ssh or a transient mon timeout rather than a deterministic input
    # error — so one retry must not be the last. 3 = the one the flow needs plus
    # two, and it still bounds a loop.
    mount-models) echo 3 ;;
    # operator-up is invoked once by a healthy run, but three of its own recover
    # verbs point back at it (a transient Harbor login failure, an apply that
    # failed on the API, a CR that vanished), and it is the step most exposed to
    # a credential the user has just rotated. 3 = the one the flow needs plus
    # two, and it still bounds a loop.
    operator-up)   echo 3 ;;
    # operator-wait is invoked once by a healthy run, but its own false negative
    # is E_OPERATOR_STILL_PROVISIONING on a slow six-component bring-up, where
    # the recovery it prescribes is another operator-wait. 4 covers that
    # recurring loss plus a genuine retry.
    operator-wait) echo 4 ;;
    # reserve-vips runs ONCE in a healthy run (Step 1b, before the deploy). Since
    # the rewrite on IPRangeRequest, every read it makes — reachability, the
    # CRD/RBAC pre-checks, the owner lookup, the pool select, the request itself
    # — happens ABOVE cs_budget_guard, so the budget guards exactly one mutation:
    # the create. That is deliberate, not an oversight: a host that cannot answer
    # must not be able to exhaust a budget, and the create is the only step a
    # second invocation could plausibly get right.
    #
    # 3 = the one the flow needs, plus a rerun after an operator has cleared
    # whatever the create tripped on. The failures the create can produce are
    # all class 2, so this headroom is for the human-driven cycle, not a loop.
    reserve-vips) echo 3 ;;
    *)           echo 2 ;;
  esac
}

cs_attempt_consume() {
  local d f n lim
  d="$(cs_run_dir)/attempts"
  mkdir -p "$d" 2>/dev/null || true
  f="$d/$CS_SCRIPT"
  n=0
  [ -f "$f" ] && n="$(cat "$f" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  lim="$(cs_attempt_limit "$CS_SCRIPT")"
  [ "$n" -ge "$lim" ] && return 1
  printf '%s\n' "$((n + 1))" > "$f" 2>/dev/null || true
  return 0
}

# Call AFTER argument parsing, so a usage error never burns budget.
cs_budget_guard() {
  local lim
  lim="$(cs_attempt_limit "$CS_SCRIPT")"
  cs_attempt_consume && return 0
  cs_fail E_RETRY_BUDGET "script=$CS_SCRIPT" "limit=$lim" recover=stop-report:user \
    hint="re-invocation budget exhausted; this failure needs a human"
}

# --- redaction guard --------------------------------------------------------
# Refuse to proceed when a value carries a tool-layer redaction artifact.
# Reads the named variables indirectly; never prints their values.
# On failure CS_BAD_KEYS holds the offending key NAMES (not values).
cs_check_redaction() {
  local bad="" k v
  for k in "$@"; do
    v="${!k:-}"
    case "$v" in *'***'*) bad="$bad${bad:+,}$k" ;; esac
  done
  CS_BAD_KEYS="$bad"
  [ -z "$bad" ]
}
