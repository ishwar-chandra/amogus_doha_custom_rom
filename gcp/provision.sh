#!/usr/bin/env bash
# Run ON the GCP VM. Installs Android 16 build dependencies and 32 GB swap.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    SUDO=sudo
else
    SUDO=
fi

$SUDO apt-get update
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs \
    gnupg gperf imagemagick lib32ncurses-dev lib32readline-dev lib32z1-dev \
    liblz4-tool libncurses6 libncurses-dev libsdl1.2-dev libssl-dev \
    libwxgtk3.2-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev python3 tmux htop

# 32 GB swap as an OOM safety net on 48 GB RAM.
if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
    if [ ! -f /swapfile ]; then
        $SUDO fallocate -l 32G /swapfile 2>/dev/null \
            || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=32768 status=progress
        $SUDO chmod 600 /swapfile
        $SUDO mkswap /swapfile
    fi
    $SUDO swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab

printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' | $SUDO tee /etc/sysctl.d/99-doha-build.conf >/dev/null
$SUDO sysctl --system >/dev/null

git config --global user.name "${GIT_NAME:-Ishwar-Chandra}"
git config --global user.email "${GIT_EMAIL:-ishwarchandra.official@gmail.com}"
git lfs install >/dev/null 2>&1 || true

echo
echo "== provisioned =="
nproc
free -h
df -h /
git config --global --get user.name
git config --global --get user.email
