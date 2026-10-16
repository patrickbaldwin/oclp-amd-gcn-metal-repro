#!/bin/sh
# SPDX-License-Identifier: MIT
# Builds both repro programs and runs them on every GPU in this Mac.
# Needs Xcode or the Command Line Tools (for clang). Takes ~1-2 minutes; each failing case may pause ~5 s while the GPU
# times out. Paste the full output when you report results.
cd "$(dirname "$0")" || exit 1

clang -fobjc-arc -O0 -framework Metal -framework Foundation msaa_resolve.m -o msaa_resolve || exit 1
clang -fobjc-arc -O0 -framework Metal -framework Foundation ubo_argbuf.m -o ubo_argbuf || exit 1

echo "== system"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))   model $(sysctl -n hw.model)"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset Model|Vendor:|Device ID|Metal" | sed 's/^ *//'
echo

gpu=0
while [ "$gpu" -lt 8 ]; do
  probe=$(./msaa_resolve rgba8 resolve hw 4 "$gpu" 2>&1)
  case "$probe" in *"no GPU index"*) break ;; esac
  echo "== GPU $gpu"
  echo "$probe" | cut -c1-200
  for v in "rgba8 store hwload" "rgba8 store compute" "rgba8 store one" "rgba8 store loop" "r32f store loop" "rgba16f store loop"; do
    ./msaa_resolve $v 4 "$gpu" 2>&1 | cut -c1-200
  done
  for v in plain argbuf; do
    ./ubo_argbuf "$v" "$gpu" 2>&1 | cut -c1-200
  done
  echo
  gpu=$((gpu + 1))
done
echo "== done"
