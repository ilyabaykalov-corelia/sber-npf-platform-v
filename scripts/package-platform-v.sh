#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
ARCHIVE_PATH="${1:-${DIST_DIR}/sber-npf-platform-v.zip}"

if [[ "${ARCHIVE_PATH}" == "-h" || "${ARCHIVE_PATH}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/package-platform-v.sh [archive-path]

Builds a Platform V import archive from .info.meta.json.
Default output: dist/sber-npf-platform-v.zip
USAGE
  exit 0
fi

if [[ "${ARCHIVE_PATH}" != /* ]]; then
  ARCHIVE_PATH="${PROJECT_ROOT}/${ARCHIVE_PATH}"
fi

mkdir -p "$(dirname -- "${ARCHIVE_PATH}")"

python3 - "${PROJECT_ROOT}" "${ARCHIVE_PATH}" <<'PY'
import json
import os
import sys
import zipfile
from pathlib import Path

project_root = Path(sys.argv[1]).resolve()
archive_path = Path(sys.argv[2]).resolve()
manifest_path = project_root / ".info.meta.json"

with manifest_path.open("r", encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)

archive_entries = [".info.meta.json"]

for item in manifest.get("files", []):
    raw_path = item.get("path")
    if not isinstance(raw_path, str) or not raw_path.startswith("/"):
        raise SystemExit(f"Invalid manifest path: {raw_path!r}")

    relative_path = raw_path.lstrip("/")
    if not relative_path or relative_path.startswith("/") or ".." in Path(relative_path).parts:
        raise SystemExit(f"Unsafe manifest path: {raw_path!r}")

    archive_entries.append(relative_path)

seen = set()
resolved_entries = []

for relative_path in archive_entries:
    source_path = (project_root / relative_path).resolve()
    try:
        source_path.relative_to(project_root)
    except ValueError:
        raise SystemExit(f"Path escapes project root: {relative_path}")

    if not source_path.is_file():
        raise SystemExit(f"Required file is missing: {relative_path}")

    normalized = Path(relative_path).as_posix()
    if normalized in seen:
        continue

    seen.add(normalized)
    resolved_entries.append((source_path, normalized))

tmp_archive_path = archive_path.with_name(f".{archive_path.name}.tmp")

with zipfile.ZipFile(tmp_archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for source_path, archive_name in resolved_entries:
        archive.write(source_path, archive_name)

os.replace(tmp_archive_path, archive_path)

print(f"Created {archive_path}")
for _, archive_name in resolved_entries:
    print(f"  {archive_name}")
PY
