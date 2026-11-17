#!/usr/bin/env bash

set -eux

# Build script for local macOS environment

# Some path variables
_root_dir="$(dirname "$(greadlink -f "$0")")"
_download_cache="$_root_dir/build/download_cache"
_src_dir="$_root_dir/build/src"
_main_repo="$_root_dir/ungoogled-chromium"

# Clone to get the Chromium Source
clone=true
_sdk_path=""
while getopts ':ds:h' OPTION; do
  case "$OPTION" in
    d)
      clone=false
      ;;
    s)
      _sdk_path=$OPTARG
      if [[ ! -d "$_sdk_path" || ! -f "$_sdk_path/SDKSettings.json" ]]; then
        echo "Invalid macOS SDK directory: $_sdk_path" >&2
        exit 1
      fi
      _sdk_path="$(greadlink -f "$_sdk_path")"
      ;;
    h)
      echo "Usage: $0 [-d] [-s SDK_PATH] [arm64|x86_64]"
      echo "  -d             Reuse downloaded source archives"
      echo "  -s SDK_PATH    Use this macOS SDK for Chromium and bindgen (default: automatic)"
      exit 0
      ;;
    *)
      echo "Usage: $0 [-d] [-s SDK_PATH] [arm64|x86_64]" >&2
      exit 1
      ;;
  esac
done

shift "$(($OPTIND -1))"

_arch=${1:-$(uname -m)}  # [custom] default to host arch (x86_64 on this Mac)

if [[ -n "$_sdk_path" ]]; then
  # build_bindgen.py asks xcrun for the SDK; SDKROOT controls that selection.
  export SDKROOT="$_sdk_path"
fi

# Add local clang and build tools to PATH
# export PATH="$PATH:$_src_dir/third_party/llvm-build/Release+Asserts/bin"

rm -rf "$_src_dir/out" || true
mkdir -p "$_download_cache"

if $clone; then
  "$_root_dir/retrieve_and_unpack_resource.py" -g $_arch
else
  "$_root_dir/retrieve_and_unpack_resource.py" -d -g $_arch
fi

mkdir -p "$_src_dir/out/Default"

# Apply patches and substitutions
python3 "$_main_repo/utils/prune_binaries.py" "$_src_dir" "$_main_repo/pruning.list"
python3 "$_main_repo/utils/patches.py" apply "$_src_dir" "$_main_repo/patches" "$_root_dir/patches"
# [custom] personal patches from ../custom/patches (series file, quilt-style)
_custom_dir="$_root_dir/custom"
if grep -qvE '^[[:space:]]*(#|$)' "$_custom_dir/patches/series" 2>/dev/null; then
  python3 "$_main_repo/utils/patches.py" apply "$_src_dir" "$_custom_dir/patches"
fi
# [custom] app icon (custom/icon/icon.svg is the source; see custom/icon/README)
if [[ -f "$_custom_dir/icon/app.icns" ]]; then
  cp "$_custom_dir/icon/app.icns" "$_custom_dir/icon/Assets.car" "$_src_dir/chrome/app/theme/chromium/mac/"
fi

# [custom] upstream patches hardcode Apple Silicon Homebrew paths for tsc/esbuild;
# point them at whatever is on PATH (Intel Homebrew or ~/.local)
if [[ ! -x /opt/homebrew/bin/tsc || ! -x /opt/homebrew/bin/esbuild ]]; then
  for _f in scripts/build/typescript/typescript_vars.gni third_party/typescript/typescript.py \
            scripts/build/ninja/bundle.gni scripts/devtools_paths.py; do
    sed -i '' -e "s|/opt/homebrew/bin/tsc|$(command -v tsc)|g" \
              -e "s|/opt/homebrew/bin/esbuild|$(command -v esbuild)|g" \
      "$_src_dir/third_party/devtools-frontend/src/$_f"
  done
  # esbuild.js assembles the path piecewise: path.join('/', 'opt', 'homebrew', 'bin', binaryName)
  perl -0pi -e "s|path\.join\(\s*'/',\s*'opt',\s*'homebrew',\s*'bin',\s*binaryName,\s*\)|'$(command -v esbuild)'|" \
    "$_src_dir/third_party/devtools-frontend/src/scripts/build/esbuild.js"
fi

python3 "$_main_repo/utils/domain_substitution.py" apply -r "$_main_repo/domain_regex.list" -f "$_main_repo/domain_substitution.list" "$_src_dir"
# Set build flags
cat "$_main_repo/flags.gn" "$_root_dir/flags.macos.gn" > "$_src_dir/out/Default/args.gn"
# [custom] personal GN args (appended last so they win)
[[ -f "$_custom_dir/flags.custom.gn" ]] && cat "$_custom_dir/flags.custom.gn" >> "$_src_dir/out/Default/args.gn"
# [custom] source tarballs (-d) ship no PGO profiles; phase 2 would fail at gn gen
$clone || echo 'chrome_pgo_phase=0' >> "$_src_dir/out/Default/args.gn"

if [[ -n "$_sdk_path" ]]; then
  # Chromium's sdk_inputs action requires its SDK path inside root_build_dir.
  mkdir -p "$_src_dir/out/Default/sdk"
  ln -s "$_sdk_path" "$_src_dir/out/Default/sdk/selected_macos_sdk"
  echo 'mac_sdk_path = "//out/Default/sdk/selected_macos_sdk"' >> "$_src_dir/out/Default/args.gn"
fi

# [custom] Intel Macs can't run Xcode 26.4+, so they build with an older SDK;
# custom/old-sdk-fixes.sh patches the few places that assume the macOS 26 SDK.
if [[ -n "$_sdk_path" ]]; then
  _sdk_major="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Version"].split(".")[0])' "$_sdk_path/SDKSettings.json")"
else
  _sdk_major="$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)"
fi
if (( _sdk_major < 26 )); then
  "$_root_dir/custom/old-sdk-fixes.sh" "$_src_dir"
fi

# Set target_cpu to the corresponding architecture
if [[ $_arch == "arm64" ]]; then
  echo 'target_cpu = "arm64"' >> "$_src_dir/out/Default/args.gn"
else
  echo 'target_cpu = "x64"' >> "$_src_dir/out/Default/args.gn"
fi

mkdir -p "$_src_dir/third_party/llvm-build/Release+Asserts"
mkdir -p "$_src_dir/third_party/rust-toolchain/bin"

"$_root_dir/retrieve_and_unpack_resource.py" -p $_arch

cd "$_src_dir"

# Fix ESBuild
_esbuild_version="$(esbuild --version)"  # [custom] works for Intel (/usr/local) Homebrew too
_esbuild_module="$_root_dir/build/esbuild-node/node_modules/esbuild"
if [[ ! -f "$_esbuild_module/package.json" ]] || \
    [[ "$(node -p 'require(process.argv[1]).version' "$_esbuild_module/package.json")" != "$_esbuild_version" ]]; then
  npm install --prefix "$_root_dir/build/esbuild-node" --no-save --package-lock=false --no-bin-links --ignore-scripts --omit=optional --no-audit --no-fund "esbuild@$_esbuild_version"
fi
rm -rf third_party/devtools-frontend/src/node_modules/esbuild
ln -s "$_esbuild_module" third_party/devtools-frontend/src/node_modules/esbuild

./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
./tools/rust/build_bindgen.py --skip-test

./out/Default/gn gen out/Default --fail-on-unused-args

ninja -C out/Default chrome chromedriver

CHROMIUM_SRC_DIR="$_src_dir" "$_root_dir/sign_and_package_app.sh"
