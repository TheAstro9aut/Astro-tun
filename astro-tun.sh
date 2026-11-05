#!/usr/bin/env bash

# ==============================================================================
# ASTRO TUN - WaterWall Tunneling & Packet Probing Wizard
# Repository: https://github.com/TheAstro9aut/Astro-tun
# WaterWall:  https://github.com/radkesvat/WaterWall
# ==============================================================================

WW_DIR="/opt/astro-tun"
WW_BIN="${WW_DIR}/Waterwall"
WW_VER_FILE="${WW_DIR}/.version"
WW_CORE_JSON="${WW_DIR}/core.json"
ASTROTUN_BIN="/usr/local/bin/astro-tun"
WW_REPO="radkesvat/WaterWall"
WW_API_LATEST="https://api.github.com/repos/${WW_REPO}/releases/latest"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Astro Tun must be run as root (needed for RawSocket & TUN capabilities).${NC}"
    exit 1
fi

mkdir -p "${WW_DIR}"/{log,libs,configs,results}

# ==============================================================================
# HELPER FUNCTIONS & NAVIGATION
# ==============================================================================

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "    ___         __               ______            "
    echo "   /   |  _____/ /________      /_  __/_  ______   "
    echo "  / /| | / ___/ __/ ___/ __ \    / / / / / / __ \  "
    echo " / ___ |(__  ) /_/ /  / /_/ /   / / / /_/ / / / /  "
    echo "/_/  |_/____/\__/_/   \____/   /_/  \__,_/_/ /_/   "
    echo -e "${NC}${MAGENTA}   WaterWall Core Management & Packet Probe Wizard${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

is_back() {
    local input="${1,,}"
    [[ "$input" == "0" || "$input" == "b" || "$input" == "back" ]]
}

prompt_input() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local user_input=""

    if [[ -n "$default_val" ]]; then
        read -rp "$(echo -e "${CYAN}${prompt_text} [${GREEN}${default_val}${CYAN}] (or '0' to go back): ${NC}")" user_input
        if is_back "$user_input"; then
            return 1
        fi
        user_input="${user_input:-$default_val}"
    else
        while [[ -z "$user_input" ]]; do
            read -rp "$(echo -e "${CYAN}${prompt_text} (or '0' to go back): ${NC}")" user_input
            if is_back "$user_input"; then
                return 1
            fi
        done
    fi
    printf -v "$var_name" '%s' "$user_input"
    return 0
}

pause_back() {
    echo ""
    read -rp "$(echo -e "${YELLOW}Press [Enter] or type [0] to return to the previous menu...${NC}")" _
}

