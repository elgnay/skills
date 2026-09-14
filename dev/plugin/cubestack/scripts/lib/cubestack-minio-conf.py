#!/usr/bin/env python3
"""Write MinIO credentials into deployments/config/minio.conf.

Why this exists: `fetch-offline-from-minio.sh` does NOT read cluster.conf — it
reads minio.conf, and a fresh pod ships only minio.conf.example. So a first run
exits 1 with correct credentials sitting in cluster.conf, and the failure looks
nothing like a credentials problem. Observed on a real run: a failed fetch plus
recovery cost ~2.5 min.

The example is the source of every non-credential key (bucket, remote dir, and
anything a future installer adds). This program only touches the keys it is
given, substituting in place when the key already exists and appending when it
does not — so it survives the example's field names changing.

Usage:
    python3 cubestack-minio-conf.py <minio.conf> <example.conf>

Credentials arrive via the environment (MINIO_EP / MINIO_AK / MINIO_SK), which
the caller populates by sourcing the values file.
Exit codes: 0 ok, 11 a required credential was empty, 1 anything else.
Exit codes are mapped to failure codes by scripts/fetch-offline.

Never prints a value: only key names.
"""

import os
import re
import sys

EXIT_MISSING_KEYS = 11

# values-file variable -> minio.conf key. Several candidate spellings are
# accepted so an installer rename does not silently produce an unauthenticated
# fetch; the first one already present in the file wins, else the first
# candidate is appended.
CANDIDATES = [
    ("MINIO_EP", ["MINIO_ENDPOINT", "MINIO_URL", "MINIO_SERVER"]),
    ("MINIO_AK", ["MINIO_ACCESS_KEY", "MINIO_ACCESSKEY", "ACCESS_KEY"]),
    ("MINIO_SK", ["MINIO_SECRET_KEY", "MINIO_SECRETKEY", "SECRET_KEY"]),
]


def quote(value):
    return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: cubestack-minio-conf.py <minio.conf> <example.conf>\n")
        sys.exit(1)
    conf_path, example_path = sys.argv[1], sys.argv[2]

    for var, _ in CANDIDATES:
        if not os.environ.get(var):
            sys.stderr.write("FAIL: %s is empty\n" % var)
            sys.exit(EXIT_MISSING_KEYS)

    if os.path.exists(conf_path):
        with open(conf_path) as fh:
            text = fh.read()
        seeded = 0
    else:
        try:
            with open(example_path) as fh:
                text = fh.read()
        except OSError as exc:
            sys.stderr.write("FAIL: no minio.conf and cannot read the example: %s\n" % exc)
            sys.exit(1)
        seeded = 1

    applied = []
    for var, candidates in CANDIDATES:
        value = os.environ[var]
        target = None
        for cand in candidates:
            if re.search(r"^%s=" % re.escape(cand), text, flags=re.M):
                target = cand
                break
        if target is None:
            target = candidates[0]
            text = text.rstrip("\n") + "\n%s=%s\n" % (target, quote(value))
        else:
            text = re.sub(
                r"^%s=.+$" % re.escape(target),
                lambda m: "%s=%s" % (target, quote(value)),
                text,
                flags=re.M,
            )
        applied.append(target)

    with open(conf_path, "w") as fh:
        fh.write(text)

    sys.stdout.write("seeded: %d\n" % seeded)
    sys.stdout.write("applied: %s\n" % " ".join(applied))
    sys.exit(0)


if __name__ == "__main__":
    main()
