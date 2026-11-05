#!/usr/bin/env bash
set -e

REPO_RAW_URL="https://raw.githubusercontent.com/TheAstro9aut/Astro-tun/main"
INSTALL_DIR="/opt/astro-tun"
BIN_PATH="/usr/local/bin/astro-tun"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Please run the installer as root (sudo -i).${NC}"
    exit 1
fi

echo -e "${CYAN}[*] Installing required system packages...${NC}"
if command -v apt-get &>/dev/null; then
    apt-get update -y -qq
    apt-get install -y -qq curl wget unzip jq socat iproute2 netcat-openbsd bc python3 libcap2-bin >/dev/null 2>&1
elif command -v dnf &>/dev/null; then
    dnf install -y -q curl wget unzip jq socat iproute nmap-ncat bc python3 libcap >/dev/null 2>&1
elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm --needed curl wget unzip jq socat iproute2 openbsd-netcat bc python libcap >/dev/null 2>&1
fi

mkdir -p "$INSTALL_DIR"/{log,libs,configs}

echo -e "${CYAN}[*] Downloading Astro Tun wizard...${NC}"
if [[ -f "./astro-tun.sh" ]]; then
    cp "./astro-tun.sh" "$BIN_PATH"
else
    curl -fsSL "$REPO_RAW_URL/astro-tun.sh" -o "$BIN_PATH"
fi

chmod +x "$BIN_PATH"

echo -e "${GREEN}[✓] Astro Tun installed successfully! You can run it anytime by typing: astro-tun${NC}"
sleep 1
exec "$BIN_PATH"
