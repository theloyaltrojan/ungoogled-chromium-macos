#!/usr/bin/env bash
# Source fixes for building with a macOS SDK older than 26 (Intel Macs can't run
# Xcode 26.4+, which ships the 26.x SDK Chromium is tested with). Idempotent.
#
#   custom/old-sdk-fixes.sh <chromium src dir>
#
# Each fix only hides macOS 26 SDK symbols at compile time; runtime behaviour on
# macOS 26 is unchanged where Chromium already had a fallback.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$1"
cd "$src"

# Clang modules: the target lists DarwinFoundation*.modulemap (26 SDK only) as inputs.
grep -q '^use_clang_modules = false' out/Default/args.gn 2>/dev/null || echo 'use_clang_modules = false' >> out/Default/args.gn
sed -i '' 's|^        inputs += \[ path \]$|        # [custom] old SDK: no DarwinFoundation modulemaps|' build/modules/BUILD.gn

# nasm: <sys/endian.h> and its htole* functions first shipped in the 26 SDK.
grep -q '__has_include(<sys/endian.h>)' third_party/nasm/config/config-mac.h ||
perl -0pi -e 's|^#define (HAVE_SYS_ENDIAN_H\|HAVE_HTOLE(?:16\|32\|64)) 1$|#if __has_include(<sys/endian.h>)\n#define $1 1\n#endif|mg' \
  third_party/nasm/config/config-mac.h

# base: posix_spawn_file_actions_addchdir (non-_np) is declared only in the 26 SDK.
grep -q 'VERSION_MAX_ALLOWED >= 260000' base/process/launch_mac.cc ||
perl -0pi -e 's|(\n)(    if \(__builtin_available\(macOS 26, \*\)\) \{\n      DPSXCHECK\(posix_spawn_file_actions_addchdir\(&file_actions_, path\)\);\n    \} else) \{|$1#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000\n$2\n#endif\n    {|' \
  base/process/launch_mac.cc

# Helper: wrap an exact multi-line snippet in `#if <cond> ... [#else alt] #endif`, once.
wrap() {  # file cond snippet [alt]
  python3 - "$@" <<'PYW'
import sys
f, cond, snip = sys.argv[1:4]; alt = sys.argv[4] if len(sys.argv) > 4 else None
s = open(f).read()
tag = "// [custom] old-SDK guard"
if snip not in s: sys.exit(f"old-sdk-fixes: snippet not found in {f}")
if f"{tag}\n#if {cond}\n{snip}" in s: sys.exit(0)
rep = f"{tag}\n#if {cond}\n{snip}\n" + (f"#else\n{alt}\n" if alt else "") + "#endif"
open(f, "w").write(s.replace(snip, rep, 1))
PYW
}
SDK26='__MAC_OS_X_VERSION_MAX_ALLOWED >= 260000'

# remote_cocoa: NSGlassEffectView (Liquid Glass) is 26-SDK only; older SDK => never glass.
wrap components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm "$SDK26" \
'  if (@available(macOS 26, *)) {
    if ([view isKindOfClass:[NSGlassEffectView class]]) {
      return true;
    }
  }'

# webauthn: isDeviceConfiguredForPasskeys is macOS 26.2 SDK only.
wrap device/fido/mac/icloud_keychain_sys.mm '__MAC_OS_X_VERSION_MAX_ALLOWED >= 260200' \
'    return [ASAuthorizationWebBrowserPublicKeyCredentialManager
        isDeviceConfiguredForPasskeys];' \
'    return false;'

# skia: kCGImageByteOrder32Host is the 26-SDK spelling of kCGBitmapByteOrder32Host.
wrap skia/ext/skia_utils_mac.mm "$SDK26" \
'          kCGImageByteOrder32Host));' \
'          kCGBitmapByteOrder32Host));'

# CALayer HDR headroom API is 26-SDK only; older SDK => standard dynamic range.
wrap ui/accelerated_widget_mac/ca_renderer_layer_tree.mm "$SDK26" \
'      if (io_surface_color_space_.IsHDR() || max_hdr_headroom > 0.f) {
        // Assume that all HDR content uses the full 4 stops (16x linear)
        // headroom that an XDR display supports. Replace this when an accurate
        // TODO(https://crbug.com/540031280): Accurately track content HDR
        // headroom.
        ca_layer_.contentsHeadroom = 16.f;
        ca_layer_.preferredDynamicRange = CADynamicRangeHigh;
      } else {
        ca_layer_.contentsHeadroom = 0.f;
        ca_layer_.preferredDynamicRange = CADynamicRangeStandard;
      }' \
'      (void)max_hdr_headroom;'

# NSScreen.CGDirectDisplayID is 26-SDK only; the deviceDescription path works everywhere.
wrap ui/display/mac/screen_utils_mac.mm "$SDK26" \
'    if (@available(macOS 26, *)) {
      screen_display_id = screen.CGDirectDisplayID;
    } else {
      screen_display_id =
          [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    }' \
'    screen_display_id =
        [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];'

# Accessibility: ~140 web AX constants (kAX*Subrole/Attribute/Notification,
# NSAccessibilitySearch*Key) were first declared publicly in the 26 SDK. Define
# them (same strings WebKit uses) and include the header where they're used.
cp "$here/ax_sdk26_compat.h" ui/accessibility/platform/ax_sdk26_compat_mac.h
for f in ax_platform_node_cocoa.mm ax_platform_node_cocoa_unittest.mm browser_accessibility_cocoa.mm \
         browser_accessibility_manager_mac.mm browser_accessibility_mac_unittest.mm \
         inspect/ax_inspect_utils_mac.mm inspect/ax_event_recorder_mac.mm inspect/ax_element_wrapper_mac.mm; do
  f="ui/accessibility/platform/$f"
  grep -q 'ax_sdk26_compat_mac.h' "$f" ||
  perl -0pi -e 's|^(#(?:include\|import) )|#include "ui/accessibility/platform/ax_sdk26_compat_mac.h"  // [custom]\n$1|m' "$f"
done

echo "old-sdk-fixes: applied"
