#!/bin/bash
# bitperfect_direct.sh -- paste into your build script / vendorsetup.sh (after the repos are cloned).
# Run from the ROM source root. Idempotent: safe to run on every build. Upgrades the v1 patch.
#
# What it does:
#  1. frameworks/av: when system property audio.bitperfect.direct=true, stereo integer-PCM *music*
#     (usage MEDIA + content type MUSIC) going to a wired/USB headset asks for AUDIO_OUTPUT_FLAG_DIRECT
#     (native rate, no mixer resample). It never evicts another client's direct output, and if no
#     direct profile matches the stock code falls back to the mixer.
#  2. fogos audio_io_policy.conf: allow 44.1k/88.2k/176.4k/192k on the direct_pcm_* profiles.
#  3. fogos audio_platform_info.xml: 24-bit headphone backend (bit_width_configs).
#  4. Default the property to true in common system_ext.prop (set to false to disable).

bitperfect_direct_setup() {
    local ROOT="${ANDROID_BUILD_TOP:-$PWD}"
    local APM="$ROOT/frameworks/av/services/audiopolicy/managerdefault/AudioPolicyManager.cpp"
    local DEV="$ROOT/device/motorola/fogos"
    local COM="$ROOT/device/motorola/sm6375-common"
    local PROP="audio.bitperfect.direct"

    # ---- 1. frameworks/av patch ----
    if [ -f "$APM" ]; then
        python3 - "$APM" "$PROP" <<'PYEOF'
import sys, re
path, prop = sys.argv[1], sys.argv[2]
s = open(path).read()
if "BITPERFECT_DIRECT_V2" in s:
    print("[bitperfect] APM already patched (v2)"); sys.exit(0)

# drop an older (v1) block if present
s = re.sub(r"\n    // BITPERFECT_DIRECT: .*?AUDIO_OUTPUT_FLAG_DIRECT\);\n    }\n", "\n", s, flags=re.S)

anchor = """    if ((*flags & AUDIO_OUTPUT_FLAG_HW_AV_SYNC) != 0) {
        *flags = (audio_output_flags_t)(*flags | AUDIO_OUTPUT_FLAG_DIRECT);
    }

    audio_stream_type_t stream = mEngine->getStreamTypeForAttributes(*attr);
"""
if s.count(anchor) != 1:
    print("[bitperfect] ERROR: anchor not found in getOutputForDevices (source differs); NOT patched")
    sys.exit(1)

patch = anchor + """
    // BITPERFECT_DIRECT_V2: request a direct (non-mixed) output for stereo integer PCM *music*
    // (usage MEDIA + content type MUSIC) on wired/USB headsets so the stream keeps its native
    // sample rate. Never evict another client's direct output: the direct profile allows a single
    // open output, and closing it kills that client's tracks (dead IAudioTrack restore loops).
    // If no direct profile matches, openDirectOutput() returns NAME_NOT_FOUND and the DIRECT
    // flag is stripped below, i.e. normal mixer playback.
    if (property_get_bool("@PROP@", false /* default_value */) &&
            stream == AUDIO_STREAM_MUSIC &&
            attr->usage == AUDIO_USAGE_MEDIA &&
            attr->content_type == AUDIO_CONTENT_TYPE_MUSIC &&
            (*flags & ~(AUDIO_OUTPUT_FLAG_PRIMARY | AUDIO_OUTPUT_FLAG_FAST |
                        AUDIO_OUTPUT_FLAG_DEEP_BUFFER)) == 0 &&
            audio_is_linear_pcm(config->format) && config->format != AUDIO_FORMAT_PCM_FLOAT &&
            audio_channel_count_from_out_mask(config->channel_mask) <= 2 &&
            devices.size() == 1 &&
            (devices.itemAt(0)->type() == AUDIO_DEVICE_OUT_WIRED_HEADSET ||
             devices.itemAt(0)->type() == AUDIO_DEVICE_OUT_WIRED_HEADPHONE ||
             devices.itemAt(0)->type() == AUDIO_DEVICE_OUT_USB_HEADSET)) {
        bool directBusy = false;
        for (size_t i = 0; i < mOutputs.size(); i++) {
            const sp<SwAudioOutputDescriptor> desc = mOutputs.valueAt(i);
            if (!desc->isDuplicated() &&
                    (desc->mFlags & AUDIO_OUTPUT_FLAG_DIRECT) != 0 &&
                    (desc->mFlags & AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD) == 0 &&
                    desc->mDirectClientSession != session) {
                directBusy = true;
                break;
            }
        }
        if (!directBusy) {
            *flags = (audio_output_flags_t)((*flags & ~(AUDIO_OUTPUT_FLAG_PRIMARY |
                    AUDIO_OUTPUT_FLAG_FAST | AUDIO_OUTPUT_FLAG_DEEP_BUFFER)) |
                    AUDIO_OUTPUT_FLAG_DIRECT);
        }
    }
""".replace("@PROP@", prop)

s = s.replace(anchor, patch)
open(path, "w").write(s)
print("[bitperfect] patched", path)
PYEOF
    else
        echo "[bitperfect] WARNING: $APM not found, skipping framework patch"
    fi

    # ---- 2. audio_io_policy.conf: native rates on direct_pcm profiles ----
    local CONF="$DEV/audio/audio_io_policy.conf"
    if [ -f "$CONF" ]; then
        python3 - "$CONF" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p).read()
new = "44100|48000|88200|96000|176400|192000"
def fix(m):
    return re.sub(r"sampling_rates [^\n]*", "sampling_rates " + new, m.group(0), count=1)
out, n = re.subn(r"  direct_pcm_(?:16|24|32) \{.*?\n  \}", fix, s, flags=re.S)
if out != s:
    open(p, "w").write(out); print("[bitperfect] updated direct_pcm rates in", p)
else:
    print("[bitperfect] audio_io_policy.conf already up to date (%d blocks)" % n)
PYEOF
    fi

    # ---- 3. audio_platform_info.xml: 24-bit headphone backend ----
    local PLAT="$DEV/audio/audio_platform_info.xml"
    if [ -f "$PLAT" ] && ! grep -q 'SND_DEVICE_OUT_HEADPHONES" bit_width' "$PLAT"; then
        sed -i 's#\(<device name="SND_DEVICE_OUT_SPEAKER" bit_width="24"/>\)#\1\n        <device name="SND_DEVICE_OUT_HEADPHONES" bit_width="24"/>\n        <device name="SND_DEVICE_OUT_HEADPHONES_44_1" bit_width="24"/>#' "$PLAT"
        echo "[bitperfect] added headphone bit_width to $PLAT"
    fi

    # ---- 4. default property ----
    local SEP="$COM/system_ext.prop"
    if [ -f "$SEP" ] && ! grep -q "^$PROP=" "$SEP"; then
        printf '\n# Request DIRECT output for wired/USB headset music (bit-perfect path)\n%s=true\n' "$PROP" >> "$SEP"
        echo "[bitperfect] added $PROP=true to $SEP"
    fi

    # sepolicy sanity: audioserver must be allowed to read the property
    if ! grep -rqs '^audio\.' "$ROOT/system/sepolicy/private/property_contexts" 2>/dev/null; then
        echo "[bitperfect] NOTE: could not confirm 'audio.*' props are labelled readable by audioserver; check logcat for avc denials"
    fi
}
bitperfect_direct_setup
