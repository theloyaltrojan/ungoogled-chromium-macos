#!/usr/bin/env bash
# Rebuild a lost/corrupted out/Default/.ninja_deps without recompiling.
#
#   custom/restore-ninja-deps.sh            (no other ninja may run meanwhile)
#
# Symptom: `ninja -n -d explain` says "deps for '...o' are missing" for objects
# that are already built, so ninja wants to redo the whole compile.
#
# How: for every C/C++/ObjC object, re-run its exact compile command with
# `-E -o /dev/null` appended (preprocess only, ~10x cheaper than compiling),
# letting clang write the same depfile so ninja records the header list again.
# The .o files are never written, so their mtimes stay valid. Afterwards the
# original toolchain.ninja and .ninja_log (command hashes) are put back.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/src/out/Default"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
cd "$OUT"
if pgrep -x ninja >/dev/null; then echo "another ninja is running; stop it first" >&2; exit 1; fi

mapfile_tc=$(find . -name toolchain.ninja)
for f in $mapfile_tc; do
  # Pristine copy (deps enabled). Prefer an existing .bak-deps from the no-deps workaround.
  [[ -f "$f.bak-deps" ]] || cp "$f" "$f.bak-deps"
done
cp .ninja_log .ninja_log.keep

# A bad record in .ninja_deps makes every later load stop there, so anything
# appended after it is silently lost. Truncate at the first bad record.
python3 - <<'PY2'
import struct
d = open(".ninja_deps", "rb").read(); off, n = 16, 0
while off + 4 <= len(d):
    (sz,) = struct.unpack("<I", d[off:off+4]); is_deps = sz >> 31; sz &= 0x7fffffff
    if off + 4 + sz > len(d): break
    if not is_deps:
        (chk,) = struct.unpack("<I", d[off+sz:off+4+sz])
        if (~chk & 0xffffffff) != n: break
        n += 1
    off += 4 + sz
if off != len(d):
    print(f".ninja_deps: truncating {len(d)} -> {off} (bad record)")
    open(".ninja_deps", "r+b").truncate(off)
PY2

restore() {
  for f in $mapfile_tc; do cp "$f.bak-deps" "$f"; done
  # Re-append the real compile entries for the objects we only preprocessed (the
  # last entry per output wins), keeping everything else ninja really rebuilt.
  [[ -f /tmp/deps_only_targets.txt ]] && python3 - <<'PY2'
want = set(open("/tmp/deps_only_targets.txt").read().split())
keep = {}
for line in open(".ninja_log.keep"):
    f = line.rstrip("\n").split("\t")
    if len(f) == 5 and f[3] in want: keep[f[3]] = line
with open(".ninja_log", "a") as out: out.writelines(keep.values())
print(f"ninja_log: restored {len(keep)} compile entries")
PY2
  rm -f deps_only.ninja
}
trap restore EXIT

# Preprocess-only variant of the cc/cxx/objc/objcxx rules. -MT keeps the depfile
# naming the real .o (ninja checks it).
for f in $mapfile_tc; do
  python3 - "$f.bak-deps" "$f" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
out, rule = [], None
for line in open(src):
    m = re.match(r"rule (\S+)", line)
    if m: rule = m.group(1)
    elif not line.startswith("  "): rule = None
    if rule in ("cc", "cxx", "objc", "objcxx") and line.startswith("  command = "):
        line = line.rstrip("\n") + " -E -o /dev/null -MT ${target_out_dir}/${label_name}/${source_name_part}.o\n"
    out.append(line)
open(dst, "w").write("".join(out))
PY
done

# Every object built by those rules, behind one phony target (too many for argv).
# Only objects that chrome/chromedriver actually use (the tree also has ~25k test objects).
ninja -t targets all | sed -nE 's/^(.+\.o): (cc|cxx|objc|objcxx)$/\1/p' | sort > /tmp/deps_c_objs.txt
ninja -t inputs chrome chromedriver | sort > /tmp/deps_needed.txt
comm -12 /tmp/deps_c_objs.txt /tmp/deps_needed.txt | awk -v n="${LIMIT:-1000000}" 'NR<=n' > /tmp/deps_only_targets.txt
echo "objects: $(wc -l < /tmp/deps_only_targets.txt)"
python3 - <<'PY'
t = open("/tmp/deps_only_targets.txt").read().split()
open("deps_only.ninja", "w").write("include build.ninja\nbuild deps_only_all: phony " + " ".join(p.replace(" ", "$ ").replace(":", "$:") for p in t) + "\n")
PY

ninja -f deps_only.ninja -k 0 deps_only_all
restore; trap - EXIT
echo "== remaining work for chrome + chromedriver:"
ninja -n chrome chromedriver | tail -1
