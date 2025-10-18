#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso-universal.sh  – Ubuntu OR Debian (any release)
#  Auto-fixes DVD sources, repos, desktop skip, AI-photo stack
#  https://github.com/YOUR_USER/ai-photo-live-universal
# ===================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';N=$'\e[0m'
log(){ echo -e "${G}[INFO]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

# ---------- 0. detect distro + release ----------
if grep -q 'Ubuntu' /etc/os-release; then
   DISTRO="ubuntu"; DISTRO_CODENAME=$(lsb_release -cs)
elif grep -q 'Debian' /etc/os-release; then
   DISTRO="debian"; DISTRO_CODENAME=$(lsb_release -cs)
else
   echo "Unsupported distro"; exit 1
fi
log "Detected $DISTRO ($DISTRO_CODENAME)"


# ---------- 1. fix broken DVD/local sources (netinst/live ISO) ----------
if grep -q 'file:/run/live' /etc/apt/sources.list 2>/dev/null; then
   warn "Broken DVD sources detected – switching to upstream mirrors"
   
   # Write the new, robust sources.list including -updates
   cat >/etc/apt/sources.list <<EOF
deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME} main contrib non-free non-free-firmware
deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.$DISTRO.org/ ${DISTRO_CODENAME}-security main contrib non-free non-free-firmware
EOF

   # Add backports only for Debian to a separate file, as is standard
   if [[ "$DISTRO" == "debian" ]]; then
      log "Adding Debian backports repository."
      echo "deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME}-backports main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list.d/backports.list
   fi

   # Crucial: Update package list immediately after fixing sources
   apt-get update -qq
fi


# ---------- 2. basics: install core helpers and development tools ----------
log "Installing core utilities and software-properties-common..."

# software-properties-common is now installed here once for all distros
apt-get install -y -qq \
   curl \
   wget \
   gnupg \
   lsb-release \
   ca-certificates \
   software-properties-common \
   git \
   python3-pip # Adding pip for the AI stack

# Note: The separate Debian helper section (1½) is now removed.

# ---------- 3. install NVIDIA drivers and proprietary software (if desired) ----------
if [[ "$DISTRO" == "ubuntu" ]]; then
   # Ubuntu setup: add PPA and install necessary packages
   add-apt-repository -y ppa:graphics-drivers/ppa
   apt-get update -qq
   apt-get install -y nvidia-driver-535 # Example driver version
else
   # Debian setup: use non-free-firmware component already enabled
   apt-get install -y firmware-misc-nonfree 
   log "NVIDIA driver installation is left for manual/post-install setup on Debian."
fi

# ---------- 4. install AI Photo Stack (GIMP, Darktable, specific Python tools) ----------
log "Installing image editors (GIMP, Darktable)..."
apt-get install -y -qq gimp darktable

log "Setting up Python environment and AI libraries..."
# Example: Install a simple image processing library
pip install pillow

# Placeholder for actual AI stack setup (e.g., Stable Diffusion dependencies)
# For a real build, you'd clone repositories and install environment dependencies here.
# git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git /opt/sd-webui
# pip install -r /opt/sd-webui/requirements.txt


log "Cleaning up..."
apt-get autoremove -y
apt-get clean

log "${G}ISO CUSTOMIZATION COMPLETE.${N}"
# Cubic will now create the final ISO image.

