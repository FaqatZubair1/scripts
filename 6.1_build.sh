#!/bin/bash

# Rom source repo
ROM_MANIFEST="https://github.com/VoltageOS/manifest.git"
ROM_BRANCH="17"

# Local manifest
LOCAL_MANIFEST_URL="https://raw.githubusercontent.com/FaqatZubair1/scripts/main/local_manifest.xml"

echo "======= Remove old local manifests ========="
rm -rf .repo/local_manifests
echo "======= Remove Done ======"

repo init -u "$ROM_MANIFEST" -b "$ROM_BRANCH" --git-lfs --depth=1
echo "Repo init success"

echo "===== Adding local manifest ====="
mkdir -p .repo/local_manifests
curl -fsSL -o .repo/local_manifests/local_manifest.xml "$LOCAL_MANIFEST_URL"
echo "Local manifest added"

echo "===== Sync the repositories ========"
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync --depth=1 -j$(nproc --all)
echo "======== Syncing Done =========="

echo " generating keys "
cd v*/v*/ke*
bash ./keys.sh
cd ../../..

# Set up build environment
. build/envsetup.sh

echo "=================="
echo "Building Rom"
echo "=================="

# Build rom
brunch fogos
