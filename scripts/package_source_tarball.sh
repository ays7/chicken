#!/bin/bash
#
# scripts/package_source_tarball.sh
# Packages a reproducible source tarball including all recursive git submodules.
#

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <version> [output_dir]" >&2
  exit 1
fi

RAW_VERSION="$1"
CLEAN_VERSION="${RAW_VERSION#v}"
OUTPUT_DIR="${2:-dist}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [ -f .gitmodules ] && git submodule status --recursive | grep -q '^-'; then
  echo "Error: One or more git submodules are not initialized. Run 'git submodule update --init --recursive'." >&2
  exit 1
fi

PREFIX="chicken-${CLEAN_VERSION}"
TARBALL_NAME="Chicken-Fork-${CLEAN_VERSION}-src.tar.gz"
mkdir -p "$OUTPUT_DIR"
TARBALL_PATH="${OUTPUT_DIR%/}/${TARBALL_NAME}"

STAGING_BASE=$(mktemp -d "${TMPDIR:-/tmp}/chicken-src-XXXXXX")
cleanup() {
  rm -rf "$STAGING_BASE"
}
trap cleanup EXIT INT TERM

STAGING_DIR="${STAGING_BASE}/${PREFIX}"
mkdir -p "$STAGING_DIR"

# Export superproject tracked files
git archive HEAD | tar -x -C "$STAGING_DIR"

# Export each submodule's tracked files at its pinned commit
if [ -f .gitmodules ]; then
  export STAGING_DIR
  git submodule foreach --recursive --quiet '
    dest="$STAGING_DIR/$displaypath"
    mkdir -p "$dest"
    git archive HEAD | tar -x -C "$dest"
  '
fi

COMMIT_EPOCH=$(git log -1 --format=%ct HEAD)

# Build a deterministic tar.gz (sorted entries, fixed mtime, normalized ownership)
python3 - "$STAGING_BASE" "$PREFIX" "$TARBALL_PATH" "$COMMIT_EPOCH" <<'PY'
import gzip
import os
import stat
import sys
import tarfile

staging_base, prefix, tarball_path, commit_epoch = sys.argv[1:5]
mtime = int(commit_epoch)
root_dir = os.path.join(staging_base, prefix)

def normalize(ti: tarfile.TarInfo) -> tarfile.TarInfo:
    ti.uid = 0
    ti.gid = 0
    ti.uname = ""
    ti.gname = ""
    ti.mtime = mtime
    return ti

def add_tree(tf: tarfile.TarFile, fs_path: str, arc_path: str) -> None:
    st = os.lstat(fs_path)
    ti = tf.gettarinfo(fs_path, arcname=arc_path)
    normalize(ti)
    if stat.S_ISLNK(st.st_mode):
        tf.addfile(ti)
        return
    if stat.S_ISDIR(st.st_mode):
        tf.addfile(ti)
        entries = sorted(os.scandir(fs_path), key=lambda e: e.name)
        for entry in entries:
            add_tree(tf, entry.path, f"{arc_path}/{entry.name}")
        return
    with open(fs_path, "rb") as f:
        tf.addfile(ti, f)

with gzip.GzipFile(filename=tarball_path, mode="wb", mtime=0) as gz:
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tf:
        add_tree(tf, root_dir, prefix)
PY

ls -lh "$TARBALL_PATH"
/usr/bin/shasum -a 256 "$TARBALL_PATH"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "src_tarball=$TARBALL_PATH" >> "$GITHUB_OUTPUT"
fi
