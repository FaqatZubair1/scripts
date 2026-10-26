#!/bin/bash
echo "======= Remove Project ========="

rm -rf .repo/local_manifests
rm -rf kernel/*
rm -rf device/*
rm -rf vendor/*
rm -rf hardware/*
echo "===== reset leftover patches ====="
git -C system/zygote checkout -- . 2>/dev/null || true
git -C system/sepolicy checkout -- . 2>/dev/null || true


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
echo "adding resukisu"
rm -rf kernel/moto*/sm*
git clone https://github.com/project-moon-gazer/android_kernel_motorola_sm6375.git -b susfs kernel/motorola/sm6375
cd kernel/moto*/sm*
rm -rf KernelSU
git clone --depth=1 https://github.com/Baka-SU/BakaSU KernelSU
[ -f KernelSU/kernel/Kconfig ] || { echo "!!! KernelSU missing"; exit 1; }
cd ../../..

brunch fogos
