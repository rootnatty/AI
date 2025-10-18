#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso-universal.sh  – Ubuntu OR Debian (any release)
#  Auto-fixes DVD sources, repos, desktop skip, full AI-photo stack
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
log "Refreshing package lists for core utilities"
apt-get update -qq # CRITICAL: Rerunning update to guarantee lists are loaded after source fixes
log "Installing core utilities"
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates software-properties-common apt-transport-https

# ---------- 3. desktop (skip if any DE already installed) ----------
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
      apt-get install -y xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
                         thunar-archive-plugin mousepad ristretto arc-theme papirus-icon-theme
   else  # debian
      apt-get install -y task-xfce-desktop lightdm
   fi
   systemctl set-default graphical.target
   cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=${DISTRO}
autologin-user-timeout=0
user-session=xfce
EOF
fi

# ---------- 4. Docker (distro-aware) ----------
log "Installing Docker"

# The package apt-transport-https is moved up to section 2 for consistency.

# Set up the official Docker repository for both Debian and Ubuntu
DOCKER_BASE_URL="https://download.docker.com/linux/${DISTRO}"
DOCKER_GPG_KEY="/usr/share/keyrings/docker.gpg"

curl -fsSL ${DOCKER_BASE_URL}/gpg | gpg --dearmor -o "${DOCKER_GPG_KEY}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_GPG_KEY}] \
      ${DOCKER_BASE_URL} ${DISTRO_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

apt-get update -qq

# Install Docker components
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker

# ---------- 5. digiKam ----------
apt-get install -y -qq digikam

# ---------- 6. light photo tools ----------
log "Installing light photo tools"
apt-get install -y -qq imagemagick ffmpeg gimp exiv2 rclone duplicity testdisk \
                   mesa-opencl-icd systemd-zram-generator

# ---------- 7. Flatpak (skip inside Cubic) ----------
if [[ -z "${CUBIC_CHROOT:-}" ]] && [[ $(stat -c %d/%i /) != "$(stat -c %d /proc/1/root/.)" ]]; then
   apt-get install -y flatpak
   flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
   flatpak install -y flathub org.gnome.FontManager || true
fi

# ---------- 8. Python AI utils (venv on Debian, system on Ubuntu) ----------
log "Installing Python tools"
if [[ "$DISTRO" == "ubuntu" ]]; then
   apt-get install -y -qq python3-pip python3-dev python3-setuptools build-essential
   python3 -m pip install --break-system-packages -q ultralytics rembg clip-retrieval
else  # debian
   apt-get install -y -qq python3-venv python3-dev build-essential
   python3 -m venv /opt/ai-venv
   /opt/ai-venv/bin/pip install -q ultralytics rembg clip-retrieval
   ln -sf /opt/ai-venv/bin/{ultralytics,rembg,clip-retrieval} /usr/local/bin/
fi

# ---------- 9. models ----------
mkdir -p /usr/share/ai-models
wget -q https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.onnx \
      -O /usr/share/ai-models/yolov8n.onnx
wget -q https://openaipublic.azureedge.net/clip/models/40d365715913c9da98579312b702a82c18be219cc2a73407c45252f58cba95ac/ViT-B-32.pt \
      -O /usr/share/ai-models/ViT-B-32.pt

# ---------- 10. Immich ----------
mkdir -p /opt/immich && cd /opt/immich
wget -q https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -q https://github.com/immich-app/immich/releases/latest/download/example.env -O .env
docker compose pull

# ---------- 11. systemd service ----------
cat >/etc/systemd/system/immich-live.service <<'EOF'
[Unit]
Description=Immich photo stack (live ISO)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/immich
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
systemctl enable immich-live.service

# ---------- 12. CompreFace ----------
docker pull exadel/compreface:1.2.0

# ---------- 13. AppImage ----------
wget -qO /opt/Upscayl.AppImage \
         https://github.com/upscayl/upscayl/releases/download/v2.9.1/upscayl-2.9.1-linux.AppImage
chmod +x /opt/*.AppImage

# ---------- 14. user menu ----------
cat >/usr/local/bin/ai-photo-menu <<'EOF'
#!/bin/bash
zenity --list --title="AI Photo Workshop" --column=Tool --column=Description \
  "Immich" "Web AI manager – face & CLIP search (http://localhost:2283)" \
  "digiKam" "Desktop organiser – face + geo" \
  "Upscayl" "4× AI upscaler (AppImage)" \
  "darktable" "RAW developer" \
  "CompreFace" "Advanced face API (http://localhost:8000)"
EOF
chmod +x /usr/local/bin/ai-photo-menu
mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/ai-photo-menu.desktop <<EOF
[Desktop Entry]
Type=Application
Name=AI Photo Workshop
Exec=ai-photo-menu
Terminal=false
EOF

# ---------- 15. cleanup ----------
apt-get autoremove -y -qq
apt-get clean
rm -rf /tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
history -c
log "All done – close this terminal and build the ISO in Cubic"

