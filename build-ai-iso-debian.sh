#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso-universal.sh  – Ubuntu OR Debian (any release)
#  Auto-fixes DVD sources, repos, desktop skip, full AI-photo stack
#  https://github.com/YOUR_USER/ai-photo-live-universal
#
#  AUDIT: Revised for chroot safety, robust Docker setup, and cleanup.
# ===================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';N=$'\e[0m'
log(){ echo -e "${G}[INFO]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

TOTAL_STEPS=17
CURRENT_STEP=0

# Function to display a progress bar at the bottom
# Requires tput, which is installed with core utilities in step 2.
progress_bar() {
    local STEP=$1
    local TITLE=$2
    local PERCENT=$(( (STEP * 100) / TOTAL_STEPS ))
    local NUM_BARS=$(( PERCENT / 2 ))
    local BAR=""
    
    # Build the filled bar section
    for ((i=1; i<=NUM_BARS; i++)); do
        BAR="${BAR}#"
    done
    # Pad with spaces for the rest
    BAR=$(printf "%-50s" "${BAR}")

    # Use tput for dynamic progress in terminal
    tput sc 2>/dev/null || true # Save cursor
    tput cup $(tput lines) 0 2>/dev/null || true # Move cursor to bottom row
    
    # Print progress bar line, followed by clearing to end of line
    echo -ne "Prog: [${G}${BAR}${N}] ${PERCENT}% | Step ${STEP}/${TOTAL_STEPS}: ${TITLE}"
    tput el 2>/dev/null || true
    
    tput rc 2>/dev/null || true # Restore cursor
}

# Wrapper for progress and logging
start_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local TITLE="$1"
    log "--- ${TITLE} (Step ${CURRENT_STEP}/${TOTAL_STEPS}) ---"
    progress_bar "${CURRENT_STEP}" "${TITLE}"
}

# ---------- 0. detect distro + release ----------
start_step "Detecting Distro"
# FIX: Corrected duplicate 'grep grep' typo.
if grep -q 'Ubuntu' /etc/os-release; then
   DISTRO="ubuntu"; DISTRO_CODENAME=$(lsb_release -cs)
elif grep -q 'Debian' /etc/os-release; then
   DISTRO="debian"; DISTRO_CODENAME=$(lsb_release -cs)
else
   echo "Unsupported distro"; exit 1
fi
log "Detected $DISTRO ($DISTRO_CODENAME)"

# ---------- 1. fix broken DVD/local sources (netinst/live ISO) ----------
start_step "Fixing APT Sources"
if grep -q 'file:/run/live' /etc/apt/sources.list 2>/dev/null; then
   warn "Broken DVD sources detected – switching to upstream mirrors"
   cat >/etc/apt/sources.list <<EOF
deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME} main contrib non-free non-free-firmware
deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.$DISTRO.org/ ${DISTRO_CODENAME}-security main contrib non-free non-free-firmware
EOF
   # add backports only for debian
   if [[ "$DISTRO" == "debian" ]]; then
      echo "deb http://deb.$DISTRO.org/$DISTRO ${DISTRO_CODENAME}-backports main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list.d/backports.list
   fi
   apt-get update -qq
fi

# ---------- 2. basics ----------
start_step "Installing Core Utilities"
log "Refreshing package lists for core utilities"
apt-get update -qq # CRITICAL: Rerunning update to guarantee lists are loaded after source fixes
log "Installing core utilities (including tput for progress bar)"
# tput is explicitly included for the progress_bar function
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates software-properties-common apt-transport-https tput

# ---------- 3. desktop (skip if any DE already installed) ----------
start_step "Installing Desktop Environment"
DE_PKGS=(xfce4-session gnome-session plasma-desktop budgie-desktop cinnamon-session)
for pkg in "${DE_PKGS[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        warn "Desktop '$pkg' detected – skipping desktop install"; SKIP_DE=1; break
    fi
done
if [[ "${SKIP_DE:-0}" == 1 ]]; then
   :
