#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="${repo_root}/zig-out/Ghostty.app"
target_app="/Applications/Caspy.app"

cd "${repo_root}"
zig build -Doptimize=ReleaseFast

if [[ -d "${target_app}" ]]; then
  rm -rf "${target_app}"
fi

ditto "${source_app}" "${target_app}"
echo "Installed ${target_app}"
