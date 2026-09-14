#!/usr/bin/env python3
"""Rewrite cluster.conf for a CubeStack deploy.

This was previously a heredoc the MODEL re-authored on every run, inside the
skill markdown. It now lives here as a file so it is versioned, tested, and
cannot drift between runs.

Usage:
    python3 cubestack-apply-conf.py <cluster.conf> <values-file>

The values file is sourced into the environment by the caller (see
scripts/configure) — this program reads it via os.environ, exactly as the
original inline version did.

Exit codes (mapped to failure codes by scripts/configure):
    0   success
    10  a field or block named in the config does not exist  -> E_CONF_FIELD_MISSING
    11  CEPH_MODE set, HAND-FILLED path, keys absent         -> E_CONF_VALUES_MISSING
    12  CEPHFS_FS set without CEPHFS_DATA_POOL               -> E_CONF_VALUES_MISSING
    13  NODES_MASTER empty                                   -> E_CONF_VALUES_MISSING
    1   anything else                                        -> E_CONF_FIELD_MISSING

Never prints a value: only key names, and only as a "set" list.
"""

import os
import re
import sys

EXIT_FIELD_MISSING = 10
EXIT_MISSING_KEYS = 11
EXIT_CEPHFS_INCOMPLETE = 12
EXIT_NO_NODES = 13


def fail(code, message):
    sys.stderr.write("FAIL: %s\n" % message)
    sys.exit(code)


def quote(value):
    """Render a value as a safe double-quoted shell assignment."""
    return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')


def make_subst(state):
    def subst(key, value, block=False, append=False):
        # Read the current text on every call: a value captured once here would
        # go stale after the first substitution and silently drop later edits.
        s = state["text"]
        if block:
            pat = re.compile(r"^%s=\(.*?^\)" % re.escape(key), flags=re.M | re.S)
            if not pat.search(s):
                fail(EXIT_FIELD_MISSING, "block %s not found" % key)
            state["text"] = pat.sub(lambda m: value.rstrip(), s, count=1)
        elif re.search(r"^%s=" % re.escape(key), s, flags=re.M):
            state["text"] = re.sub(
                r"^%s=.+$" % re.escape(key),
                lambda m: "%s=%s" % (key, quote(value)),
                s,
                flags=re.M,
            )
        elif append:
            # The key exists ONLY inside the example's *commented* block (every
            # CEPHFS_* field is like this -- the example's live section has no
            # CEPHFS_FS= line). Append at EOF so the assignment still wins:
            # cluster.conf is bash-sourced top-down, last assignment wins.
            state["text"] = s.rstrip("\n") + "\n%s=%s\n" % (key, quote(value))
        else:
            fail(EXIT_FIELD_MISSING, "field %s not found" % key)

    return subst


