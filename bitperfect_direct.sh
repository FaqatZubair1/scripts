#!/bin/bash
# bitperfect_direct.sh (v3) -- paste into your build script / vendorsetup.sh after the repos are cloned.
# Run from the ROM source root (or with ANDROID_BUILD_TOP set). Idempotent; upgrades v1/v2 patches.
#
# 1. frameworks/av: with property audio.bitperfect.direct=true, stereo integer-PCM *music*
#    (usage MEDIA + content type MUSIC) on a wired/USB headset requests AUDIO_OUTPUT_FLAG_DIRECT
#    (native rate, no mixer resample). It never evicts another client's direct output, and if no
#    direct profile matches the stock code falls back to the mixer.
# 2. fogos audio_io_policy.conf: 44.1k/88.2k/176.4k/192k on the direct_pcm_* profiles.
# 3. fogos audio_platform_info.xml: 24-bit headphone backend.
# 4. system_ext.prop: audio.bitperfect.direct=true by default.
#
# v3: no longer depends on an exact multi-line anchor. It finds getOutputForDevices() by name,
# reads the real parameter names from its signature, and inserts after the stream declaration
# (or before the spatializer check as a fallback). If something is really different it stops
# with a precise message instead of guessing.

bitperfect_direct_setup() {
    local ROOT="${ANDROID_BUILD_TOP:-$PWD}"
    local PROP="audio.bitperfect.direct"
    local rc=0

    local APM
    APM=$(find "$ROOT/frameworks/av/services/audiopolicy" -name AudioPolicyManager.cpp -path '*managerdefault*' 2>/dev/null | head -1)

    local DEV="$ROOT/device/motorola/fogos"
    local COM="$ROOT/device/motorola/sm6375-common"
    local CONF="$DEV/audio/audio_io_policy.conf"
    [ -f "$CONF" ] || CONF=$(ls "$ROOT"/device/motorola/*/audio/audio_io_policy.conf 2>/dev/null | head -1)
    local PLAT="$DEV/audio/audio_platform_info.xml"
    [ -f "$PLAT" ] || PLAT=$(ls "$ROOT"/device/motorola/*/audio/audio_platform_info.xml 2>/dev/null | head -1)
    local SEP="$COM/system_ext.prop"
    [ -f "$SEP" ] || SEP="$DEV/system_ext.prop"

    # ---- 1. frameworks/av patch ----
    if [ -n "$APM" ] && [ -f "$APM" ]; then
        python3 - "$APM" "$PROP" <<'PYEOF' || rc=1
import sys, re, os

path, prop = sys.argv[1], sys.argv[2]
s = open(path).read()

def fail(msg):
    print("[bitperfect] ERROR: " + msg + " -- framework NOT patched")
    sys.exit(1)

if "BITPERFECT_DIRECT_V2" in s:
    print("[bitperfect] APM already patched"); sys.exit(0)

# drop older (v1) block if present
s = re.sub(r"\n    // BITPERFECT_DIRECT: .*?AUDIO_OUTPUT_FLAG_DIRECT\);\n    }\n", "\n", s, flags=re.S)

# prerequisites in the descriptor header (member names we rely on)
inc = os.path.join(os.path.dirname(path), "..", "common", "managerdefinitions", "include", "AudioOutputDescriptor.h")
if os.path.exists(inc):
    h = open(inc).read()
    for sym in ("mDirectClientSession", "isDuplicated"):
        if sym not in h:
            fail("%s no longer exists in AudioOutputDescriptor.h (upstream refactor); the busy check needs porting" % sym)

# locate getOutputForDevices definition
m = re.search(r"audio_io_handle_t\s+AudioPolicyManager::getOutputForDevices\s*\((.*?)\)\s*\{", s, flags=re.S)
if not m:
    fail("getOutputForDevices() definition not found")
sig = m.group(1)
body_start = m.end()
end = s.find("\n}\n", body_start)
if end < 0:
    fail("could not find end of getOutputForDevices()")
body = s[body_start:end]

def param(pattern, what):
    pm = re.search(pattern, sig)
    if not pm:
        fail("getOutputForDevices() signature changed: no %s parameter found in (%s)" % (what, " ".join(sig.split())))
    return pm.group(1)

devices = param(r"const\s+DeviceVector\s*&\s*(\w+)", "DeviceVector")
session = param(r"audio_session_t\s+(\w+)", "audio_session_t")
attr    = param(r"const\s+audio_attributes_t\s*\*\s*(\w+)", "audio_attributes_t*")
config  = param(r"const\s+audio_config_t\s*\*\s*(\w+)", "audio_config_t*")
flags   = param(r"audio_output_flags_t\s*\*\s*(\w+)", "audio_output_flags_t*")

# insertion point: after the stream declaration; fallback: before the spatializer check
sm = re.search(r"^[ \t]*audio_stream_type_t\s+(\w+)\s*=\s*mEngine->getStreamTypeForAttributes\(\s*\*\s*%s\s*\);[ \t]*\n" % attr, body, flags=re.M)
if sm:
    stream = sm.group(1)
    decl = ""
    pos = body_start + sm.end()
else:
    fm = re.search(r"^[ \t]*(//[^\n]*[Ss]patializer output[^\n]*\n|\*isSpatialized\s*=\s*false;)", body, flags=re.M)
    if not fm:
        fm = re.search(r"^[ \t]*audio_config_t\s+directConfig\s*=", body, flags=re.M)
    if not fm:
        fail("no usable insertion point in getOutputForDevices() (no stream declaration, spatializer check or directConfig)")
    stream = "bpStream"
    decl = "    const audio_stream_type_t bpStream = mEngine->getStreamTypeForAttributes(*%s);\n" % attr
    pos = body_start + fm.start()

for need in ("mOutputs", "mEngine"):
    if need not in s:
        fail("%s not found in AudioPolicyManager.cpp" % need)

patch = """
    // BITPERFECT_DIRECT_V2: request a direct (non-mixed) output for stereo integer PCM *music*
    // (usage MEDIA + content type MUSIC) on wired/USB headsets so the stream keeps its native
    // sample rate. Never evict another client's direct output: the direct profile allows a single
    // open output, and closing it kills that client's tracks (dead IAudioTrack restore loops).
    // If no direct profile matches, openDirectOutput() returns NAME_NOT_FOUND and the DIRECT
    // flag is stripped below, i.e. normal mixer playback.
@DECL@    if (property_get_bool("@PROP@", false /* default_value */) &&
            @STREAM@ == AUDIO_STREAM_MUSIC &&
            @ATTR@->usage == AUDIO_USAGE_MEDIA &&
            @ATTR@->content_type == AUDIO_CONTENT_TYPE_MUSIC &&
            (*@FLAGS@ & ~(AUDIO_OUTPUT_FLAG_PRIMARY | AUDIO_OUTPUT_FLAG_FAST |
                        AUDIO_OUTPUT_FLAG_DEEP_BUFFER)) == 0 &&
            audio_is_linear_pcm(@CONFIG@->format) && @CONFIG@->format != AUDIO_FORMAT_PCM_FLOAT &&
            audio_channel_count_from_out_mask(@CONFIG@->channel_mask) <= 2 &&
            @DEVICES@.size() == 1 &&
            (@DEVICES@.itemAt(0)->type() == AUDIO_DEVICE_OUT_WIRED_HEADSET ||
             @DEVICES@.itemAt(0)->type() == AUDIO_DEVICE_OUT_WIRED_HEADPHONE ||
             @DEVICES@.itemAt(0)->type() == AUDIO_DEVICE_OUT_USB_HEADSET)) {
        bool directBusy = false;
        for (size_t i = 0; i < mOutputs.size(); i++) {
            const sp<SwAudioOutputDescriptor> desc = mOutputs.valueAt(i);
            if (!desc->isDuplicated() &&
                    (desc->mFlags & AUDIO_OUTPUT_FLAG_DIRECT) != 0 &&
                    (desc->mFlags & AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD) == 0 &&
                    desc->mDirectClientSession != @SESSION@) {
                directBusy = true;
                break;
            }
        }
        if (!directBusy) {
            *@FLAGS@ = (audio_output_flags_t)((*@FLAGS@ & ~(AUDIO_OUTPUT_FLAG_PRIMARY |
                    AUDIO_OUTPUT_FLAG_FAST | AUDIO_OUTPUT_FLAG_DEEP_BUFFER)) |
                    AUDIO_OUTPUT_FLAG_DIRECT);
        }
    }
"""
for k, v in (("@DECL@", decl), ("@PROP@", prop), ("@STREAM@", stream), ("@ATTR@", attr),
             ("@FLAGS@", flags), ("@CONFIG@", config), ("@DEVICES@", devices), ("@SESSION@", session)):
    patch = patch.replace(k, v)

s = s[:pos] + patch + s[pos:]
open(path, "w").write(s)
print("[bitperfect] patched %s (insert via %s; params: %s/%s/%s/%s/%s)" %
      (path, "stream decl" if sm else "fallback anchor", devices, session, attr, config, flags))
PYEOF
    else
        echo "[bitperfect] WARNING: AudioPolicyManager.cpp not found under $ROOT/frameworks/av, skipping framework patch"
        rc=1
    fi

    # ---- 2. audio_io_policy.conf: native rates on direct_pcm profiles ----
    if [ -n "$CONF" ] && [ -f "$CONF" ]; then
        python3 - "$CONF" <<'PYEOF' || rc=1
import sys, re
p = sys.argv[1]
s = open(p).read()
new = "44100|48000|88200|96000|176400|192000"
def fix(m):
    return re.sub(r"sampling_rates[ \t]+[^\n]*", "sampling_rates " + new, m.group(0), count=1)
out, n = re.subn(r"direct_pcm_(?:16|24|32)[ \t]*\{.*?\n[ \t]*\}", fix, s, flags=re.S)
if n == 0:
    print("[bitperfect] ERROR: no direct_pcm_* profiles found in", p); sys.exit(1)
if out != s:
    open(p, "w").write(out); print("[bitperfect] updated direct_pcm rates in", p)
else:
    print("[bitperfect] audio_io_policy.conf already up to date (%d blocks)" % n)
PYEOF
    else
        echo "[bitperfect] WARNING: audio_io_policy.conf not found, skipping"
        rc=1
    fi

    # ---- 3. audio_platform_info.xml: 24-bit headphone backend ----
    if [ -n "$PLAT" ] && [ -f "$PLAT" ]; then
        if grep -q 'SND_DEVICE_OUT_HEADPHONES" bit_width' "$PLAT"; then
            echo "[bitperfect] headphone bit_width already present"
        elif grep -q '<bit_width_configs>' "$PLAT"; then
            sed -i '0,/<bit_width_configs>/s##<bit_width_configs>\n        <device name="SND_DEVICE_OUT_HEADPHONES" bit_width="24"/>\n        <device name="SND_DEVICE_OUT_HEADPHONES_44_1" bit_width="24"/>#' "$PLAT"
            echo "[bitperfect] added headphone bit_width to $PLAT"
        else
            echo "[bitperfect] WARNING: no <bit_width_configs> in $PLAT, skipped headphone bit width"
        fi
    fi

    # ---- 4. default property ----
    if [ -f "$SEP" ]; then
        if grep -q "^$PROP=" "$SEP"; then
            echo "[bitperfect] $PROP already set in $SEP"
        else
            printf '\n# Request DIRECT output for wired/USB headset music (bit-perfect path)\n%s=true\n' "$PROP" >> "$SEP"
            echo "[bitperfect] added $PROP=true to $SEP"
        fi
    else
        echo "[bitperfect] WARNING: no system_ext.prop found, set $PROP=true yourself"
        rc=1
    fi

    if ! grep -rqs '^audio\.' "$ROOT/system/sepolicy/private/property_contexts" 2>/dev/null; then
        echo "[bitperfect] NOTE: could not confirm 'audio.*' props are readable by audioserver; check logcat for avc denials"
    fi
    [ $rc -eq 0 ] && echo "[bitperfect] all steps OK" || echo "[bitperfect] finished WITH PROBLEMS (see messages above)"
    return $rc
}
bitperfect_direct_setup
