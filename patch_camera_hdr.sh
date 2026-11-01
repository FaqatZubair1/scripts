#!/usr/bin/env bash
# patch_camera_hdr.sh — run from the ROM source root (after repo sync, before build).
# Idempotent. Applies the cameraserver shutter-order workaround and checks the
# assumptions behind it. Exit code is 0 unless a hard requirement fails.
#
# Assumptions being tested:
#  A1  AOSP cameraserver has the strict "Shutter notification out-of-order" SET_ERR
#  A2  the Moto camera APK is the real file (not a Git LFS pointer)
#  A3  libAncFaceDetect.so (missing in your log) is shipped by some vendor tree
#  A4  camera props from camera.mk actually end up in the build
set -u
TOP="${ANDROID_BUILD_TOP:-$PWD}"; cd "$TOP" || exit 1
MARK="HDR_SHUTTER_WORKAROUND"
pass(){ printf '[PASS] %s\n' "$*"; }; warn(){ printf '[WARN] %s\n' "$*"; }; fail(){ printf '[FAIL] %s\n' "$*"; RC=1; }
RC=0

# ---- A1: find and patch the shutter check -------------------------------
DIR=frameworks/av/services/camera/libcameraservice
if [ ! -d "$DIR" ]; then fail "A1 $DIR not found (run from ROM root)"; exit 1; fi
FILES=$(grep -rl "Shutter notification out-of-order" "$DIR" 2>/dev/null || true)
if [ -z "$FILES" ]; then
  warn "A1 string 'Shutter notification out-of-order' not found in $DIR — check is elsewhere or already removed; nothing patched"
else
  for f in $FILES; do
    if grep -q "$MARK" "$f"; then pass "A1 $f already patched"; continue; fi
    python3 - "$f" "$MARK" <<'PY' || { fail "A1 could not patch $f (source layout differs, patch by hand)"; continue; }
import re, sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path).read()
# SET_ERR("... out-of-order ...", args);  ->  ALOGW(...)  (same args; the following 'return;' is kept)
pat = re.compile(r'(?:\w*SET_ERR\w*|[\w.>-]*setErrorState)\(\s*("Shutter notification out-of-order[^;]*?)\)\s*;', re.S)
new, n = pat.subn(lambda m: '/* %s: stock Moto HAL reports ZSL original frame numbers; ignore stale shutters\n'
                  '             instead of putting the device into an error state */\n'
                  '            ALOGW(%s);' % (mark, m.group(1)), src)
if n < 1:
    import subprocess
    sys.stderr.write('--- no match; surrounding source (paste this to Claude):\n')
    subprocess.call(['grep','-n','-B12','-A8','Shutter notification out-of-order',path], stdout=sys.stderr)
    sys.exit(1)
open(path, 'w').write(new)
print("patched %d site in %s" % (n, path))
PY
    if grep -q "$MARK" "$f"; then
      pass "A1 patched $f"
      # the check must still 'return' right after the log, otherwise stale frames overwrite mNextShutterFrameNumber
      if grep -A6 "$MARK" "$f" | grep -q 'return;'; then pass "A1 early return preserved"; else fail "A1 no 'return;' after patched ALOGW — review $f by hand"; fi
    fi
  done
fi

# ---- A2: Moto camera APK must not be an LFS pointer ---------------------
APK=$(find vendor/motorola -name 'MotCamera4.apk' -o -name 'MotCamera3.apk' 2>/dev/null | head -1)
if [ -z "$APK" ]; then warn "A2 no MotCamera*.apk under vendor/motorola"
else
  SZ=$(stat -c %s "$APK")
  if [ "$SZ" -lt 1000000 ]; then fail "A2 $APK is $SZ bytes (LFS pointer?) — run: git -C $(git -C $(dirname "$APK") rev-parse --show-toplevel) lfs pull"
  else pass "A2 $APK is $((SZ/1024/1024)) MB"; fi
fi

# ---- A3: libAncFaceDetect.so shipped somewhere --------------------------
HITS=$(grep -rIl "libAncFaceDetect" vendor/motorola device/motorola 2>/dev/null | head -3)
BLOB=$(find vendor/motorola device/motorola -name 'libAncFaceDetect.so' 2>/dev/null | head -1)
if [ -n "$BLOB" ]; then pass "A3 blob present: $BLOB"
elif [ -n "$HITS" ]; then warn "A3 referenced but blob file not found (LFS/proprietary-files only?): $HITS"
else warn "A3 libAncFaceDetect.so not in vendor trees — add it to proprietary-files.txt (vendor/lib64), pull from stock /vendor/lib64"; fi

# ---- A4: camera props reach the build -----------------------------------
if [ -f vendor/motorola/camera/camera.mk ]; then
  for p in persist.vendor.camera.physical.num vendor.camera.aux.packagelist; do
    grep -q "$p" vendor/motorola/camera/camera.mk && pass "A4 $p set in camera.mk (compare value with stock getprop!)"
  done
  grep -rq "camera.mk" device/motorola 2>/dev/null && pass "A4 camera.mk is inherited by a device tree" || warn "A4 no device tree inherits camera.mk"
fi
exit $RC
