#!/bin/bash
# cephfs-mount-node.sh — install the Provider's CephFS client files on ONE node
# and mount a subdirectory of the filesystem read-only.
#
# This runs ON THE NODE, fed to `bash -s` over SSH by scripts/mount-models. It is
# deliberately a static repo file taking plain arguments rather than a script
# generated per run with the values interpolated: generating it means quoting a
# multi-line program with embedded quotes through `kubectl exec ... bash -c`,
# which is exactly the nesting that has silently mangled shell before.
#
# Arguments: <mon> <fs_path> <mountpoint> <cephx_user> <tar_path>
#
# The keyring arrives inside the tar at $5. It is never an argument, never an
# environment variable and never on a command line, so it cannot appear in the
# node's process list; the tar is deleted as soon as it has been unpacked.
#
# Prints exactly ONE sentinel line and always exits 0. The caller reads the
# sentinel and never the exit status, because ssh conflates "the remote command
# failed" with "ssh failed", and a bare non-zero would be indistinguishable from
# an unreachable node. Anything that is not MODELS_OK is a failure.
set -u

MON="$1"; FSPATH="$2"; MP="$3"; CUSER="$4"; TAR="$5"
CONF=/etc/ceph/ceph.conf
KEYRING="/etc/ceph/ceph.client.$CUSER.keyring"
SECRET="/etc/ceph/ceph.client.$CUSER.secret"
FSTAB_LINE="$MON:$FSPATH $MP ceph name=$CUSER,ro,secretfile=$SECRET,noatime,_netdev 0 0"
FSTAB_KEY="$MP ceph name=$CUSER"

fail() { echo "MODELS_FAIL $1"; exit 0; }
ok()   { echo "MODELS_OK $1"; exit 0; }

# cloud-init grants NOPASSWD; if that ever stops being true, every later step
# would fail with a confusing permission error, so say so plainly here.
sudo -n true 2>/dev/null || fail nosudo

# `already` still re-asserts the /etc/ceph files and the fstab line, so a
# re-invocation is a repair rather than a no-op.
STATE=mounted
if mountpoint -q "$MP" 2>/dev/null; then
  STATE=already
fi

if [ "$STATE" = mounted ]; then
  if ! command -v mount.ceph >/dev/null 2>&1; then
    # mount.ceph ships in ceph-common.
    #
    # The `apt-get update` is NOT optional, and leaving it out is a real failure
    # (measured on cubestack3): the nodes carry an apt package index baked in at
    # image build time, so by the time a run happens the archive has moved on and
    # the install dies with
    #   Failed to fetch .../librabbitmq4_0.10.0-1ubuntu2.1_amd64.deb  404 Not Found
    # — a stale index pointing at a superseded version, which reads like "the
    # package is unavailable" but is not. Refreshing first turns that into a
    # 23-second success.
    #
    # Both steps are bounded and non-fatal: a node with no route to the archive
    # still falls through to the admin-facing failure below rather than hanging.
    sudo -n timeout 180 env DEBIAN_FRONTEND=noninteractive \
      apt-get update -qq >/dev/null 2>&1
    INS="$(sudo -n timeout 300 env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq ceph-common 2>&1)"
    if ! command -v mount.ceph >/dev/null 2>&1; then
      # Three causes need three different sentences from the caller, and they
      # are indistinguishable from "it failed": a node whose dpkg state is
      # already broken (measured on cubestack3-1 — unpacked skopeo/sysstat and a
      # half-upgraded udev, which block EVERY apt operation, not just this one),
      # a node that cannot reach an archive at all, and everything else. apt's
      # text is the only thing that tells them apart.
      case "$INS" in
        *"Unmet dependencies"*|*"fix-broken"*) fail "nocephcommon:unmetdeps" ;;
        *"Unable to locate package"*)          fail "nocephcommon:nopackage" ;;
        *"Temporary failure"*|*"Could not resolve"*|*"Failed to fetch"*)
                                               fail "nocephcommon:noarchive" ;;
        *)                                     fail "nocephcommon:install" ;;
      esac
    fi
  fi
fi

[ -f "$TAR" ] || fail notar
T="$(mktemp -d 2>/dev/null)" || fail mktemp
tar xf "$TAR" -C "$T" 2>/dev/null || { rm -rf "$T" "$TAR"; fail untar; }
rm -f "$TAR"

for f in ceph.conf "ceph.client.$CUSER.keyring" "ceph.client.$CUSER.secret"; do
  [ -s "$T/$f" ] || { rm -rf "$T"; fail missingfile; }
done

# install(1) with a mode, rather than `cp` + `chmod`: the file is never briefly
# world-readable between the two steps.
sudo -n install -d -m 755 /etc/ceph "$MP" 2>/dev/null || { rm -rf "$T"; fail mkdir; }
{ sudo -n install -m 600 "$T/ceph.conf" "$CONF" 2>/dev/null &&
  sudo -n install -m 600 "$T/ceph.client.$CUSER.keyring" "$KEYRING" 2>/dev/null &&
  sudo -n install -m 600 "$T/ceph.client.$CUSER.secret" "$SECRET" 2>/dev/null; } \
  || { rm -rf "$T"; fail install; }
rm -rf "$T"

if [ "$STATE" = mounted ]; then
  ERR="$(sudo -n mount -t ceph "$MON:$FSPATH" "$MP" \
           -o "name=$CUSER,ro,secretfile=$SECRET" 2>&1)"
  if [ $? -ne 0 ]; then
    # The kernel/client error text is the whole diagnosis here (errno 13 vs 2 vs
    # a timeout), so it is carried out — sanitised to the verdict charset.
    fail "mount:$(printf '%s' "$ERR" | tr -d '\n' \
      | tr -c 'A-Za-z0-9._:@/+,-' '_' | cut -c1-80)"
  fi
fi

# _netdev makes the mount wait for the network instead of hanging the boot when
# the Provider's mon is unreachable; noatime avoids a write on every read of a
# read-only store.
if ! grep -qF "$FSTAB_KEY" /etc/fstab 2>/dev/null; then
  printf '%s\n' "$FSTAB_LINE" | sudo -n tee -a /etc/fstab >/dev/null 2>&1 || fail fstab
fi

mountpoint -q "$MP" 2>/dev/null || fail notmounted
ls "$MP" >/dev/null 2>&1 || fail unreadable

# The read-only proof, and the reason this script is worth having as code: it is
# the one assertion that distinguishes "mounted ro" from "mounted". A write that
# SUCCEEDS means the mount is not read-only, which is a failure even though every
# earlier step passed.
if touch "$MP/.cs-write-test" 2>/dev/null; then
  rm -f "$MP/.cs-write-test" 2>/dev/null
  fail writable
fi

ok "$STATE"