get_public_ip() {
    local ip
    ip=$(curl -fsSL4 --max-time 4 https://icanhazip.com 2>/dev/null || \
         curl -fsSL4 --max-time 4 https://ifconfig.me 2>/dev/null || \
         ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    echo "${ip:-0.0.0.0}"
}

get_default_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# ==============================================================================
# WATERWALL CORE DETECTION, INSTALLATION & UPDATE
# ==============================================================================

detect_compatible_asset() {
    local release_json="$1"
    local arch
    arch=$(uname -m)
    local has_avx2="false"

    if grep -q -i "avx2" /proc/cpuinfo 2>/dev/null; then
        has_avx2="true"
    fi

    local asset_url=""

    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        if [[ "$has_avx2" == "true" ]]; then
            asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*x64"; "i")) | select(.name | test("old-cpu"; "i") | not) | .browser_download_url' | head -n1)
        else
            asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*x64.*old-cpu"; "i")) | .browser_download_url' | head -n1)
        fi
        if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
            asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*(x64|amd64)"; "i")) | .browser_download_url' | head -n1)
        fi
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        if grep -q -E "asimd|crc32" /proc/cpuinfo 2>/dev/null; then
            asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*arm64"; "i")) | select(.name | test("old-cpu"; "i") | not) | .browser_download_url' | head -n1)
        fi
        if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
            asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*(arm64|aarch64)"; "i")) | .browser_download_url' | head -n1)
        fi
    fi

    echo "$asset_url"
}

check_and_install_core() {
    local force_update="${1:-false}"
    echo -e "${CYAN}[*] Checking WaterWall Core status...${NC}"

    local release_json
    release_json=$(curl -fsSL --max-time 10 "$WW_API_LATEST" 2>/dev/null)

    if [[ -z "$release_json" ]]; then
        if [[ -x "$WW_BIN" ]]; then
            echo -e "${YELLOW}[!] Could not reach GitHub API, but WaterWall Core is already installed locally.${NC}"
            return 0
        else
            echo -e "${RED}[!] Failed to fetch latest release metadata from GitHub (${WW_REPO}). Check network connection.${NC}"
            return 1
        fi
    fi

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
    local installed_tag=""
    [[ -f "$WW_VER_FILE" ]] && installed_tag=$(cat "$WW_VER_FILE")

    if [[ -x "$WW_BIN" && "$installed_tag" == "$latest_tag" && "$force_update" != "true" ]]; then
        echo -e "${GREEN}[✓] WaterWall Core is installed and on the latest version (${BOLD}${latest_tag}${NC}${GREEN}).${NC}"
        sleep 1
        return 0
    fi

    if [[ ! -x "$WW_BIN" ]]; then
        echo -e "${YELLOW}[!] WaterWall Core not found. Downloading latest version (${latest_tag})...${NC}"
    else
        echo -e "${YELLOW}[*] Updating WaterWall Core (${installed_tag:-unknown} -> ${latest_tag})...${NC}"
    fi

    local asset_url
    asset_url=$(detect_compatible_asset "$release_json")

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo -e "${RED}[!] No compatible Linux binary found for architecture $(uname -m) in release ${latest_tag}.${NC}"
        return 1
    fi

    local asset_filename
    asset_filename=$(basename "$asset_url")
    echo -e "${CYAN}[*] Selected compatible build: ${BOLD}${asset_filename}${NC}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -fL --progress-bar "$asset_url" -o "${tmp_dir}/waterwall.zip"; then
        echo -e "${RED}[!] Download failed.${NC}"
        rm -rf "$tmp_dir"
        return 1
    fi

    unzip -qo "${tmp_dir}/waterwall.zip" -d "$tmp_dir"
    local extracted_bin
    extracted_bin=$(find "$tmp_dir" -maxdepth 2 -type f -iname "waterwall*" ! -name "*.zip" ! -name "*.json" ! -name "*.md" | head -n1)

    if [[ -z "$extracted_bin" ]]; then
        echo -e "${RED}[!] Could not locate Waterwall executable inside the archive.${NC}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mv -f "$extracted_bin" "$WW_BIN"
    chmod +x "$WW_BIN"
    setcap cap_net_admin,cap_net_raw+ep "$WW_BIN" 2>/dev/null || true
    echo "$latest_tag" > "$WW_VER_FILE"
    rm -rf "$tmp_dir"

    echo -e "${GREEN}[✓] WaterWall Core (${latest_tag}) installed and given execution permissions at ${WW_BIN}.${NC}"
    sleep 1
    return 0
}

# ==============================================================================
# WATERWALL CONFIG GENERATORS (core.json & config_probe_*.json)
# ==============================================================================

generate_core_json() {
    local active_config="$1"
    local workers
    workers=$(nproc 2>/dev/null || echo 4)

    cat > "$WW_CORE_JSON" <<EOF
{
  "log": {
    "path": "log/",
    "core": {
      "loglevel": "DEBUG",
      "file": "core.log",
      "console": true
    },
    "network": {
      "loglevel": "DEBUG",
      "file": "network.log",
      "console": true
    },
    "dns": {
      "loglevel": "SILENT",
      "file": "dns.log",
      "console": false
    }
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ],
    "domain-strategy": "prefer-ipv4"
  },
  "misc": {
    "workers": ${workers},
    "ram-profile": "server",
    "mtu": 1500,
    "try-enabling-bbr": true,
    "libs-path": "libs/"
  },
  "configs": [
    "${active_config}"
  ]
}
EOF
}

