#!/bin/bash
# VoltageOS build script for fogos, with step tracker, live build progress bar,
# logging, timing and error handling.

set -eo pipefail

# ---------- Config ----------
ROM_MANIFEST="https://github.com/VoltageOS/manifest.git"
ROM_BRANCH="17"
LOCAL_MANIFEST_URL="https://raw.githubusercontent.com/FaqatZubair1/scripts/main/local_manifest.xml"
DEVICE="fogos"
KEYS_DIR="vendor/voltage-priv/keys"
LOG_DIR="$(pwd)/build_logs"
TOTAL_STEPS=7

# ---------- Colors ----------
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'
  C=$'\033[0;36m'; W=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; W=""; N=""
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build_$(date +%Y%m%d_%H%M%S).log"
SCRIPT_START=$(date +%s)
STEP=0
STEP_START=$SCRIPT_START
CURRENT_STEP_NAME=""

# ---------- Helpers ----------
fmt_time() {
  local s=$1
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# bar <percent> <width>
bar() {
  local pct=$1 width=${2:-30}
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  printf '%s' "${G}"
  printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
  printf '%s' "${N}"
  printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
}

step() {
  STEP=$((STEP + 1))
  CURRENT_STEP_NAME="$1"
  STEP_START=$(date +%s)
  local pct=$(( (STEP - 1) * 100 / TOTAL_STEPS ))
  echo
  echo "${C}${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo "${W}Step ${STEP}/${TOTAL_STEPS}: $1${N}"
  printf 'Overall  [%s] %3d%%\n' "$(bar $pct 30)" "$pct"
  echo "${C}${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo "[STEP $STEP] $1" >> "$LOG"
}

step_done() {
  local took=$(( $(date +%s) - STEP_START ))
  echo "${G}✔ ${CURRENT_STEP_NAME} done in $(fmt_time $took)${N}"
}

fail() {
  echo
  echo "${R}${W}✖ FAILED at step ${STEP}/${TOTAL_STEPS}: ${CURRENT_STEP_NAME}${N}"
  echo "${R}Log: $LOG${N}"
  printf '\a'
  exit 1
}
trap 'fail' ERR

# Reads ninja output, draws a live progress bar, prints only errors, logs everything
build_progress() {
  local re='^\[ *([0-9]+)% ([0-9]+)/([0-9]+)\]'
  local line pct cur tot now elapsed eta
  local start; start=$(date +%s)
  while IFS= read -r line; do
    echo "$line" >> "$LOG"
    if [[ $line =~ $re ]]; then
      pct=${BASH_REMATCH[1]}; cur=${BASH_REMATCH[2]}; tot=${BASH_REMATCH[3]}
      now=$(date +%s); elapsed=$((now - start))
      eta="--:--:--"
      if [ "$cur" -gt 0 ] && [ "$elapsed" -gt 5 ]; then
        eta=$(fmt_time $(( elapsed * (tot - cur) / cur )))
      fi
      printf '\r\033[K%s [%s] %3d%%  %d/%d  elapsed %s  ETA %s' \
        "${W}Build${N}" "$(bar "$pct" 30)" "$pct" "$cur" "$tot" "$(fmt_time $elapsed)" "$eta"
    elif [[ $line =~ (FAILED|error:|Error|ERROR|fatal) ]]; then
      printf '\r\033[K%s\n' "${R}${line}${N}"
    elif [[ $line =~ (^####|build completed|Package Complete|Package complete) ]]; then
      printf '\r\033[K%s\n' "${Y}${line}${N}"
    fi
  done
  echo
}

# ---------- Start ----------
echo "${W}${B}VoltageOS ${ROM_BRANCH} build for ${DEVICE}${N}"
echo "Log file: $LOG"

# 1. Clean old local manifests
step "Removing old local manifests"
rm -rf .repo/local_manifests
step_done

# 2. Repo init
step "Initializing repo"
repo init -u "$ROM_MANIFEST" -b "$ROM_BRANCH" --git-lfs --depth=1 2>&1 | tee -a "$LOG"
step_done

# 3. Local manifest
step "Downloading local manifest"
mkdir -p .repo/local_manifests
curl -fSL --progress-bar -o .repo/local_manifests/local_manifest.xml "$LOCAL_MANIFEST_URL"
step_done

# 4. Sync
step "Syncing repositories"
repo sync -c --force-sync --optimized-fetch --no-tags --no-clone-bundle --prune \
  -j"$(nproc --all)" 2>&1 | tee -a "$LOG"
step_done

# 5. Fix LFS pointer files (WebView prebuilts)
step "Verifying WebView LFS files"
for arch in arm64 arm; do
  d="external/chromium-webview/prebuilt/$arch"
  if [ -d "$d" ] && [ -f "$d/webview.apk" ]; then
    size=$(stat -c%s "$d/webview.apk")
    if [ "$size" -lt 1000 ]; then
      echo "${Y}$arch webview.apk is an LFS pointer ($size bytes), pulling...${N}"
      git -C "$d" lfs install >> "$LOG" 2>&1
      git -C "$d" lfs pull 2>&1 | tee -a "$LOG"
    else
      echo "${G}$arch webview.apk OK ($((size / 1024 / 1024)) MB)${N}"
    fi
  fi
done
step_done

# 6. Keys
step "Generating signing keys"
if ls "$KEYS_DIR"/*.pk8 >/dev/null 2>&1; then
  echo "${Y}Keys already exist, skipping (delete *.pk8 to regenerate).${N}"
else
  pushd "$KEYS_DIR" > /dev/null
  ./keys.sh 2>&1 | tee -a "$LOG"
  popd > /dev/null
fi
step_done

# 7. Build
step "Building ROM (brunch fogos)"
# shellcheck disable=SC1091
. build/envsetup.sh >> "$LOG" 2>&1
brunch fogos 2>&1 | build_progress
step_done

# ---------- Summary ----------
TOTAL=$(( $(date +%s) - SCRIPT_START ))
OUT="out/target/product/$DEVICE"
echo
echo "${G}${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
printf 'Overall  [%s] 100%%\n' "$(bar 100 30)"
echo "${G}${W}✔ BUILD FINISHED in $(fmt_time $TOTAL)${N}"
echo "Output: $OUT"
ls -lh "$OUT"/*.zip 2>/dev/null | awk '{print "  " $5 "  " $9}' || true
echo "Log:    $LOG"
echo "${G}${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
printf '\a'
