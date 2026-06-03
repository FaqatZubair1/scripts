#!/bin/bash

# Rom source repo
repo init --depth=1 --no-repo-verify --git-lfs -u https://github.com/Lunaris-AOSP/android -b 16.2 -g default,-mips,-darwin,-notdefault

echo "=================="
echo "Repo init success"
echo "=================="

echo "===== Sync the repositories ========"

/opt/crave/resync.sh

echo "======== Syncing Done =========="

echo "======= Remove Project ========="

rm -rf .repo/local_manifests
rm -rf kernel/motorola
rm -rf device/motorola
rm -rf vendor/motorola

echo "======= Remove Done ======"

git clone --depth=1 https://github.com/FaqatZubair1/Lineage_android_device_motorola_fogos.git -b luna device/motorola/fogos
git clone --depth=1 https://github.com/FaqatZubair1/Lineage_android_device_motorola_sm6375-common.git -b 16.2 device/motorola/sm6375-common
git clone --depth=1 https://github.com/FaqatZubair1/Lineage_android_vendor_motorola_fogos.git -b 16.2 vendor/motorola/fogos
git clone --depth=1 https://github.com/FaqatZubair1/Lineage_android_vendor_motorola_sm6375-common.git -b 16.2 vendor/motorola/sm6375-common
git clone --depth=1 https://github.com/JNWSG/Lineage_android_kernel_motorola_sm6375.git -b 16.2 kernel/motorola/sm6375

echo "=================="
echo "Cloning Done"
echo "=================="

# Exports
export BUILD_USERNAME=agony
export BUILD_HOSTNAME=CraveCloud
export TZ=Asia/Bishkek

echo "=================="
echo " Exports Done "
echo "=================="

# Set up build environment
. b*/env*
echo "====== Envsetup Done ======="

# Lunch
lunch lineage_fogos-bp4a-user
echo "============="

# Clean
make installclean

echo "=================="
echo "Building Rom"
echo "=================="

# Build rom
m bacon