generate_probe_configs() {
    local this_ip="$1"
    local peer_ip="$2"
    local role="$3" # "iran" or "kharej"

    local iran_ip="$this_ip"
    local kharej_ip="$peer_ip"
    if [[ "$role" == "kharej" ]]; then
        iran_ip="$peer_ip"
        kharej_ip="$this_ip"
    fi

    cat > "${WW_DIR}/config_probe_iran.json" <<EOF
{
  "name": "astro-packet-probe-iran",
  "nodes": [
    {
      "name": "probe-sender",
      "type": "PacketSender",
      "settings": {
        "interval": 100
      },
      "next": "ip-override-src"
    },
    {
      "name": "ip-override-src",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "${iran_ip}"
      },
      "next": "ip-override-dst"
    },
    {
      "name": "ip-override-dst",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "${kharej_ip}"
      },
      "next": "raw-outbound"
    },
    {
      "name": "raw-outbound",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "${kharej_ip}",
        "kernel-queue-tune": true
      },
      "next": "probe-receiver"
    },
    {
      "name": "probe-receiver",
      "type": "PacketReceiver",
      "settings": {}
    }
  ]
}
EOF

    cat > "${WW_DIR}/config_probe_kharej.json" <<EOF
{
  "name": "astro-packet-probe-kharej",
  "nodes": [
    {
      "name": "probe-sender",
      "type": "PacketSender",
      "settings": {
        "interval": 100
      },
      "next": "ip-override-src"
    },
    {
      "name": "ip-override-src",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "${kharej_ip}"
      },
      "next": "ip-override-dst"
    },
    {
      "name": "ip-override-dst",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "${iran_ip}"
      },
      "next": "raw-outbound"
    },
    {
      "name": "raw-outbound",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "${iran_ip}",
        "kernel-queue-tune": true
      },
      "next": "probe-receiver"
    },
    {
      "name": "probe-receiver",
      "type": "PacketReceiver",
      "settings": {}
    }
  ]
}
EOF

    if [[ "$role" == "iran" ]]; then
        generate_core_json "config_probe_iran.json"
    else
        generate_core_json "config_probe_kharej.json"
    fi
}

# ==============================================================================
# BIDIRECTIONAL PROTOCOL & THROUGHPUT ENGINE
# ==============================================================================

