#!/bin/bash
echo "======= Remove Project ========="

rm -rf .repo/local_manifests
rm -rf kernel/*
rm -rf device/*
rm -rf vendor/*
rm -rf hardware/*



echo "======= Remove Done ======"
# Rom source repo
        repo init -u https://github.com/VoltageOS/manifest.git -b 17 --git-lfs --depth=1
        
echo "Repo init success"
echo "=================="

echo "===== Sync the repositories ========"

/opt/crave/resync.sh

echo "======== Syncing Done =========="



git clone --depth=1 https://github.com/project-moon-gazer/android_device_motorola_fogos.git -b vos-https device/motorola/fogos
bash d*/m*/f*/vendorsetup.sh 

echo "=================="
echo "Cloning Done"
echo "=================="

# Exports
export BUILD_USERNAME=Niggesha
export BUILD_HOSTNAME=CraveCloud
export TZ=Asia/Bishkek
   # Fix for error memory stall at build soong 
   wget https://github.com/yaap-17-stone/build_soong/raw/f9c27b0b9298f6eeee9a850346e0a646c3eaeb87/cmd/soong_build/main.go && mv main.go build/soong/cmd/soong_build/
echo "=================="
echo " Exports Done "
echo "=================="
echo " adding ksu "
cd kernel/motorola/sm637*
curl -LSs https://raw.githubusercontent.com/FaqatZubair1/scripts/main/ksu_backslashxx.sh | bash
cd ../../..
echo " ksu done "

echo "===== per-app rotation toggle ====="
(
  set -e
  cd packages/apps/Settings
  git checkout -- .    # drop leftovers from a previous run
  curl -fsSL -o /tmp/per_app_rotation_toggle.patch \
    https://raw.githubusercontent.com/FaqatZubair1/scripts/main/per_app_rotation_toggle.patch
  git apply --check /tmp/per_app_rotation_toggle.patch
  git apply /tmp/per_app_rotation_toggle.patch
  echo "per-app rotation patch applied"
) || { echo "!!! per-app rotation patch FAILED - stopping"; exit 1; }

echo "===== zygote_next: log reinit error + tmpfs sepolicy ====="
(
  set -e
  # reset leftovers from a previous run
  git -C system/zygote checkout -- zygote/src/server.rs
  git -C system/sepolicy checkout -- private/zygote_next.te

  python3 - <<'PY'
import sys
p = "system/zygote/zygote/src/server.rs"
s = open(p).read()
old = ".map_err(|_| ClientError::Reinitialization)?;"
if s.count(old) != 1:
    sys.exit("server.rs: pattern found %d times, expected 1 - patch by hand" % s.count(old))
new = (".map_err(|e| {\n"
       "                    error!(\"re_initialize_as_subspecies failed: {e:?}\");\n"
       "                    ClientError::Reinitialization\n"
       "                })?;")
open(p, "w").write(s.replace(old, new))
print("server.rs patched")
PY

  python3 - <<'PY'
p = "system/zygote/zygote/src/server.rs"
s = open(p).read()

def ins_after(s, anchor, text, label):
    if s.count(anchor) != 1:
        print("[dbg] WARNING anchor for %s found %d times - skipped" % (label, s.count(anchor)))
        return s
    return s.replace(anchor, anchor + text)

# who calls remove_client_socket, with which fd, and a backtrace
s = ins_after(s,
  "fn remove_client_socket(&mut self, fd: RawFd) -> ClientResult<()> {\n",
  "        error!(\"DBG remove_client_socket fd={fd} bt={}\", std::backtrace::Backtrace::force_capture());\n",
  "remove_client_socket")

# did re-init start / finish
s = ins_after(s,
  "fn re_initialize_as_subspecies(&mut self, child_socket_path: String) -> ServerResult<()> {\n",
  "        error!(\"DBG reinit start\");\n",
  "reinit start")
anchor = "        self.pid = sys::getpid();\n\n        Ok(())\n"
if s.count(anchor) == 1:
    s = s.replace(anchor, "        self.pid = sys::getpid();\n        error!(\"DBG reinit done\");\n\n        Ok(())\n")
else:
    print("[dbg] WARNING reinit-done anchor found %d times - skipped" % s.count(anchor))

open(p, "w").write(s)
print("[dbg] done")
PY


  TE=system/sepolicy/private/zygote_next.te
  [ -f "$TE" ] || { echo "$TE missing"; exit 1; }
  grep -q "tmpfs_domain(zygote_next)" "$TE" || cat >> "$TE" <<'EOF'

# tmpfs typing for zygote_next memfds (fixes Chrome app-zygote helper dying in enforcing)
type zygote_next_tmpfs, file_type;
tmpfs_domain(zygote_next)
EOF
  echo "zygote_next patches applied"
) || { echo "!!! zygote_next patch FAILED - stopping"; exit 1; }

echo "three finger screenshot fix"

curl -fsSL https://raw.githubusercontent.com/FaqatZubair1/scripts/main/fix_screenshot_display.sh | bash

echo " generating keys "
cd v*/v*/ke*
bash ./keys.sh
cd ../../..
# Set up build environment
. b*/env*


echo "=================="
echo "Building Rom"
echo "=================="

# Build rom
brunch fogos

