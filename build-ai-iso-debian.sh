#!/usr/bin/env bash
# ===================================================================
#  build-ai-iso-universal.sh  – Ubuntu OR Debian inside Cubic chroot
#  Detects distro, repo, desktop presence; installs AI-photo stack
#  https://github.com/YOUR_USER/ai-photo-live-universal
# ===================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';N=$'\e[0m'
log(){ echo -e "${G}[INFO]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

# ---------- 0. detect distro ----------
if grep -q 'Ubuntu' /etc/os-release; then
   DISTRO="ubuntu"; DISTRO_CODENAME=$(lsb_release -cs)
elif grep -q 'Debian' /etc/os-release; then
   DISTRO="debian"; DISTRO_CODENAME=$(lsb_release -cs)
else
   echo "Unsupported distro"; exit 1
fi
log "Detected $DISTRO ($DISTRO_CODENAME)"

# ---------- 1. basics ----------
log "Updating system"
apt-get update -qq
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates software-properties-common

# ---------- 1½  desktop (skip if any major DE already installed) ----------
DE_PKGS=(xfce4-session gnome-session plasma-desktop budgie-desktop cinnamon-session)
for pkg in "${DE_PKGS[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        warn "Desktop environment '$pkg' already installed – skipping desktop install"
        SKIP_DE=1; break
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

# ---------- 2. Docker (distro-specific) ----------
log "Installing Docker"
if [[ "$DISTRO" == "ubuntu" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu ${DISTRO_CODENAME} stable" \
          > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
else  # debian
    # enable backports only if they exist
    if curl -s "http://deb.debian.org/debian/dists/${DISTRO_CODENAME}-backports" | grep -q 'Release'; then
        echo "deb http://deb.debian.org/debian ${DISTRO_CODENAME}-backports main contrib non-free" \
             > /etc/apt/sources.list.d/backports.list
        apt-get update -qq
        apt-get install -y -qq -t "${DISTRO_CODENAME}-backports" docker.io docker-compose-plugin
    else
        apt-get install -y -qq docker.io docker-compose-plugin
    fi
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

# ---------- 6. Python AI utils ----------
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
