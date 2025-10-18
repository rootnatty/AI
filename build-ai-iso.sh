#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso.sh  – turn current Ubuntu system (or Cubic chroot)
#  into an AI-photo live ISO with Immich, digiKam, Darktable, etc.
#  https://github.com/YOUR_USER/ai-photo-live
# ===================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# colours
R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';N=$'\e[0m'
log(){ echo -e "${G}[INFO]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

# ---------- 1. basics ----------
log "Updating system"
apt-get update -qq
apt-get install -y -qq curl wget software-properties-common apt-transport-https \
                   ca-certificates gnupg lsb-release

# ---------- 1.5 Install Lightweight Desktop Environment ----------
# ---------- 1½  ultra-light Xfce desktop ----------
log "Installing minimal Xfce"
apt-get install -y xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
                   thunar thunar-archive-plugin mousepad ristretto \
                   arc-theme papirus-icon-theme
systemctl set-default graphical.target


cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=xfce
EOF


# ---------- 2. Docker ----------
log "Installing Docker"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker

# ---------- 3. digiKam ----------
log "Installing digiKam"
apt-get install -y -qq digikam

# ---------- 4. photo / RAW / video tools ----------
log "Installing photo tools"
apt-get install -y -qq darktable rawtherapee hugin imagemagick ffmpeg gimp exiv2 \
                   rclone duplicity testdisk intel-opencl-icd mesa-opencl-icd \
                   systemd-zram-generator

#-------- Cleaning Space ------------
# 1. Uninstall (Purge) some of the largest, non-essential packages installed earlier
apt-get purge -y darktable rawtherapee hugin

# 2. Automatically remove dependencies that are no longer needed
apt-get autoremove -y

# 3. Clear the local repository of downloaded package files
apt-get clean
#------end cleaning 


# ---------- 5. Flatpak ----------
# ---------- 5  Flatpak (skip if inside Cubic chroot) ----------
if [[ -z "${CUBIC_CHROOT:-}" ]] && [[ $(stat -c %d/%i /) != "$(stat -c %d /proc/1/root/.)" ]]; then
    log "Installing Flatpak apps"
    apt-get install -y flatpak
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub org.gnome.FontManager || warn "FontManager install skipped"
else
    warn "Cubic chroot detected – skipping Flatpak to avoid bwrap spam"
fi

# ---------- 6. Python AI utils ----------
log "Installing Python tools"
apt-get install -y -qq python3-pip python3-dev python3-setuptools build-essential
python3 -m pip install --break-system-packages -q \
          ultralytics rembg clip-retrieval

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
log "Creating desktop menu"
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
