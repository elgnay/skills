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
    11  a required value is missing: CEPH_MODE set on the HAND-FILLED path with
        the keys absent; or SERVICE_EXPOSE_MODE selecting metallb with no
        METALLB_POOL                                    -> E_CONF_VALUES_MISSING
    12  CEPHFS_FS set without CEPHFS_DATA_POOL               -> E_CONF_VALUES_MISSING
    13  NODES_MASTER empty                                   -> E_CONF_VALUES_MISSING
    14  the in-cluster registry left with no storage backend:
        REGISTRY_ENABLED on, LOCAL_PATH_ENABLED=false and no Ceph
                                                             -> E_CONF_VALUES_MISSING
    15  UPSTREAM_DNS_SERVERS holds something that is not an IP address
                                                             -> E_CONF_VALUES_MISSING
    1   anything else                                        -> E_CONF_FIELD_MISSING

Never prints a value: only key names, and only as a "set" list.
"""

import ipaddress
import os
import re
import sys

EXIT_FIELD_MISSING = 10
EXIT_MISSING_KEYS = 11
EXIT_CEPHFS_INCOMPLETE = 12
EXIT_NO_NODES = 13
EXIT_REGISTRY_NO_STORAGE = 14
EXIT_BAD_UPSTREAM_DNS = 15


def truthy(value):
    """Installer truthiness: deploy-registry.sh accepts 1/true/yes/on."""
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def is_ip(token):
    """True for an IPv4 or IPv6 literal.

    Deliberately not socket.inet_aton, which accepts the shorthand forms
    (``1.2.3`` meaning ``1.2.0.3``) that a ``forward`` directive does not.
    """
    try:
        ipaddress.ip_address(token)
    except ValueError:
        return False
    return True


def fail(code, message):
    sys.stderr.write("FAIL: %s\n" % message)
    sys.exit(code)


def quote(value):
    """Render a value as a safe double-quoted shell assignment.

    cluster.conf is SOURCED, not parsed, and this renders into double quotes — so
    a `$`, a backtick or a `\\` in a value is a shell expansion rather than data
    unless every one of them is escaped. That is not hypothetical: the Harbor
    robot accounts this skill uses are named `robot$<project>+<name>`, and
    unescaped they render as `"robot$cubestack+installer"`, which the installer's
    `source` expands to `robot+installer` — a wrong credential in a
    docker-registry Secret, a 401 on every node's pull, and an operator that
    ImagePullBackOffs while the module that created the Secret reports success.
    A password containing `$` fails the same way, wherever it is used.
    Escaping can only turn a mangled value back into the literal the caller
    passed: nothing here is ever meant to be expanded.
    """
    return '"%s"' % (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("`", "\\`")
    )


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
        elif append or key in state["advanced"]:
            # Two ways to land here, and both mean the assignment is still LIVE
            # -- which is the only thing that makes appending honest:
            #
            #  * append=True -- the key exists ONLY inside the example's
            #    *commented* block (every CEPHFS_* field is like this; the
            #    example's live section has no CEPHFS_FS= line).
            #  * the key is declared in cluster.defaults.conf instead. The
            #    2026-10-15 config split moved it there, and check-modules.sh
            #    now ENFORCES that the two layers declare disjoint variable sets
            #    (its check 7, "配置双层无同名声明"), so a relocated key is absent
            #    from the example BY DESIGN rather than gone. load_config loads
            #    the defaults layer unconditionally, and it declares these as
            #    ${KEY:-...}, so the appended literal wins whether that layer is
            #    sourced before or after this file.
            #
            # Either way append at EOF: cluster.conf is bash-sourced top-down
            # and the last assignment wins.
            state["text"] = s.rstrip("\n") + "\n%s=%s\n" % (key, quote(value))
        else:
            # Absent from BOTH layers -- this installer does not know the key.
            # That MUST stay loud, and it is the whole reason this branch is not
            # folded into the append above: it is what catches config written for
            # a module the installer has since removed. LWS_ENABLED is the live
            # example -- the 2026-10-15 branch deleted 07_gpu_lws.sh and
            # 24_verify_lws.sh and dropped the key from both layers, so supplying
            # it now stops the run here.
            #
            # This branch is the SECOND line of defence, not the first. A key the
            # values file should not carry at all (ENVOY_GATEWAY_ENABLED /
            # ENVOY_AI_GATEWAY_ENABLED / PROMETHEUS_ENABLED, whose modules
            # dc4f3d7 removed) is refused by the values lint in scripts/lib/
            # common.sh before this file is ever spawned, so subst() is never
            # called with it and this branch never sees it. The failure it does
            # catch is the one the lint cannot: a key that is still allow-listed
            # and was therefore still live when that list was last checked, but
            # has since gone from both layers.
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

    # Read the names the SECOND config layer declares. The 2026-10-15 split put
    # cluster.defaults.conf beside this file, load_config sources it
    # unconditionally, and check-modules.sh enforces that the two layers declare
    # DISJOINT key sets -- so a key absent from the example is ambiguous on its
    # own, and this set is what resolves it into "relocated" (append) or "gone"
    # (fail loudly). Absence of the file is not an error: images from before the
    # split have no second layer, and an empty set reproduces the old behaviour
    # exactly.
    advanced = set()
    defaults_path = os.path.join(
        os.path.dirname(os.path.abspath(conf_path)), "cluster.defaults.conf"
    )
    try:
        with open(defaults_path) as fh:
            advanced = set(
                re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)=", fh.read(), flags=re.M)
            )
    except OSError:
        pass

    state = {"text": text, "advanced": advanced}
    subst = make_subst(state)
    applied = []

    def env(name):
        return os.environ.get(name, "")

    # --- credentials --------------------------------------------------------
    basic = {
        "SSH_DEFAULT_PASSWORD": env("SSH_PW"),
    }
    for key, value in basic.items():
        if not value:
            # Fail before writing anything rather than planting an empty
            # credential that only surfaces as an auth failure mid-deploy.
            fail(EXIT_MISSING_KEYS, "%s is empty" % key)
        subst(key, value)
        applied.append(key)

    # --- MinIO creds --------------------------------------------------------
    # APPENDED, not demanded, and the reason is the image, not a preference.
    # The 2026-10-15 installer build moved these three out of cluster.conf.example
    # entirely -- they now appear only in cluster.defaults.conf, as
    # `MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"` and friends. `subst()` with
    # append=False hard-fails "field MINIO_ENDPOINT not found" on such an image,
    # which is how cubestack4 died at Step 4 with E_CONF_FIELD_MISSING. The
    # CEPHFS_* keys below get the same treatment for the identical reason (they
    # survive only inside the example's commented block).
    #
    # Appending is order-safe against cluster.defaults.conf: `:-` substitutes only
    # when unset OR empty, so the literal written here survives whether defaults
    # are sourced before this file (empty -> literal) or after it (set -> kept).
    #
    # Nothing in the deploy path reads these -- the offline fetch reads
    # config/minio.conf, which `fetch-offline` seeds through cubestack-minio-conf.py.
    # They are written anyway so a run on the older image, and any tool that
    # sources cluster.conf for MinIO, keeps working unchanged.
    minio = {
        "MINIO_ENDPOINT": env("MINIO_EP"),
        "MINIO_ACCESS_KEY": env("MINIO_AK"),
        "MINIO_SECRET_KEY": env("MINIO_SK"),
    }
    for key, value in minio.items():
        if not value:
            fail(EXIT_MISSING_KEYS, "%s is empty" % key)
        subst(key, value, append=True)
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

    # --- Service expose mode (opt-in) ---------------------------------------
    #
    # MetalLB is NOT a component toggle, and this is the key thing to hold onto:
    # it is gated by the GLOBAL expose mode. cluster.conf.example documents that
    # SERVICE_EXPOSE_MODE defaults to nodePort and that nodeport mode 自动关闭
    # MetalLB - the installer force-disables it. So a cluster can carry
    # METALLB_ENABLED=true, preload the metallb images, and still come up with no
    # metallb-system namespace at all; seeing the images in PRELOAD_IMAGE_PATTERNS
    # proves nothing.
    #
    # Enabling it is a MODE FLIP whose blast radius goes well past MetalLB: the
    # in-cluster registry moves to a LoadBalancer VIP, and an empty REGISTRY_IP
    # takes the POOL'S FIRST ADDRESS. The example's own warning is a run that
    # pointed a registry at another cluster's VIP: images were pushed to one
    # cluster and pulled from another, and every node pull 404'd. Two clusters
    # sharing a subnet therefore MUST pin REGISTRY_IP - which is exactly why it
    # is carried here (it was unplumbed until 2026-09-28, leaving the pool's
    # starting address as the only lever and co-located runs to fight over it).
    # ingress-nginx and the Ceph expose mode follow the global mode too, if on.
    #
    # Guard: the installer normalises ANY value other than nodeport to metallb
    # (loadbalancer -> metallb), and with no pool supplied it silently keeps the
    # example's placeholder - 10.66.1.131-10.66.1.132. On a VM cluster whose
    # nodes sit on some other subnet that pool is off-L2: MetalLB never
    # announces, the registry VIP is unreachable, and image pulls fail
    # everywhere. Refuse it here rather than 12 minutes into a deploy.
    #
    # Deliberately NOT checked: whether the pool's subnet actually matches the
    # nodes'. That needs the real netmask, which no values key carries - a /24
    # guess would reject legitimate wider-netmask pools.
    expose_mode = env("SERVICE_EXPOSE_MODE").strip()
    if expose_mode and expose_mode.lower() != "nodeport" and not env("METALLB_POOL"):
        fail(
            EXIT_MISSING_KEYS,
            "SERVICE_EXPOSE_MODE=%s selects metallb but METALLB_POOL is empty; the "
            "example's placeholder pool (10.66.1.131-10.66.1.132) would be used, "
            "which is off-L2 for most clusters" % expose_mode,
        )
    for key in ("SERVICE_EXPOSE_MODE", "METALLB_ENABLED", "REGISTRY_IP"):
        if env(key):
            subst(key, env(key))
            applied.append(key)

    # --- nodelocaldns upstream resolvers (opt-in: only when supplied) -------
    #
    # cluster.conf ships `UPSTREAM_DNS_SERVERS="${UPSTREAM_DNS_SERVERS:-127.0.0.1}"`.
    # That variable is kubespray's `upstream_dns_servers`, and its ONE job there is
    # the external zone of nodelocaldns: tasks/main.yml:71 renders
    # `upstreamForwardTarget` as the list when non-empty and `/etc/resolv.conf`
    # when not, and nodelocaldns-config.yml.j2 puts it in `forward .`. So a pod's
    # public lookups terminate at whatever this holds — and the shipped 127.0.0.1
    # terminates them at a loopback port with nothing on it. (It is also
    # systemd-resolved's FallbackDNS, resolved.conf.j2:5.) Cluster-internal names
    # are unaffected either way, which is what makes the failure so quiet: only
    # names that leave the cluster fail.
    #
    # Substituted as a LITERAL, not left as an indirection, for the addon toggles'
    # reason: the `:-` default resolves at DEPLOY time, in a different process from
    # the one that sources the values file, so a resolver exported by `configure`
    # into this rewriter would simply be gone by then and the sentinel would win.
    #
    # "Not supplied" therefore leaves the sentinel alone — and that is the correct
    # fallback rather than a nicety, because an EMPTY upstream is the one case the
    # sentinel exists to prevent: it renders `forward . /etc/resolv.conf`, i.e.
    # nodelocaldns -> node resolv -> systemd-resolved -> nodelocaldns, and
    # coredns's `loop` plugin FATALs the ClusterDNS until it is reverted.
    #
    # IPs only: these land in a Corefile `forward` directive, so a hostname or
    # typo would produce a Corefile nodelocaldns refuses to load — a cluster-wide
    # DNS outage twelve minutes into a deploy, from a value nothing validated.
    upstream_dns = env("UPSTREAM_DNS_SERVERS").split()
    if upstream_dns:
        bad = [token for token in upstream_dns if not is_ip(token)]
        if bad:
            fail(
                EXIT_BAD_UPSTREAM_DNS,
                "UPSTREAM_DNS_SERVERS must be a space-separated list of IP "
                "addresses; got: %s" % " ".join(bad),
            )
        subst("UPSTREAM_DNS_SERVERS", " ".join(upstream_dns))
        applied.append("UPSTREAM_DNS_SERVERS")

    # --- Addon toggles (opt-in: only when named in the values file) ---------
    #
    # Each of these is a module gate - `# TOGGLE: <KEY>` in the module header,
    # and deploy-cluster.sh auto-enables every module whose toggle is true. So
    # getting one wrong is not cosmetic: a toggle left true puts a module in the
    # plan, and a module that then FAILS ABORTS THE WHOLE ADDON PHASE. Modules
    # run in numeric order, so an abort at 10_rdma_shared_dev_plugin.sh means
    # every later module never runs at all - while deploy-wait still reports OK
    # from ansible's recap, which saw no task failures. That is a silent partial
    # install.
    #
    # The example ships these as `KEY="${KEY:-true}"` - i.e. it DEFERS to the
    # ambient environment. Values-file keys are sourced by configure (which
    # spawns this rewriter), but cluster.conf is sourced LATER, by
    # deploy-cluster.sh, in a different process. Nothing guarantees the values
    # file's exports are still live there, and a `:-` default silently resolves
    # to `true` when they are not - the toggle would appear accepted and do
    # nothing. So make it a literal in cluster.conf instead of an indirection.
    #
    # append=False, deliberately - these all live in the example's LIVE section,
    # so a missing one means this file and the installer have drifted apart, and
    # that must be loud. It used to append at EOF instead, which is how three
    # long-dead keys (ENVOY_GATEWAY_ENABLED / ENVOY_AI_GATEWAY_ENABLED /
    # PROMETHEUS_ENABLED, whose modules the installer removed in dc4f3d7) kept
    # being written as inert shell variables while every verdict stayed green:
    # load_config is a plain `source`, with no unknown-key validation at all.
    # configure maps the resulting exit 10 to E_CONF_FIELD_MISSING, so the run
    # stops instead of deploying a cluster missing what was asked for.
    #
    # The CEPHFS_* keys below are the one place the EOF-append fallback is still
    # correct: those exist ONLY inside the example's commented block.
    for key in (
        "K8S_ENABLED",
        "KUBE_VIP_ENABLED",
        "LWS_ENABLED",
        "NETSHOOT_ENABLED",
        "RDMA_ENABLED",
        "GPU_OPERATOR_ENABLED",
        "MULTUS_ENABLED",
        "LOCAL_PATH_ENABLED",
        "REGISTRY_ENABLED",
    ):
        if env(key):
            subst(key, env(key))
            applied.append(key)

    # --- operator image source ----------------------------------------------
    # ONLINE_DEPLOY_CUBESTACK_OPERATOR chooses WHERE the cubeStack operator's
    # images come from — never whether an operator is installed. That is
    # CUBESTACK_OPERATOR_ENABLED, ON by default, and it is why a deploy nowadays
    # hands Step 7 a CR to adopt. `true` = each node pulls them straight from
    # Harbor, the chart's own configuration; `false` = the offline tar is pushed
    # into the in-cluster registry and the nodes pull from there.
    #
    # Written ALWAYS when the run states a mode, `false` included, for the same
    # reason REGISTRY_ENABLED above is pinned explicitly: the key is declared in
    # cluster.defaults.conf as ${ONLINE_DEPLOY_CUBESTACK_OPERATOR:-false}, so
    # writing nothing defers to whatever that default becomes, and a run that
    # asked for offline must stay offline if a later image flips it.
    #
    # NOT folded into the toggle loop above, deliberately: that loop is gated on
    # truthy(), so the off case would write nothing — exactly the deferral this
    # avoids.
    #
    # And NOT a values-file key — it is absent from CS_VALUES_ALLOWED on purpose,
    # so the lint refuses a values file that carries it. The mode has to be the
    # one env-probe checked the NODES against at Step 3, and env-probe takes no
    # values file at all; a second place to set it is a second answer.
    online_mode = env("ONLINE_DEPLOY_CUBESTACK_OPERATOR")
    if online_mode:
        subst("ONLINE_DEPLOY_CUBESTACK_OPERATOR",
              "true" if truthy(online_mode) else "false")
        applied.append("ONLINE_DEPLOY_CUBESTACK_OPERATOR")

    # --- and the credential online mode cannot run without --------------------
    # Both keys live in the example's LIVE section, so the in-place branch above
    # rewrites them — there is no relocated-key or commented-block case to work
    # around here. The mapping is the same shape as SSH_PW -> SSH_DEFAULT_PASSWORD
    # at the top of this file: the RUN's name for a credential on the left, the
    # INSTALLER's on the right.
    #
    # It is not cosmetic. The operator's own image lives in the private project
    # suanova-private, and the module that consumes these does not fail when they
    # are empty: it warns and clears the CR's imagePullSecrets, so the operator
    # ImagePullBackOffs while the module reports success. `configure` refuses an
    # online run with no credential, so an empty value here should be
    # unreachable — it is checked anyway, because the alternative is planting a
    # broken credential that only surfaces twelve minutes into a deploy.
    if truthy(online_mode):
        for key, value in (
            ("CUBESTACK_OPERATOR_HARBOR_USER", env("HARBOR_RO_USER")),
            ("CUBESTACK_OPERATOR_HARBOR_PASSWORD", env("HARBOR_RO_PW")),
        ):
            if not value:
                fail(EXIT_MISSING_KEYS, "%s is empty" % key)
            subst(key, value)
            applied.append(key)

    # --- registry storage backend -------------------------------------------
    #
    # The registry needs a StorageClass, and the backend is chosen for you:
    # local-path unless Ceph is on, in which case load_config forces ceph-block
    # and LOCAL_PATH_ENABLED=false (lib-common.sh:556-565 - Ceph and local-path
    # are mutually exclusive, and it says outright that an explicit
    # LOCAL_PATH_ENABLED is overridden by that rule).
    #
    # So the only way to leave the registry with NO backend is to turn local-path
    # off while Ceph is off. Nothing in the installer reports that: 04_local_path.sh
    # exits 0 on its own toggle and the registry module never inspects it. The
    # run stays green and fails much later as a PVC that never binds. That is a
    # config error with a deterministic outcome, so reject it here rather than
    # twelve minutes into a deploy.
    #
    # Absent REGISTRY_ENABLED means the upstream default (1, deploy it) is still
    # in force, so treat absent as ON - only an explicit false turns it off.
    if not env("CEPH_MODE"):
        registry_on = (not env("REGISTRY_ENABLED")) or truthy(env("REGISTRY_ENABLED"))
        local_path_off = bool(env("LOCAL_PATH_ENABLED")) and not truthy(
            env("LOCAL_PATH_ENABLED")
        )
        if registry_on and local_path_off:
            fail(
                EXIT_REGISTRY_NO_STORAGE,
                "REGISTRY_ENABLED on with LOCAL_PATH_ENABLED=false and no Ceph: "
                "the registry PVC would never bind (local-path is its only backend "
                "unless Ceph is enabled)",
            )

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
            # Opt-in, and only on the external path. The module defaults this to
            # FALSE as of 2026-09-28 (it was true before), which changes what a
            # green run proves: with it off the Provider is never exercised end
            # to end, so a passing deploy-wait says nothing about whether the
            # RBD/CephFS it hands us actually provision. Set it true to restore
            # the smoke test (1Gi PVC + busybox write/read; the module
            # hard-fails on provider failure). Empty = leave the default alone.
            "CEPH_EXTERNAL_PROVISION_SMOKE": env("CEPH_EXTERNAL_PROVISION_SMOKE"),
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
