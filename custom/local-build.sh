#!/usr/bin/env bash
# Unattended local build on this Intel Mac. Survives closing the terminal / Claude.
#
#   custom/local-build.sh          full build: download source tarball, patch, compile, package
#   custom/local-build.sh resume   just re-run ninja + packaging in the existing tree (after a fix)
#
# Log:   build/local-build.log      Status: build/local-build.status (running|done|failed)
# Output: build/ungoogled-chromium_*_macos.dmg
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build/local-build.log"
STATUS="$ROOT/build/local-build.status"
mkdir -p "$ROOT/build"

# Daemonize once: re-exec under nohup + caffeinate so sleep/terminal close can't kill it.
if [[ -z "${_LOCAL_BUILD_CHILD:-}" ]]; then
  export _LOCAL_BUILD_CHILD=1
  nohup caffeinate -dimsu "$0" "$@" >>"$LOG" 2>&1 &
  echo "started (pid $!), log: $LOG"
  exit 0
fi

echo running >"$STATUS"
trap 'rc=$?; [[ $rc -eq 0 ]] && echo done >"$STATUS" || echo "failed ($rc)" >"$STATUS"; echo "== exit $rc at $(date)"' EXIT
echo "== local build started $(date) mode=${1:-full}"

# Python 3.13 (what CI uses; Chromium's scripts aren't tested on 3.15) ahead of everything.
# uv-managed CPython 3.13 and ~/.local node/tsc (prebuilt; Intel Homebrew compiles from source).
export PATH="$HOME/.local/share/uv/python/cpython-3.13-macos-x86_64-none/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
# No Developer ID certificate on this Mac: ad-hoc sign, skip notarization.
export MACOS_AD_HOC_SIGNING=1
# Xcode 16.4 / macOS 15.5 SDK: Chromium's non-official minimum is SDK 15.
python3 --version; xcodebuild -version | head -1; xcrun --show-sdk-version

set -e
cd "$ROOT"
if [[ "${1:-}" == "resume" ]]; then
  cd build/src
  ./out/Default/gn gen out/Default --fail-on-unused-args
  ninja -k "${NINJA_KEEP_GOING:-1}" -C out/Default chrome chromedriver
  CHROMIUM_SRC_DIR="$ROOT/build/src" "$ROOT/sign_and_package_app.sh"
else
  ./build.sh -d x86_64
fi
ls -lh "$ROOT"/build/*.dmg
