#!/bin/bash -eux

# Simple partitioned (2 of 3) build script for building Ungoogled-Chromium macOS binaries on GitHub Actions
# Resuming build script for macOS

_target_cpu="${1:-x86_64}"

_root_dir="$(dirname "$(greadlink -f "$0")")"
_src_dir="$_root_dir/build/src"
if [[ -f "$_root_dir/epoch_job_start.txt" ]]; then
  epoch_job_start=$(cat "$_root_dir/epoch_job_start.txt")
  # GitHub's hard time limit is 6 h per job, we want to spare 1 h for steps before and after the build,
  # To get the remaining time for building we subtract 360*60s - 60*60s - (epoch_now - epoch_job_start)
  _remaining_time=$(( 360*60 - 60*60 - $(date +%s) + epoch_job_start ))
fi

# [custom] Self-heal esbuild for DevTools: older archives held a symlink into build/esbuild-node,
# which is not archived between jobs, so it dangles on a fresh runner.
_esbuild_dst="$_src_dir/third_party/devtools-frontend/src/node_modules/esbuild"
if [[ ! -f "$_esbuild_dst/package.json" ]]; then
  _esbuild_version="$(esbuild --version)"
  _esbuild_node="$_root_dir/build/esbuild-node"
  npm install --prefix "$_esbuild_node" --no-save --package-lock=false --no-bin-links --ignore-scripts --omit=optional --no-audit --no-fund "esbuild@$_esbuild_version"
  rm -rf "$_esbuild_dst"
  cp -R "$_esbuild_node/node_modules/esbuild" "$_esbuild_dst"
fi

cd "$_src_dir"

echo $(date +%s) | tee -a "$_root_dir/build_times_$_target_cpu.log"
echo "status=running" >> $GITHUB_OUTPUT

set +e

timeout -k 7m -s SIGTERM ${_remaining_time:-19680}s ninja -C out/Default chrome chromedriver # 328 m as default $_remaining_time

_error_code="${?}"
if [[ "$_error_code" -eq 124 ]]; then
    exit 0
fi

if [[ "$_error_code" -ne 0 ]]; then
    exit "$_error_code"
fi

set -e

echo $(date +%s) | tee "$_root_dir/build_finished_$_target_cpu.log"
echo "status=finished" >> $GITHUB_OUTPUT