def main():
    if len(sys.argv) != 3:
        fail(1, "usage: cubestack-apply-conf.py <cluster.conf> <values-file>")
    conf_path = sys.argv[1]

    try:
        with open(conf_path) as fh:
            text = fh.read()
    except OSError as exc:
        fail(1, "cannot read %s: %s" % (conf_path, exc))

    state = {"text": text}
    subst = make_subst(state)
    applied = []

    def env(name):
        return os.environ.get(name, "")

    # --- credentials --------------------------------------------------------
    basic = {
        "SSH_DEFAULT_PASSWORD": env("SSH_PW"),
        "MINIO_ENDPOINT": env("MINIO_EP"),
        "MINIO_ACCESS_KEY": env("MINIO_AK"),
        "MINIO_SECRET_KEY": env("MINIO_SK"),
    }
    for key, value in basic.items():
        if not value:
            # Fail before writing anything rather than planting an empty
            # credential that only surfaces as an auth failure mid-deploy.
            fail(EXIT_MISSING_KEYS, "%s is empty" % key)
        subst(key, value)
        applied.append(key)

    # --- NODES --------------------------------------------------------------
    nodes = []
    if env("NODES_MASTER"):
        nodes.append('  "%s"' % env("NODES_MASTER").replace('"', '\\"'))
    for worker in env("NODES_WORKERS").split("|"):
        if worker:
            nodes.append('  "%s"' % worker.replace('"', '\\"'))
    if not nodes:
        fail(EXIT_NO_NODES, "NODES_MASTER is empty - supply the master node line")
    subst("NODES", "NODES=(\n" + "\n".join(nodes) + "\n)", block=True)
    applied.append("NODES")

    # --- MetalLB (nodeport mode leaves it untouched) ------------------------
    if env("METALLB_POOL"):
        subst("METALLB_POOL", env("METALLB_POOL"))
        applied.append("METALLB_POOL")

    # --- External Ceph CSI (opt-in: runs ONLY when CEPH_MODE is set) --------
    #
    # Installer contract (03_addon/03_ceph_csi.sh + lib-common.sh):
    #   * CEPH_CSI_ENABLED=true is the gate - the module exits 0 without it;
    #     CEPH_MODE=external lets it run with CEPH_ENABLED=false.
    #   * CEPH_MODE selects external at all. There is NO `CEPH_NODE` key in the
    #     installer; `CEPH_NODES`/`CEPH_NODE_LABEL` are unrelated (they place
    #     internal-mode OSDs). Setting CEPH_NODE would silently do nothing.
    #
    # TWO import paths, and they need DIFFERENT config. Getting this wrong is
    # not cosmetic: it is the difference between a run that works and exit 11.
    #
    #   OFFICIAL (preferred) - the Provider exports `external-ceph.env`; we
    #     place it at deployments/config/external-ceph.env and the module
    #     SOURCES it (`_ext_import_official`, line 178) to create the mon
    #     secret, mon-endpoints CM, CSI secrets, CephCluster CR and the six
    #     StorageClasses, after which Rook builds CephConnection/ClientProfile
    #     and reports STATE=Connected. configure signals this path by exporting
    #     CS_EXT_CEPH_ENV=1. It needs ONLY the three literals below plus
    #     CEPH_EXTERNAL_ENV_FILE - and deliberately NOT CEPH_MONITORS or
    #     CEPH_KEYRING. This rewriter used to demand both unconditionally, which
    #     made every correct official-path run fail here with "missing:
    #     CEPH_MONITORS, CEPH_KEYRING" while the env file already carried them.
    #
    #   HAND-FILLED (fallback) - no env file. The module then requires
    #     CEPH_MONITORS + CEPH_KEYRING and takes the rest from config. Kept
    #     working unchanged.
    #
    #   * CEPHFS_FS is ITSELF the external-CephFS switch. Setting it makes
    #     CEPHFS_DATA_POOL required; the module hard-fails MID-DEPLOY if it is
    #     empty, so reject that here instead of 12 minutes in.
    #   * RGW is internal-mode ONLY. An external Provider's RGW is used directly
    #     and is NOT configured here.
    external_env = bool(env("CS_EXT_CEPH_ENV"))

    if env("CEPH_MODE"):
        live = {  # real assignments in cluster.conf.example
            "CEPH_ENABLED": "false",   # literal: never deploy a Ceph base here
            "CEPH_CSI_ENABLED": "true",  # literal: this is the module's gate
            "CEPH_MODE": env("CEPH_MODE"),
        }
        if external_env:
            # Absolute, derived from the config path we were handed, so it does
            # not depend on the module's cwd and repo-root relocation keeps
            # working. The module also auto-detects this exact default path; set
            # it explicitly so a moved/absent file fails LOUDLY instead of
            # silently falling through to the hand-filled path, which would then
            # fail on the absent CEPH_MONITORS.
            live["CEPH_EXTERNAL_ENV_FILE"] = "%s/external-ceph.env" % os.path.dirname(
                os.path.abspath(conf_path)
            )
        else:
            live["CEPH_MONITORS"] = env("CEPH_MONITORS")
            live["CEPH_POOL"] = env("CEPH_POOL")
            live["CEPH_USER"] = env("CEPH_USER")
            live["CEPH_KEYRING"] = env("CEPH_KEYRING")

        cephfs = {  # only in the example's COMMENTED block -> append
            "CEPHFS_FS": env("CEPHFS_FS"),
            "CEPHFS_META_POOL": env("CEPHFS_META_POOL"),
            "CEPHFS_DATA_POOL": env("CEPHFS_DATA_POOL"),
            "CEPHFS_USER": env("CEPHFS_USER"),
            "CEPHFS_KEYRING": env("CEPHFS_KEYRING"),
        }
        if not external_env:
            missing = [k for k in ("CEPH_MONITORS", "CEPH_KEYRING") if not env(k)]
            if missing:
                fail(
                    EXIT_MISSING_KEYS,
                    "CEPH_MODE is set but missing: "
                    + ", ".join(missing)
                    + " (pass --external-ceph-env for the official import path, which needs neither)",
                )
        if env("CEPHFS_FS") and not env("CEPHFS_DATA_POOL"):
            fail(
                EXIT_CEPHFS_INCOMPLETE,
                "CEPHFS_FS is set but CEPHFS_DATA_POOL is empty",
            )
        for key, value in live.items():
            if value:
                subst(key, value)
                applied.append(key)
        if env("CEPHFS_FS"):  # CephFS block is all-or-nothing on CEPHFS_FS
            for key, value in cephfs.items():
                if value:
                    subst(key, value, append=True)
                    applied.append(key)

    with open(conf_path, "w") as fh:
        fh.write(state["text"])

    # Key NAMES only. Never values.
    sys.stdout.write("applied: %s\n" % " ".join(applied))
    sys.stdout.write("written: %s\n" % conf_path)
    sys.exit(0)


if __name__ == "__main__":
    main()