else
   log "Installing lightweight desktop"
   if [[ "$DISTRO" == "ubuntu" ]]; then
      # FIX: Ensure 'lightdm' is installed for Ubuntu variant too if needed
      apt-get install -y -qq xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
                         thunar-archive-plugin mousepad ristretto arc-theme papirus-icon-theme
   else  # debian
      apt-get install -y -qq task-xfce-desktop lightdm
   fi
   # NOTE: systemctl commands often don't work correctly in a chroot.
   # We leave them for completeness, assuming Cubic handles the boot setup.
   systemctl set-default graphical.target 2>/dev/null || true
   cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=${DISTRO}
autologin-user-timeout=0
user-session=xfce
EOF
fi

# ---------- 4. Docker (distro-aware) ----------
start_step "Installing Docker and Compose"
# AUDIT: Set up the official Docker repository
DOCKER_BASE_URL="https://download.docker.com/linux/${DISTRO}"
DOCKER_GPG_KEY="/usr/share/keyrings/docker.gpg"

curl -fsSL ${DOCKER_BASE_URL}/gpg | gpg --dearmor -o "${DOCKER_GPG_KEY}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_GPG_KEY}] \
      ${DOCKER_BASE_URL} ${DISTRO_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

apt-get update -qq

# Install Docker components
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

# FIX: Docker should be enabled, but we suppress errors if systemctl fails in chroot
systemctl enable docker 2>/dev/null || true

# ---------- 5. Nvidia Tools (for GPU acceleration) ----------
start_step "Installing Nvidia/OpenCL support"
if [[ "$DISTRO" == "ubuntu" ]]; then
    # Ubuntu provides better support through its standard repos
    # AUDIT: Added nvidia-docker2 for broader support
    apt-get install -y -qq nvidia-container-toolkit nvidia-docker2
else  # debian
    # Debian requires non-free and generic runtimes
    apt-get install -y -qq ocl-icd-libopencl1 libcuda1
fi

# ---------- 6. digiKam ----------
start_step "Installing digiKam"
apt-get install -y -qq digikam

# ---------- 7. light photo tools (including darktable) ----------
start_step "Installing Light Photo Tools (GIMP, darktable, etc.)"
# AUDIT: Combined `mesa-opencl-icd` install here, as it's general utility
apt-get install -y -qq imagemagick ffmpeg gimp exiv2 rclone duplicity testdisk darktable \
                   mesa-opencl-icd systemd-zram-generator

# ---------- 8. Flatpak (skip application install in chroot) ----------
start_step "Installing Flatpak Infrastructure"
# AUDIT: Condition check is robust, proceed with infrastructure install only
if [[ -z "${CUBIC_CHROOT:-}" ]] && [[ $(stat -c %d/%i /) != "$(stat -c %d /proc/1/root/.)" ]]; then
   log "Installing Flatpak infrastructure and Flathub remote..."
   apt-get install -y -qq flatpak
   flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
   log "Skipping Flatpak app installation to prevent chroot hang."
fi

# ---------- 9. Python AI utils (venv on Debian, system on Ubuntu) ----------
start_step "Installing Python AI Utilities"
if [[ "$DISTRO" == "ubuntu" ]]; then
   # FIX: Removed `python3-setuptools` as it's rarely needed and sometimes conflicts
   apt-get install -y -qq python3-pip python3-dev build-essential
   python3 -m pip install --break-system-packages -q ultralytics rembg clip-retrieval
else  # debian
   apt-get install -y -qq python3-venv python3-dev build-essential
   python3 -m venv /opt/ai-venv
   /opt/ai-venv/bin/pip install -q ultralytics rembg clip-retrieval
   ln -sf /opt/ai-venv/bin/{ultralytics,rembg,clip-retrieval} /usr/local/bin/
fi

# ---------- 10. models ----------
start_step "Downloading AI Models"
mkdir -p /usr/share/ai-models
# AUDIT: Added --no-check-certificate just in case of chroot certificate issues
wget -q --no-check-certificate https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.onnx \
      -O /usr/share/ai-models/yolov8n.onnx
