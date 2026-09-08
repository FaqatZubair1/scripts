#!/bin/bash
echo "======= Remove Project ========="

rm -rf .repo/local_manifests
rm -rf kernel/*
rm -rf device/*
rm -rf vendor/*
rm -rf hardware/*
rm -rf out/soong
rm -rf prebuilt/gcc

echo "======= Remove Done ======"
# Rom source repo
        repo init -u https://github.com/VoltageOS/manifest.git -b 17 --git-lfs
        
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

echo "=================="
echo " Exports Done "
echo "=================="
cd v*/v*/ke*
bash ./keys.sh
cd ../../..
# Set up build environment
. b*/env*
# Clean
make clean

echo "=================="
echo "Building Rom"
echo "=================="

# Build rom
brunch fogos -j4
