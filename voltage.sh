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
echo "===build complete==="
cd kernel/motorola/sm6375
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main
# Append the KSU configs to activate the C hooks you pushed to GitHub
echo -e "\nCONFIG_KSU=y\nCONFIG_KSU_MANUAL_HOOK=y" >> arch/arm64/configs/vendor/holi-qgki_defconfig
cd ../../..

mka bootimage

echo "=== Rooted Boot Image Complete ==="