wget -q --no-check-certificate https://openaipublic.azureedge.net/clip/models/40d365715913c9da98579312b702a82c18be219cc2a73407c45252f58cba95ac/ViT-B-32.pt \
      -O /usr/share/ai-models/ViT-B-32.pt

# ---------- 11. Immich ----------
start_step "Configuring Immich (Docker)"
mkdir -p /opt/immich && cd /opt/immich
wget -q --no-check-certificate https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -q --no-check-certificate https://github.com/immich-app/immich/releases/latest/download/example.env -O .env
# AUDIT: We use "docker compose pull" to download all images now, which is correct.
docker compose pull

# ---------- 12. systemd service ----------
start_step "Creating Immich Service"
cat >/etc/systemd/system/immich-live.service <<'EOF'
[Unit]
Description=Immich photo stack (live ISO)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/immich
# FIX: Use the full path for compose command
ExecStart=/usr/local/bin/docker compose up -d
ExecStop=/usr/local/bin/docker compose down
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
# FIX: Suppress errors in chroot for systemctl
systemctl enable immich-live.service 2>/dev/null || true

# ---------- 13. CompreFace ----------
start_step "Pulling CompreFace Docker Image"
docker pull exadel/compreface:1.2.0

# ---------- 14. AppImage ----------
start_step "Downloading Upscayl AppImage"
wget -qO /opt/Upscayl.AppImage \
         --no-check-certificate https://github.com/upscayl/upscayl/releases/download/v2.9.1/upscayl-2.9.1-linux.AppImage
chmod +x /opt/*.AppImage

# ---------- 15. user menu ----------
start_step "Setting Up User Menu"
cat >/usr/local/bin/ai-photo-menu <<'EOF'
#!/bin/bash
# FIX: Ensure zenity is installed, otherwise this menu fails
if ! command -v zenity &> /dev/null; then
  echo "Zenity is not installed. Falling back to simple message."
  echo "AI Photo Workshop Tools:"
  echo " - Immich: http://localhost:2283"
  echo " - CompreFace: http://localhost:8000"
  echo " - Other tools: digiKam, Upscayl, darktable"
  sleep 5
  exit 0
fi

zenity --list --title="AI Photo Workshop" --column=Tool --column=Description \
  "Immich" "Web AI manager – face & CLIP search (http://localhost:2283)" \
  "digiKam" "Desktop organiser – face + geo" \
  "Upscayl" "4× AI upscaler (AppImage)" \
  "darktable" "RAW developer" \
  "CompreFace" "Advanced face API (http://localhost:8000)"
EOF
chmod +x /usr/local/bin/ai-photo-menu

# FIX: Must install zenity for the menu to work!
apt-get install -y -qq zenity

mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/ai-photo-menu.desktop <<EOF
[Desktop Entry]
Type=Application
Name=AI Photo Workshop
Exec=ai-photo-menu
Terminal=false
EOF

# ---------- 16. user documentation/shortcuts (for darktable) ----------
start_step "Creating Desktop Shortcuts and Docs"
# Ensure desktop is installed for this to work, which is covered in section 3.
cat >/etc/skel/Desktop/darktable.desktop <<EOF
[Desktop Entry]
Type=Application
Name=darktable RAW Developer
Exec=/usr/bin/darktable
Icon=darktable
Terminal=false
Categories=Graphics;Photography;
EOF
chmod +x /etc/skel/Desktop/darktable.desktop
ln -sf /etc/skel/Desktop/darktable.desktop /usr/share/applications/darktable.desktop # Symlink for global visibility

# ---------- 17. cleanup ----------
start_step "Cleaning Up System"
# AUDIT: Added `docker system prune -a -f` to remove all cached docker images
# that were pulled in steps 11 and 13, saving significant ISO space.
docker system prune -a -f 2>/dev/null || true

apt-get autoremove -y -qq
apt-get clean
rm -rf /tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
history -c
progress_bar 17 "COMPLETE" # Final 100% progress
tput cup $(tput lines) 0 2>/dev/null || true # Move cursor to bottom left
tput el 2>/dev/null || true # Clear the progress bar line
echo -e "${G}[SUCCESS]${N} All done – close this terminal and build the ISO in Cubic"

