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


echo "three finger screenshot fix"

curl -fsSL https://raw.githubusercontent.com/FaqatZubair1/scripts/main/fix_screenshot_display.sh | bash

echo "bit-perfect addition"
curl -fsSL https://raw.githubusercontent.com/FaqatZubair1/scripts/main/bitperfect_direct.sh | bash


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


echo "===== zygote_next: anon-inode fd classification fix + tmpfs sepolicy ====="
(
  set -e
  git -C system/zygote checkout -- zygote/src/server.rs zygote/src/file_descriptors.rs
  git -C system/sepolicy checkout -- private/zygote_next.te

  python3 - <<'PY'
import sys
p = "system/zygote/zygote/src/file_descriptors.rs"
s = open(p).read()
old = "            libc::S_IFCHR | libc::S_IFREG => Self::get_file_info(fd, &stat),\n"
if s.count(old) != 1:
    sys.exit("file_descriptors.rs: anchor found %d times, expected 1" % s.count(old))
new = '''            libc::S_IFCHR | libc::S_IFREG => {
                // Older kernels (e.g. 5.4) report anonymous inodes such as
                // signalfd and eventpoll as S_IFCHR; classify them by their
                // /proc link like the fallback arm below does.
                if let Ok(link) = get_proc_fd_link_info(fd) {
                    if let Ok(link_cstr) = link.as_cstr() {
                        if link_cstr == PROC_METADATA_SIGNALFD {
                            return Ok(FileDescriptorInfo::SignalFd);
                        }
                        if link_cstr == PROC_METADATA_EPOLLFD {
                            return Ok(FileDescriptorInfo::EPollFd);
                        }
                    }
                }
                Self::get_file_info(fd, &stat)
            }
'''
open(p, "w").write(s.replace(old, new))
print("file_descriptors.rs patched")
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

echo " build again with zygote fix"
brunch fogos

echo "making resukisu boot.img"
rm -rf kernel/moto*/sm*
git clone https://github.com/project-moon-gazer/android_kernel_motorola_sm6375.git -b susfs kernel/motorola/sm6375
 cd kernel/moto*/sm*
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

cd ../../..

lunch voltage_fogos-cp2a-user

mka bootimage