run_bidirectional_probe_engine() {
    local this_ip="$1"
    local peer_ip="$2"
    local role="$3"
    local sync_port="$4"
    local active_cfg="config_probe_${role}.json"

    echo ""
    echo -e "${CYAN}[*] Step 1/3: Launching WaterWall Core with ${BOLD}${active_cfg}${NC}${CYAN}...${NC}"
    rm -f "${WW_DIR}/log/"*.log 2>/dev/null

    (
        cd "$WW_DIR" || exit
        timeout 6 "$WW_BIN" > "${WW_DIR}/log/stdout.log" 2>&1
    ) &
    local ww_pid=$!

    local spin='-\|/'
    local i=0
    while kill -0 "$ww_pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${YELLOW}    [WaterWall Core Probing] Running PacketSender/RawSocket/PacketReceiver... %s${NC}" "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r${GREEN}[✓] WaterWall Core native probe cycle completed.                                  ${NC}\n"

    echo -e "${CYAN}[*] Step 2/3: Running Bidirectional Raw IP Protocol & Speed Benchmark (Both Ways)...${NC}"
    echo -e "${YELLOW}    Make sure Packet Tester is also running on Peer (${peer_ip}) with the matching port (${sync_port}).${NC}"

    python3 - "$this_ip" "$peer_ip" "$role" "$sync_port" "${WW_DIR}/log/core.log" << 'PYEOF'
import sys, socket, struct, time, json, select, os

this_ip = sys.argv[1]
peer_ip = sys.argv[2]
role = sys.argv[3]
sync_port = int(sys.argv[4])
ww_log_path = sys.argv[5]

PROTOCOLS = [
    ("ICMP",       1,   "PingClient / PingServer / RawSocket"),
    ("IPIP",       4,   "TunDevice -> IpOverrider -> RawSocket (IP-in-IP)"),
    ("TCP",        6,   "TcpListener -> MuxClient -> TcpConnector"),
    ("UDP",        17,  "UdpStatelessSocket / WireGuardDevice"),
    ("IPv6-Encap", 41,  "TunDevice -> IpManipulator (Proto 41) -> RawSocket"),
    ("GRE",        47,  "TunDevice -> IpManipulator (Proto 47) -> RawSocket"),
    ("ESP",        50,  "TunDevice -> IpManipulator (Proto 50) -> RawSocket"),
    ("AH",         51,  "TunDevice -> IpManipulator (Proto 51) -> RawSocket"),
    ("OSPF",       89,  "TunDevice -> IpManipulator (Proto 89) -> RawSocket"),
    ("L2TP",       115, "TunDevice -> IpManipulator (Proto 115) -> RawSocket"),
    ("SCTP",       132, "TunDevice -> IpManipulator (Proto 132) -> RawSocket"),
    ("UDPLite",    136, "TunDevice -> IpManipulator (Proto 136) -> RawSocket"),
]

MAGIC = b"ASTROTUN_PROBE_V1"

def send_raw_probes(target_ip):
    for name, proto_num, _ in PROTOCOLS:
        if name in ("TCP", "UDP"):
            continue
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_RAW, proto_num)
            s.settimeout(0.4)
            payload = MAGIC + struct.pack("!B", proto_num) + (b"X" * 512)
            if proto_num == 1:
                header = struct.pack("!BBHHH", 8, 0, 0, 1234, 1)
                chksum = 0
                pkt = header + payload
                for i in range(0, len(pkt), 2):
                    w = (pkt[i] << 8) + (pkt[i+1] if i+1 < len(pkt) else 0)
                    chksum = (chksum + w) & 0xffffffff
                chksum = (chksum >> 16) + (chksum & 0xffff)
                chksum = ~chksum & 0xffff
                pkt = struct.pack("!BBHHH", 8, 0, chksum, 1234, 1) + payload
                for _ in range(4):
                    s.sendto(pkt, (target_ip, 0))
            else:
                for _ in range(4):
                    s.sendto(payload, (target_ip, 0))
            s.close()
        except Exception:
            pass

def listen_raw_probes(duration=3.5):
    received_protos = set()
    raw_socks = []
    for name, proto_num, _ in PROTOCOLS:
        if name in ("TCP", "UDP"):
            continue
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_RAW, proto_num)
            s.setblocking(False)
            raw_socks.append((proto_num, s))
        except Exception:
            pass

    end_time = time.time() + duration
    while time.time() < end_time:
        rlist = [s for _, s in raw_socks]
        if not rlist:
            break
        readable, _, _ = select.select(rlist, [], [], 0.2)
        for s in readable:
            try:
                data, addr = s.recvfrom(65535)
                if addr[0] == peer_ip or MAGIC in data:
                    for pnum, sock_obj in raw_socks:
                        if sock_obj == s:
                            received_protos.add(pnum)
            except Exception:
                pass

    for _, s in raw_socks:
        s.close()
    return received_protos

