#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso-debian-universal.sh  – Debian-universal edition
#  Works on Debian ≥ 10 (Buster) and inside Cubic chroots
#  https://github.com/YOUR_USER/ai-photo-live-debian-universal
# ===================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';N=$'\e[0m'
log(){ echo -e "${G}[INFO]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

# ---------- 0. discover Debian release ----------
DEB_CODENAME=$(lsb_release -cs)
DEB_VERSION=$(lsb_release -sr | cut -d. -f1)
log "Detected Debian $DEB_CODENAME (v$DEB_VERSION)"

# ---------- 1. basics ----------
log "Updating system"
# add backports only if it exists for this release
if curl -s "http://deb.debian.org/debian/dists/${DEB_CODENAME}-backports" | grep -q 'Release'; then
    log "Enabling ${DEB_CODENAME}-backports"
    echo "deb http://deb.debian.org/debian ${DEB_CODENAME}-backports main contrib non-free" \
         > /etc/apt/sources.list.d/backports.list
fi
apt-get update -qq
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates

# ---------- 1½  desktop ----------
log "Installing Xfce desktop"
# task-xfce-desktop exists on every Debian ≥ 10
apt-get install -y task-xfce-desktop lightdm
systemctl set-default graphical.target
cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=debian
autologin-user-timeout=0
user-session=xfce
EOF

# ---------- 2. Docker ----------
if [[ -f /etc/apt/sources.list.d/backports.list ]]; then
    log "Installing Docker from ${DEB_CODENAME}-backports"
    apt-get install -y -qq -t "${DEB_CODENAME}-backports" docker.io docker-compose-plugin
else
    log "Installing Docker from regular repo"
    apt-get install -y -qq docker.io docker-compose-plugin
fi
systemctl enable docker

# ---------- 3. digiKam ----------
log "Installing digiKam"
apt-get install -y -qq digikam

# ---------- 4. light photo tools ----------
log "Installing light photo tools"
apt-get install -y -qq imagemagick ffmpeg gimp exiv2 rclone duplicity testdisk \
                   mesa-opencl-icd systemd-zram-generator

# ---------- 5. Flatpak (skip inside Cubic) ----------
if [[ -z "${CUBIC_CHROOT:-}" ]] && [[ $(stat -c %d/%i /) != "$(stat -c %d /proc/1/root/.)" ]]; then
    log "Installing Flatpak apps"
    apt-get install -y flatpak
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub org.gnome.FontManager || warn "FontManager install skipped"
else
    warn "Cubic chroot detected – skipping Flatpak to avoid bwrap spam"
fi

# ---------- 6. Python AI utils (venv, no --break-system-packages) ----------
log "Installing Python tools"
apt-get install -y -qq python3-venv python3-dev build-essential
python3 -m venv /opt/ai-venv
/opt/ai-venv/bin/pip install -q ultralytics rembg clip-retrieval
ln -sf /opt/ai-venv/bin/{ultralytics,rembg,clip-retrieval} /usr/local/bin/

# ---------- 7. models ----------
log "Downloading AI models"
mkdir -p /usr/share/ai-models
wget -q https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.onnx \
      -O /usr/share/ai-models/yolov8n.onnx
wget -q https://openaipublic.azureedge.net/clip/models/40d365715913c9da98579312b702a82c18be219cc2a73407c45252f58cba95ac/ViT-B-32.pt \
      -O /usr/share/ai-models/ViT-B-32.pt

# ---------- 8. Immich ----------
log "Setting up Immich"
mkdir -p /opt/immich && cd /opt/immich
wget -q https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -q https://github.com/immich-app/immich/releases/latest/download/example.env -O .env
docker compose pull

# ---------- 9. systemd service ----------
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

# ---------- 10. CompreFace ----------
log "Pulling CompreFace face-api"
docker pull exadel/compreface:1.2.0

# ---------- 11. AppImage ----------
log "Downloading Upscayl"
wget -qO /opt/Upscayl.AppImage \
         https://github.com/upscayl/upscayl/releases/download/v2.9.1/upscayl-2.9.1-linux.AppImage
chmod +x /opt/*.AppImage

# ---------- 12. user menu ----------
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

# ---------- 13. cleanup ----------
log "Cleaning up"
apt-get autoremove -y -qq
apt-get clean
rm -rf /tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
history -c
log "All done – close this terminal and build the ISO in Cubic"
