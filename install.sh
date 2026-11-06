#!/usr/bin/env bash
set -e

REPO_RAW_URL="https://raw.githubusercontent.com/TheAstro9aut/Waterwall-Manager/main"
INSTALL_DIR="/opt/waterwall-manager"
BIN_PATH="/usr/local/bin/wwmng"
TMP_DL=""

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup_install() {
    echo -e "\n${RED}[!] Installation interrupted by user (Ctrl+C). Rolling back...${NC}"
    if [[ -n "$TMP_DL" && -f "$TMP_DL" ]]; then
        rm -f "$TMP_DL"
    fi
    exit 130
}
trap cleanup_install INT TERM

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Please run the installer as root (sudo -i).${NC}"
    exit 1
fi

rm -f /usr/local/bin/astro-tun 2>/dev/null

echo -e "${CYAN}[*] Installing required system packages...${NC}"
if command -v apt-get &>/dev/null; then
    apt-get update -y -qq
    apt-get install -y -qq curl wget unzip jq socat iproute2 iptables netcat-openbsd bc python3 libcap2-bin >/dev/null 2>&1
elif command -v dnf &>/dev/null; then
    dnf install -y -q curl wget unzip jq socat iproute iptables nmap-ncat bc python3 libcap >/dev/null 2>&1
elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm --needed curl wget unzip jq socat iproute2 iptables openbsd-netcat bc python libcap >/dev/null 2>&1
fi

mkdir -p "$INSTALL_DIR"/{log,libs,configs,results,transports}

echo -e "${CYAN}[*] Downloading Waterwall-Manager (wwmng) and transports...${NC}"
TMP_DL=$(mktemp)
if [[ -f "./wwmng.sh" ]]; then
    cp "./wwmng.sh" "$BIN_PATH"
else
    curl -fsSL "$REPO_RAW_URL/wwmng.sh" -o "$TMP_DL"
    mv -f "$TMP_DL" "$BIN_PATH"
fi
chmod +x "$BIN_PATH"

if [[ -f "./transports/bitswapmux.sh" ]]; then
    cp "./transports/bitswapmux.sh" "$INSTALL_DIR/transports/bitswapmux.sh"
    chmod +x "$INSTALL_DIR/transports/bitswapmux.sh"
else
    if curl -fsSL "$REPO_RAW_URL/transports/bitswapmux.sh" -o "$INSTALL_DIR/transports/bitswapmux.sh" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/transports/bitswapmux.sh"
    fi
fi

echo -e "${GREEN}[✓] Waterwall-Manager installed! Run it anytime by typing: wwmng${NC}"
sleep 1
exec "$BIN_PATH"