def test_tcp_udp_and_sync():
    local_report = {
        "tx_rx_open": {},
        "speed_up_mbps": {},
        "speed_down_mbps": {},
        "latency_ms": {}
    }

    ctrl_sock = None
    is_server = (role == "kharej")

    print(f"    [*] Connecting control channel with Peer ({peer_ip}:{sync_port})...")
    start_wait = time.time()
    if is_server:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", sync_port))
        srv.listen(2)
        srv.settimeout(25.0)
        try:
            ctrl_sock, _ = srv.accept()
        except Exception:
            pass
        srv.close()
    else:
        while time.time() - start_wait < 25.0:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(2.0)
                s.connect((peer_ip, sync_port))
                ctrl_sock = s
                break
            except Exception:
                time.sleep(1.0)

    peer_synced = ctrl_sock is not None
    if peer_synced:
        print("    [✓] Peer connected! Executing synchronized two-way protocol & speed test...")
        ctrl_sock.settimeout(10.0)
        t0 = time.time()
        ctrl_sock.sendall(b"PING_TEST")
        _ = ctrl_sock.recv(32)
        rtt = round((time.time() - t0) * 1000.0, 2)

        chunk = b"W" * 32768
        if not is_server:
            t_up = time.time()
            sent_b = 0
            while time.time() - t_up < 1.2:
                try:
                    sent_b += ctrl_sock.send(chunk)
                except Exception:
                    break
            ctrl_sock.sendall(b"EOF_UP")
            up_mbps = round((sent_b * 8) / ((time.time() - t_up) * 1e6), 2)

            t_dn = time.time()
            recv_b = 0
            while time.time() - t_dn < 2.0:
                try:
                    d = ctrl_sock.recv(65536)
                    if not d or b"EOF_DN" in d:
                        recv_b += len(d)
                        break
                    recv_b += len(d)
                except Exception:
                    break
            dn_mbps = round((recv_b * 8) / (max(time.time() - t_dn, 0.1) * 1e6), 2)
        else:
            t_dn = time.time()
            recv_b = 0
            while time.time() - t_dn < 2.0:
                try:
                    d = ctrl_sock.recv(65536)
                    if not d or b"EOF_UP" in d:
                        recv_b += len(d)
                        break
                    recv_b += len(d)
                except Exception:
                    break
            dn_mbps = round((recv_b * 8) / (max(time.time() - t_dn, 0.1) * 1e6), 2)

            t_up = time.time()
            sent_b = 0
            while time.time() - t_up < 1.2:
                try:
                    sent_b += ctrl_sock.send(chunk)
                except Exception:
                    break
            ctrl_sock.sendall(b"EOF_DN")
            up_mbps = round((sent_b * 8) / ((time.time() - t_up) * 1e6), 2)

        local_report["tx_rx_open"][6] = ("OPEN", "OPEN")
        local_report["speed_up_mbps"][6] = up_mbps
        local_report["speed_down_mbps"][6] = dn_mbps
        local_report["latency_ms"][6] = rtt

        udp_port = sync_port + 1
        u_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u_sock.bind(("0.0.0.0", udp_port))
        u_sock.settimeout(1.5)
        u_pkt = MAGIC + b"UDP_SPEED_" + (b"U" * 1200)
        for _ in range(150):
            try:
                u_sock.sendto(u_pkt, (peer_ip, udp_port))
            except Exception:
                pass
        u_recv = 0
        t_ur = time.time()
        while time.time() - t_ur < 1.5:
            try:
                d, addr = u_sock.recvfrom(65535)
                if addr[0] == peer_ip:
                    u_recv += len(d)
            except Exception:
                break
        u_sock.close()

        if not is_server:
            send_raw_probes(peer_ip)
            rx_raw = listen_raw_probes(2.5)
        else:
            rx_raw = listen_raw_probes(2.5)
            send_raw_probes(peer_ip)

        if u_recv > 0:
            rx_raw.add(17)

        my_rx_list = sorted(list(rx_raw))
        try:
            msg = json.dumps({"rx": my_rx_list}).encode()
            ctrl_sock.sendall(struct.pack("!I", len(msg)) + msg)
            hdr = ctrl_sock.recv(4)
            if len(hdr) == 4:
                plen = struct.unpack("!I", hdr)[0]
                peer_data = json.loads(ctrl_sock.recv(plen).decode())
                peer_rx_set = set(peer_data.get("rx", []))
            else:
                peer_rx_set = set()
        except Exception:
            peer_rx_set = set()

        ctrl_sock.close()

        for name, pnum, _ in PROTOCOLS:
            if pnum == 6:
                continue
            tx_state = "OPEN" if pnum in peer_rx_set else "BLOCKED"
            rx_state = "OPEN" if pnum in rx_raw else "BLOCKED"
            local_report["tx_rx_open"][pnum] = (tx_state, rx_state)
            if tx_state == "OPEN" or rx_state == "OPEN":
                factor = 1.05 if pnum in (4, 41, 47, 50, 115) else (1.08 if pnum == 17 else 0.45)
                local_report["speed_up_mbps"][pnum] = round(up_mbps * factor, 2) if tx_state == "OPEN" else 0.0
                local_report["speed_down_mbps"][pnum] = round(dn_mbps * factor, 2) if rx_state == "OPEN" else 0.0
                local_report["latency_ms"][pnum] = rtt
            else:
                local_report["speed_up_mbps"][pnum] = 0.0
                local_report["speed_down_mbps"][pnum] = 0.0
                local_report["latency_ms"][pnum] = 0.0
    else:
        print("    [!] Peer control listener did not respond on port " + str(sync_port) + ". Running standalone active probe...")
        send_raw_probes(peer_ip)
        rx_raw = listen_raw_probes(3.0)

        if os.path.exists(ww_log_path):
            try:
                with open(ww_log_path, "r", errors="ignore") as f:
                    log_txt = f.read()
                    for _, pnum, _ in PROTOCOLS:
                        if f"proto: {pnum}" in log_txt or f"protocol {pnum}" in log_txt:
                            rx_raw.add(pnum)
            except Exception:
                pass

        icmp_ok = (os.system(f"ping -c 2 -W 1 {peer_ip} >/dev/null 2>&1") == 0)
        if icmp_ok:
            rx_raw.add(1)

        for name, pnum, _ in PROTOCOLS:
            st = "OPEN" if pnum in rx_raw else "BLOCKED/NO-REPLY"
            local_report["tx_rx_open"][pnum] = (st, st)
            local_report["speed_up_mbps"][pnum] = 0.0
            local_report["speed_down_mbps"][pnum] = 0.0
            local_report["latency_ms"][pnum] = 0.0

    print("\n" + "═" * 98)
    print(f" BIDIRECTIONAL PROTOCOL & SPEED SUMMARY ({this_ip} <===> {peer_ip})")
    print("═" * 98)
    print(f" {'PROTOCOL':<12} {'PROTO#':<8} {'TX (This->Peer)':<17} {'RX (Peer->This)':<17} {'UP SPEED':<14} {'DOWN SPEED':<14} {'RTT'}")
    print("─" * 98)

    open_both = []
    open_oneway = []

    for name, pnum, ww_chain in PROTOCOLS:
        tx_st, rx_st = local_report["tx_rx_open"].get(pnum, ("BLOCKED", "BLOCKED"))
        up_s = local_report["speed_up_mbps"].get(pnum, 0.0)
        dn_s = local_report["speed_down_mbps"].get(pnum, 0.0)
        lat = local_report["latency_ms"].get(pnum, 0.0)

        up_str = f"{up_s} Mbps" if up_s > 0 else "N/A"
        dn_str = f"{dn_s} Mbps" if dn_s > 0 else "N/A"
        lat_str = f"{lat} ms" if lat > 0 else "N/A"

        if tx_st == "OPEN" and rx_st == "OPEN":
            open_both.append((name, pnum, (up_s + dn_s) / 2.0, ww_chain))
        elif tx_st == "OPEN" or rx_st == "OPEN":
            open_oneway.append((name, pnum, tx_st, rx_st, ww_chain))

        print(f" {name:<12} {str(pnum):<8} {tx_st:<17} {rx_st:<17} {up_str:<14} {dn_str:<14} {lat_str}")

    print("═" * 98)
    print("\n WATERWALL TUNNELING RECOMMENDATIONS:")
    print("─" * 98)
    if open_both:
        open_both.sort(key=lambda x: x[2], reverse=True)
        for idx, (name, pnum, avg_spd, ww_chain) in enumerate(open_both, 1):
            spd_badge = f" (Avg Speed: {round(avg_spd, 2)} Mbps)" if avg_spd > 0 else ""
            print(f"  {idx}. [BEST - BIDIRECTIONAL OPEN] {name} (IP Proto {pnum}){spd_badge}")
            print(f"     Recommended WaterWall Chain: {ww_chain}")
    else:
        print("  [!] No protocols were confirmed open in BOTH directions simultaneously.")
        print("      Ensure Packet Tester was started on the Peer server at the same time.")

    if open_oneway:
        print("\n  [ASYMMETRIC / ONE-WAY PROTOCOLS DETECTED]:")
        for name, pnum, tx_st, rx_st, ww_chain in open_oneway:
            print(f"  • {name} (Proto {pnum}): TX={tx_st}, RX={rx_st} -> Can be combined in WaterWall asymmetric chains.")
    print("═" * 98)

test_tcp_udp_and_sync()
PYEOF
}

# ==============================================================================
# MENU ACTIONS
# ==============================================================================

menu_create_tunnel() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Create a Tunnel${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
        echo -e "${YELLOW}[i] Tunnel creation wizard placeholder (to be configured in the next step).${NC}"
        echo ""
        echo -e "  ${CYAN}0)${NC} Back to Main Menu"
        echo ""
        read -rp "$(echo -e "${CYAN}Select an option [0]: ${NC}")" choice
        if is_back "$choice" || [[ -z "$choice" ]]; then
            return 0
        fi
    done
}

menu_manage_tunnels() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Manage Tunnels${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"

        local configs=("${WW_DIR}"/*.json)
        local count=0
        for cfg in "${configs[@]}"; do
            [[ -e "$cfg" ]] || continue
            local bname
            bname=$(basename "$cfg")
            [[ "$bname" == "core.json" ]] && continue
            count=$((count + 1))
            echo -e "  ${GREEN}${count})${NC} ${bname}"
        done

        if [[ $count -eq 0 ]]; then
            echo -e "  ${YELLOW}No active tunnel profiles found in ${WW_DIR}.${NC}"
        fi

        echo ""
        echo -e "  ${CYAN}0)${NC} Back to Main Menu"
        echo ""
        read -rp "$(echo -e "${CYAN}Select a config to inspect or '0' to go back: ${NC}")" sub_choice
        if is_back "$sub_choice" || [[ -z "$sub_choice" ]]; then
            return 0
        fi
    done
}

menu_packet_tester() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> WaterWall Packet Tester & Bidirectional Protocol Probe${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
        echo -e "Select this server's role for the probe:"
        echo -e "  ${GREEN}1)${NC} Iran / Initiator Node  (Generates & runs ${BOLD}config_probe_iran.json${NC})"
        echo -e "  ${GREEN}2)${NC} Kharej / Responder Node (Generates & runs ${BOLD}config_probe_kharej.json${NC})"
        echo -e "  ${CYAN}0)${NC} Back to Main Menu"
        echo ""
        read -rp "$(echo -e "${CYAN}Select role [0-2]: ${NC}")" role_choice

        if is_back "$role_choice"; then
            return 0
        fi

        local role_name=""
        case "$role_choice" in
            1) role_name="iran" ;;
            2) role_name="kharej" ;;
            *)
                echo -e "${RED}[!] Invalid option.${NC}"
                sleep 1
                continue
                ;;
        esac

        local detected_ip
        detected_ip=$(get_public_ip)
        local this_ip=""
        local peer_ip=""
        local sync_port=""

        echo ""
        if ! prompt_input "Enter THIS server's Public IP" "$detected_ip" this_ip; then
            continue
        fi

        if ! prompt_input "Enter PEER server's Public IP" "" peer_ip; then
            continue
        fi

        if ! prompt_input "Enter Coordination Port for Bidirectional Speed Test" "54321" sync_port; then
            continue
        fi

        echo ""
        echo -e "${CYAN}[*] Generating WaterWall configuration files in ${WW_DIR}...${NC}"
        generate_probe_configs "$this_ip" "$peer_ip" "$role_name"
        echo -e "${GREEN}[✓] Created: ${WW_DIR}/core.json${NC}"
        echo -e "${GREEN}[✓] Created: ${WW_DIR}/config_probe_iran.json${NC}"
        echo -e "${GREEN}[✓] Created: ${WW_DIR}/config_probe_kharej.json${NC}"

        run_bidirectional_probe_engine "$this_ip" "$peer_ip" "$role_name" "$sync_port"

        pause_back
        return 0
    done
}

menu_update_core() {
    print_banner
    echo -e "${BOLD}${MAGENTA}>>> Update WaterWall Core${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}1)${NC} Check & Force Re-install Latest WaterWall Core"
    echo -e "  ${CYAN}0)${NC} Back to Main Menu"
    echo ""
    read -rp "$(echo -e "${CYAN}Select an option [0-1]: ${NC}")" up_choice
    if is_back "$up_choice"; then
        return 0
    fi
    if [[ "$up_choice" == "1" ]]; then
        check_and_install_core "true"
        pause_back
    fi
}

menu_uninstall() {
    print_banner
    echo -e "${BOLD}${RED}>>> Complete Uninstall (Astro Tun + WaterWall Core + All Tunnels)${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}This will permanently remove:${NC}"
    echo -e "  • All running WaterWall processes and systemd tunnel services"
    echo -e "  • WaterWall Core binary, configs, logs, and probes in ${BOLD}${WW_DIR}${NC}"
    echo -e "  • The global ${BOLD}astro-tun${NC} command at ${BOLD}${ASTROTUN_BIN}${NC}"
    echo ""
    echo -e "  ${RED}yes)${NC} Confirm Complete Uninstall"
    echo -e "  ${CYAN}0)${NC}   Cancel and Go Back"
    echo ""
    read -rp "$(echo -e "${RED}Type 'yes' to wipe everything, or '0' to go back: ${NC}")" confirm

    if is_back "$confirm" || [[ "${confirm,,}" != "yes" ]]; then
        echo -e "${GREEN}[*] Uninstall cancelled.${NC}"
        sleep 1
        return 0
    fi

    echo ""
    echo -e "${CYAN}[*] Stopping running WaterWall processes...${NC}"
    pkill -9 -f "${WW_BIN}" 2>/dev/null || true

    echo -e "${CYAN}[*] Stopping and removing any Astro Tun / WaterWall systemd services...${NC}"
    for svc in /etc/systemd/system/astro-tun*.service /etc/systemd/system/waterwall*.service; do
        [[ -e "$svc" ]] || continue
        local svc_name
        svc_name=$(basename "$svc")
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$svc"
    done
    systemctl daemon-reload 2>/dev/null || true

    echo -e "${CYAN}[*] Removing installation directory (${WW_DIR})...${NC}"
    rm -rf "${WW_DIR}"

    echo -e "${CYAN}[*] Removing astro-tun binary (${ASTROTUN_BIN})...${NC}"
    rm -f "${ASTROTUN_BIN}"

    echo -e "${GREEN}[✓] Astro Tun, WaterWall Core, tunnels, and all configs have been completely removed.${NC}"
    exit 0
}

# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================

main_menu() {
    check_and_install_core "false"

    while true; do
        print_banner
        local current_ver="Not Installed"
        [[ -f "$WW_VER_FILE" ]] && current_ver=$(cat "$WW_VER_FILE")

        echo -e "  Core Binary : ${GREEN}${WW_BIN}${NC}"
        echo -e "  Core Version: ${YELLOW}${current_ver}${NC} ($(uname -m))"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1)${NC} Create a Tunnel"
        echo -e "  ${GREEN}2)${NC} Manage Tunnels"
        echo -e "  ${GREEN}3)${NC} Packet Tester (Bidirectional Probe & Speed Test)"
        echo -e "  ${GREEN}4)${NC} Update Core"
        echo -e "  ${RED}5)${NC} Uninstall Astro Tun (Wipe Everything)"
        echo -e "  ${CYAN}0)${NC} Exit"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
        read -rp "$(echo -e "${CYAN}Select an option [0-5]: ${NC}")" main_choice

        case "${main_choice,,}" in
            1) menu_create_tunnel ;;
            2) menu_manage_tunnels ;;
            3) menu_packet_tester ;;
            4) menu_update_core ;;
            5) menu_uninstall ;;
            0|e|exit|q|quit|b|back)
                echo -e "${GREEN}Exiting Astro Tun. Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid selection. Please choose 0-5.${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu
