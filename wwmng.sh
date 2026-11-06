#!/usr/bin/env bash

# ==============================================================================
# WATERWALL-MANAGER (wwmng) - Tunneling & Bidirectional Packet Probe Wizard
# Repository: https://github.com/TheAstro9aut/Waterwall-Manager
# WaterWall:  https://github.com/radkesvat/WaterWall
# ==============================================================================

WW_DIR="/opt/waterwall-manager"
WW_BIN="${WW_DIR}/Waterwall"
WW_VER_FILE="${WW_DIR}/.version"
WW_CORE_JSON="${WW_DIR}/core.json"
WWMNG_BIN="/usr/local/bin/wwmng"
WWMNG_RAW_URL="https://raw.githubusercontent.com/TheAstro9aut/Waterwall-Manager/main/wwmng.sh"
WW_REPO="radkesvat/WaterWall"
WW_API_LATEST="https://api.github.com/repos/${WW_REPO}/releases/latest"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# State tracking for Ctrl+C rollback
ACTIVE_TMP_DIR=""
ACTIVE_WW_PID=""
ACTIVE_PY_PID=""

# ==============================================================================
# CTRL+C (SIGINT / SIGTERM) ROLLBACK & CLEANUP HANDLER
# ==============================================================================

handle_interrupt() {
    trap '' INT TERM
    echo -e "\n\n${RED}${BOLD}[!] Ctrl+C detected! Cancelling active operations and rolling back...${NC}"

    # The packet tester (python) owns its WaterWall children: ask it to stop them
    # gracefully so WaterWall removes the iptables rules it installed.
    if [[ -n "$ACTIVE_PY_PID" ]] && kill -0 "$ACTIVE_PY_PID" 2>/dev/null; then
        echo -e "${YELLOW}    -> Stopping Packet Tester and its WaterWall processes (PID: ${ACTIVE_PY_PID})...${NC}"
        kill -TERM "$ACTIVE_PY_PID" 2>/dev/null
        local waited=0
        while kill -0 "$ACTIVE_PY_PID" 2>/dev/null && [[ $waited -lt 40 ]]; do
            sleep 0.5
            waited=$((waited + 1))
        done
        if kill -0 "$ACTIVE_PY_PID" 2>/dev/null; then
            kill -9 "$ACTIVE_PY_PID" 2>/dev/null
            purge_ww_rules
        fi
    fi

    # Only a core process started by this session is ever stopped here, so tunnels
    # that are already running as services are never touched.
    if [[ -n "$ACTIVE_WW_PID" ]] && kill -0 "$ACTIVE_WW_PID" 2>/dev/null; then
        echo -e "${YELLOW}    -> Stopping active WaterWall process (PID: ${ACTIVE_WW_PID})...${NC}"
        kill -TERM "$ACTIVE_WW_PID" 2>/dev/null
        sleep 2
        kill -9 "$ACTIVE_WW_PID" 2>/dev/null
    fi

    if [[ -n "$ACTIVE_TMP_DIR" && -d "$ACTIVE_TMP_DIR" ]]; then
        echo -e "${YELLOW}    -> Removing temporary directory (${ACTIVE_TMP_DIR})...${NC}"
        rm -rf "$ACTIVE_TMP_DIR"
    fi

    echo -e "${GREEN}[✓] Rollback complete. Exiting Waterwall-Manager.${NC}"
    exit 130
}

# Remove only the firewall rules WaterWall's RawSocket tags with its own comments.
purge_ww_rules() {
    command -v iptables-save >/dev/null 2>&1 || return 0
    local rule
    while IFS= read -r rule; do
        [[ "$rule" == -A* ]] || continue
        eval "iptables -t raw ${rule/-A/-D}" 2>/dev/null
    done < <(iptables-save -t raw 2>/dev/null | grep -E 'WW(RAW|CAP)_NOTRACK')
}

trap handle_interrupt INT TERM

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Waterwall-Manager (wwmng) must be run as root (needed for RawSocket & TUN capabilities).${NC}"
    exit 1
fi

mkdir -p "${WW_DIR}"/{log,libs,configs,results}

# ==============================================================================
# UI BANNER & NAVIGATION HELPERS
# ==============================================================================

print_banner() {
    clear
    echo -e "  ${CYAN}██╗    ██╗ █████╗ ████████╗███████╗██████╗ ██╗    ██╗ █████╗ ██╗     ██╗${NC}  "
    echo -e "  ${CYAN}██║    ██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗██║    ██║██╔══██╗██║     ██║${NC}  "
    echo -e "  ${CYAN}██║ █╗ ██║███████║   ██║   █████╗  ██████╔╝██║ █╗ ██║███████║██║     ██║${NC}  "
    echo -e "  ${CYAN}██║███╗██║██╔══██║   ██║   ██╔══╝  ██╔══██╗██║███╗██║██╔══██║██║     ██║${NC}  "
    echo -e "  ${CYAN}╚███╔███╔╝██║  ██║   ██║   ███████╗██║  ██║╚███╔███╔╝██║  ██║███████╗███████╗${NC}"
    echo -e "  ${CYAN} ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝${NC}"
    echo -e "               ${WHITE}───  W A T E R W A L L - M A N A G E R  ───${NC}                "
    echo -e "                            ${YELLOW}${BOLD}Waterwall $(cat "$WW_VER_FILE" 2>/dev/null || echo unknown)${NC}"
}

is_back() {
    local input="${1,,}"
    case "$input" in
        0|b|back) return 0 ;;
        *) return 1 ;;
    esac
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
    local ip=""
    ip=$(curl -fsSL4 --max-time 4 https://icanhazip.com 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -fsSL4 --max-time 4 https://ifconfig.me 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    fi
    echo "${ip:-0.0.0.0}"
}

# ==============================================================================
# WATERWALL CORE & SCRIPT INSTALLATION / UPDATE
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

    case "$arch" in
        x86_64|amd64)
            # Release has linux builds: clang-avx512f-x64, clang-x64, gcc-x64 and gcc-x64-old-cpu.
            # Never pick the AVX-512 build unless this CPU really has avx512f (it would crash).
            if grep -q -i "avx512f" /proc/cpuinfo 2>/dev/null; then
                asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*avx512f.*x64"; "i")) | .browser_download_url' | head -n1)
            fi
            if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
                if [[ "$has_avx2" == "true" ]]; then
                    asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux-gcc-x64"; "i")) | select(.name | test("old-cpu"; "i") | not) | .browser_download_url' | head -n1)
                    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
                        asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*x64"; "i")) | select(.name | test("old-cpu|avx512"; "i") | not) | .browser_download_url' | head -n1)
                    fi
                else
                    asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*x64.*old-cpu"; "i")) | .browser_download_url' | head -n1)
                fi
            fi
            if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
                asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*x64"; "i")) | select(.name | test("avx512"; "i") | not) | .browser_download_url' | head -n1)
            fi
            ;;
        aarch64|arm64)
            if grep -q -i "asimd" /proc/cpuinfo 2>/dev/null; then
                asset_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*arm64"; "i")) | select(.name | test("old-cpu"; "i") | not) | .browser_download_url' | head -n1)
            fi
            if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
                asset_url=$(echo "$release_json" | jq -r '.assets[] | select((.name | test("linux.*arm64"; "i")) or (.name | test("linux.*aarch64"; "i"))) | .browser_download_url' | head -n1)
            fi
            ;;
    esac

    echo "$asset_url"
}

install_or_update_core() {
    local release_json="$1"

    if [[ -z "$release_json" ]]; then
        release_json=$(curl -fsSL --max-time 10 "$WW_API_LATEST" 2>/dev/null)
    fi

    if [[ -z "$release_json" ]]; then
        echo -e "${RED}[!] Failed to fetch release metadata from GitHub (${WW_REPO}). Check network connection.${NC}"
        return 1
    fi

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r '.tag_name // empty')

    local asset_url
    asset_url=$(detect_compatible_asset "$release_json")

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        echo -e "${RED}[!] No compatible Linux binary found for architecture $(uname -m) in release ${latest_tag}.${NC}"
        return 1
    fi

    local asset_filename
    asset_filename=$(basename "$asset_url")
    echo -e "${CYAN}[*] Downloading compatible WaterWall Core build: ${BOLD}${asset_filename}${NC} (${latest_tag})..."

    ACTIVE_TMP_DIR=$(mktemp -d)
    if ! curl -fL --progress-bar "$asset_url" -o "${ACTIVE_TMP_DIR}/waterwall.zip"; then
        echo -e "${RED}[!] Download failed.${NC}"
        rm -rf "$ACTIVE_TMP_DIR"
        ACTIVE_TMP_DIR=""
        return 1
    fi

    unzip -qo "${ACTIVE_TMP_DIR}/waterwall.zip" -d "$ACTIVE_TMP_DIR"
    local extracted_bin
    extracted_bin=$(find "$ACTIVE_TMP_DIR" -maxdepth 2 -type f -iname "waterwall*" ! -name "*.zip" ! -name "*.json" ! -name "*.md" | head -n1)

    if [[ -z "$extracted_bin" ]]; then
        echo -e "${RED}[!] Could not locate Waterwall executable inside the archive.${NC}"
        rm -rf "$ACTIVE_TMP_DIR"
        ACTIVE_TMP_DIR=""
        return 1
    fi

    mv -f "$extracted_bin" "$WW_BIN"
    chmod +x "$WW_BIN"
    setcap cap_net_admin,cap_net_raw+ep "$WW_BIN" 2>/dev/null
    echo "$latest_tag" > "$WW_VER_FILE"
    rm -rf "$ACTIVE_TMP_DIR"
    ACTIVE_TMP_DIR=""

    echo -e "${GREEN}[✓] WaterWall Core (${latest_tag}) installed and given execution permissions at ${WW_BIN}.${NC}"
    sleep 1
    return 0
}

# Only installs on startup if the binary is completely missing.
# Does NOT check for updates every time wwmng runs.
ensure_core_present_on_startup() {
    if [[ -x "$WW_BIN" ]]; then
        return 0
    fi
    echo -e "${YELLOW}[!] WaterWall Core is not installed yet. Installing latest version...${NC}"
    install_or_update_core ""
}

# ==============================================================================
# PACKET TESTER (WaterWall PacketGenerator -> RawSocket / RawSocket -> PacketCounter)
# ==============================================================================

PROBE_PY="${WW_DIR}/wwprobe.py"
PROBE_DIR="${WW_DIR}/probe"

write_probe_script() {
    cat > "$PROBE_PY" << 'PYEOF'
import sys, os, socket, json, time, signal, subprocess, shutil, re, shlex

THIS_IP, PEER_IP, ROLE, SYNC_PORT, WW_BIN, PROBE_DIR, MODE = sys.argv[1:8]
SYNC_PORT = int(SYNC_PORT)
IS_SERVER = (ROLE == "kharej")
DEST_PORT = SYNC_PORT + 13 if SYNC_PORT + 13 < 65535 else SYNC_PORT - 13
TERM_MARK = b"\x00\x00WWEND\x00\x00"

G, Y, R_, C, B, N = "\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0;36m", "\033[1m", "\033[0m"

PROTO_NAMES = {
    1: "ICMP", 2: "IGMP", 4: "IPIP", 6: "TCP", 17: "UDP", 41: "IPv6-Encap",
    47: "GRE", 50: "ESP", 51: "AH", 89: "OSPF", 115: "L2TP", 132: "SCTP",
    136: "UDPLite", 253: "Experimental-1", 254: "Experimental-2",
}

children = []
stopping = False
BASELINE_INPUT = set()


def log(msg=""):
    print(msg, flush=True)


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except Exception:
        return subprocess.CompletedProcess(cmd, 1, "", "")


# ----------------------------------------------------------------------------
# Process + firewall hygiene (RawSocket installs iptables rules while it runs)
# ----------------------------------------------------------------------------
def stop_proc(p, grace=6):
    if p is None or p.poll() is not None:
        return
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            p.send_signal(sig)
        except Exception:
            return
        t0 = time.time()
        while time.time() - t0 < grace:
            if p.poll() is not None:
                return
            time.sleep(0.1)
    try:
        p.kill()
    except Exception:
        pass


def purge_rules():
    """Remove only the firewall rules WaterWall's RawSocket may have left behind."""
    removed = 0
    out = run(["iptables-save", "-t", "raw"]).stdout
    for line in out.splitlines():
        if line.startswith("-A") and ("WWRAW_NOTRACK" in line or "WWCAP_NOTRACK" in line):
            if run(["iptables", "-t", "raw"] + shlex.split(line.replace("-A", "-D", 1))).returncode == 0:
                removed += 1
    out = run(["iptables", "-S", "INPUT"]).stdout
    for line in out.splitlines():
        if line.startswith("-A") and "NFQUEUE" in line and line not in BASELINE_INPUT:
            if run(["iptables"] + shlex.split(line.replace("-A", "-D", 1))).returncode == 0:
                removed += 1
    return removed


def on_signal(signum, frame):
    global stopping
    if stopping:
        return
    stopping = True
    log("\n" + R_ + " [!] Interrupted - stopping WaterWall and restoring firewall rules..." + N)
    for p in list(children):
        stop_proc(p, grace=4)
    n = purge_rules()
    if n:
        log(f" [i] Removed {n} leftover firewall rule(s).")
    os._exit(130)


signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)


# ----------------------------------------------------------------------------
# Control channel (plain TCP, newline-delimited JSON + raw bytes for speed test)
# ----------------------------------------------------------------------------
class Chan:
    def __init__(self, s):
        self.s = s
        self.buf = b""

    def send(self, obj):
        self.s.sendall(json.dumps(obj).encode() + b"\n")

    def recv(self, timeout=60):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            d = self.s.recv(65536)
            if not d:
                raise ConnectionError("peer closed the control channel")
            self.buf += d
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode())

    def stream_send(self, seconds):
        chunk = b"W" * 65536
        self.s.settimeout(10)
        end = time.time() + seconds
        while time.time() < end:
            self.s.sendall(chunk)
        self.s.sendall(TERM_MARK)

    def stream_recv(self, max_wait):
        self.s.settimeout(max_wait)
        total, t_first, t_last, tail = 0, None, None, b""
        data = self.buf
        self.buf = b""
        while True:
            if data:
                now = time.time()
                if t_first is None:
                    t_first = now
                t_last = now
                total += len(data)
                tail = (tail + data)[-16:]
                if TERM_MARK in tail:
                    total -= len(TERM_MARK)
                    break
            data = self.s.recv(262144)
            if not data:
                raise ConnectionError("peer closed during speed test")
        dt = max((t_last - t_first), 0.05) if t_first else 0.05
        return round(total * 8 / dt / 1e6, 1)


def open_channel():
    log(f"{C}[*] Connecting control channel with peer {PEER_IP}:{SYNC_PORT} (waiting up to 90s)...{N}")
    deadline = time.time() + 90
    if IS_SERVER:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", SYNC_PORT))
        srv.listen(4)
        while time.time() < deadline:
            srv.settimeout(max(0.5, deadline - time.time()))
            try:
                s, addr = srv.accept()
            except socket.timeout:
                break
            if addr[0] == PEER_IP:
                srv.close()
                return Chan(s)
            s.close()
        srv.close()
    else:
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(3)
                s.connect((PEER_IP, SYNC_PORT))
                return Chan(s)
            except Exception:
                time.sleep(1)
    return None


# ----------------------------------------------------------------------------
# WaterWall config generation (written next to the core so you can inspect them)
# ----------------------------------------------------------------------------
def local_source_ip():
    out = run(["ip", "-4", "route", "get", PEER_IP]).stdout
    m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else THIS_IP


def write_core_json(d, cfg_name):
    workers = max(1, min(os.cpu_count() or 1, 4))
    core = {
        "log": {
            "path": "log/",
            "internal": {"loglevel": "INFO", "file": "internal.log", "console": True},
            "core": {"loglevel": "INFO", "file": "core.log", "console": True},
            "network": {"loglevel": "INFO", "file": "network.log", "console": True},
            "dns": {"loglevel": "SILENT", "file": "dns.log", "console": False},
        },
        "misc": {"workers": workers, "ram-profile": "client", "mtu": 1500,
                 "tcp-tune": False, "try-enabling-bbr": False, "libs-path": "libs/"},
        "dns": {"domain-strategy": "prefer-ipv4"},
        "configs": [cfg_name],
    }
    with open(os.path.join(d, "core.json"), "w") as f:
        json.dump(core, f, indent=2)


def fresh_dir(name):
    d = os.path.join(PROBE_DIR, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    return d


def write_selfcheck():
    d = fresh_dir("selfcheck")
    cfg = {"name": "wwmng-selfcheck", "nodes": [
        {"name": "gen", "type": "PacketGenerator",
         "settings": {"source-ipv4-range": "198.51.100.10/32", "dest-ipv4": "203.0.113.20",
                      "protocol-number": "ALL", "duration-ms": 500, "packets-per-ip": 2,
                      "dest-port": 9, "src-port": "random"}, "next": "count"},
        {"name": "count", "type": "PacketCounter",
         "settings": {"source-ipv4-range": "198.51.100.10/32", "protocol-number": "ALL",
                      "expected-packets-per-ip": 2, "report-after-ms": 2000,
                      "output-file": "report.txt"}}]}
    with open(os.path.join(d, "config_selfcheck.json"), "w") as f:
        json.dump(cfg, f, indent=2)
    write_core_json(d, "config_selfcheck.json")
    return d


def write_phase(ppi, duration_ms, report_ms, src_ip):
    tx = fresh_dir("tx")
    rx = fresh_dir("rx")
    tx_cfg = {"name": "wwmng-probe-tx", "nodes": [
        {"name": "gen", "type": "PacketGenerator",
         "settings": {"source-ipv4-range": f"{src_ip}/32", "dest-ipv4": PEER_IP,
                      "protocol-number": "ALL", "duration-ms": duration_ms,
                      "packets-per-ip": ppi, "dest-port": DEST_PORT, "src-port": "random"},
         "next": "raw-out"},
        {"name": "raw-out", "type": "RawSocket",
         "settings": {"raw-device-name": "wwmng-raw-out", "bypass-conntrack": True}}]}
    rx_cfg = {"name": "wwmng-probe-rx", "nodes": [
        {"name": "raw-in", "type": "RawSocket",
         "settings": {"capture-filter-mode": "source-ip", "capture-ip": PEER_IP,
                      "dont-capture-protocols": [6],
                      "capture-device-name": "wwmng-capture-in",
                      "raw-device-name": "wwmng-raw-in", "bypass-conntrack": True},
         "next": "count"},
        {"name": "count", "type": "PacketCounter",
         "settings": {"source-ipv4-range": f"{PEER_IP}/32", "protocol-number": "ALL",
                      "expected-packets-per-ip": ppi, "report-after-ms": report_ms,
                      "output-file": "report.txt"}}]}
    with open(os.path.join(tx, "config_probe_tx.json"), "w") as f:
        json.dump(tx_cfg, f, indent=2)
    with open(os.path.join(rx, "config_probe_rx.json"), "w") as f:
        json.dump(rx_cfg, f, indent=2)
    write_core_json(tx, "config_probe_tx.json")
    write_core_json(rx, "config_probe_rx.json")
    return tx, rx


def start_core(d):
    lf = open(os.path.join(d, "run.log"), "w")
    p = subprocess.Popen([WW_BIN], cwd=d, stdout=lf, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    children.append(p)
    return p


def read_log(d):
    try:
        with open(os.path.join(d, "run.log"), errors="ignore") as f:
            return f.read()
    except Exception:
        return ""


def fatal_lines(d):
    return [l for l in read_log(d).splitlines() if " FATAL " in l or " ERROR " in l][-6:]


def wait_for(p, d, pattern, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        txt = read_log(d)
        if re.search(pattern, txt):
            return True
        if " FATAL " in txt or p.poll() is not None:
            return False
        time.sleep(0.2)
    return False


def parse_report(d):
    res = {}
    try:
        with open(os.path.join(d, "report.txt")) as f:
            for line in f:
                parts = [x.strip() for x in line.split("|")]
                if len(parts) >= 6 and parts[1].isdigit():
                    res[int(parts[1])] = int(parts[3])
    except Exception:
        pass
    return res


# ----------------------------------------------------------------------------
# Test stages
# ----------------------------------------------------------------------------
def self_check():
    log(f"{C}[*] Step 1/4: WaterWall core self-check (PacketGenerator -> PacketCounter)...{N}")
    d = write_selfcheck()
    p = start_core(d)
    try:
        p.wait(timeout=25)
    except subprocess.TimeoutExpired:
        stop_proc(p)
    rep = parse_report(d)
    if len(rep) < 200 or sum(rep.values()) < 200:
        log(R_ + " [!] This WaterWall build did not run the packet-test nodes correctly." + N)
        for l in fatal_lines(d):
            log("     " + l)
        log("     Try menu option 4 (Update), then run the Packet Tester again.")
        return False
    log(G + " [✓] Core OK: PacketGenerator / PacketCounter / RawSocket nodes are available." + N)
    return True


def tcp_speed(ch):
    log(f"{C}[*] Step 2/4: TCP latency + real throughput over the control channel...{N}")
    best = 1e9
    for _ in range(5):
        t0 = time.time()
        ch.send({"cmd": "ping"})
        ch.recv(10)
        best = min(best, (time.time() - t0) * 1000)
    return round(best, 1)


def serve_pings(ch, n=5):
    for _ in range(n):
        ch.recv(10)
        ch.send({"cmd": "pong"})


def speed_exchange(ch, secs=3):
    """Returns (tx_mbps this->peer, rx_mbps peer->this), both really measured."""
    if not IS_SERVER:
        ch.send({"cmd": "speed_up"})
        ch.stream_send(secs)
        tx = ch.recv(secs + 15)["mbps"]
        rx = ch.stream_recv(secs + 15)
        ch.send({"mbps": rx})
        return tx, rx
    ch.recv(15)
    rx = ch.stream_recv(secs + 15)
    ch.send({"mbps": rx})
    ch.stream_send(secs)
    tx = ch.recv(secs + 15)["mbps"]
    return tx, rx


def run_phase(ch, label, ppi, duration_ms, src_ip, rtt_ms):
    report_ms = duration_ms + 10000 + int(rtt_ms * 4)
    tx_dir, rx_dir = write_phase(ppi, duration_ms, report_ms, src_ip)
    log(f"{C}[*] {label}: {ppi} packets x 255 protocol numbers over {duration_ms/1000:.0f}s, both directions...{N}")
    ch.send({"cmd": "go_rx"})
    ch.recv(60)
    rx = start_core(rx_dir)
    ok = wait_for(rx, rx_dir, r"CaptureDevice:.* up with", 25)
    if not ok:
        log(R_ + " [!] WaterWall receiver failed to start:" + N)
        for l in fatal_lines(rx_dir):
            log("     " + l)
        log("     RawSocket needs: root, iptables + iptables-save + ip, and kernel NFQUEUE support.")
        stop_proc(rx)
        ch.send({"cmd": "rx_failed"})
        return None
    ch.send({"cmd": "rx_ready"})
    msg = ch.recv(60)
    if msg.get("cmd") != "rx_ready":
        log(R_ + " [!] Peer receiver failed to start; see peer output." + N)
        stop_proc(rx)
        return None
    tx = start_core(tx_dir)
    sent = wait_for(tx, tx_dir, r"finished transmitting", duration_ms / 1000 + 20)
    if not sent:
        log(R_ + " [!] WaterWall sender failed:" + N)
        for l in fatal_lines(tx_dir):
            log("     " + l)
    time.sleep(0.5)
    stop_proc(tx)
    t0 = time.time()
    while rx.poll() is None and time.time() - t0 < report_ms / 1000 + 20:
        time.sleep(0.3)
    if rx.poll() is None:
        stop_proc(rx)
    mine = parse_report(rx_dir)
    ch.send({"cmd": "result", "rx": {str(k): v for k, v in mine.items()}})
    peer_msg = ch.recv(report_ms / 1000 + 60)
    theirs = {int(k): v for k, v in peer_msg.get("rx", {}).items()}
    if not mine and not theirs:
        return None
    return {"ppi": ppi, "rx_from_peer": mine, "tx_to_peer": theirs}


# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
def pct(phase, key, p):
    if not phase:
        return None
    v = phase[key].get(p, 0)
    return min(100.0, round(100.0 * v / phase["ppi"], 1))


def fmt(v):
    return "  n/a " if v is None else f"{v:5.1f}%"


def ranges(nums):
    nums = sorted(nums)
    out, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        out.append(str(nums[i]) if i == j else f"{nums[i]}-{nums[j]}")
        i = j + 1
    return ", ".join(out) if out else "none"


def summary(p1, p2, tcp, rtt, nat_note):
    W = 100
    log("\n" + "═" * W)
    log(f" PACKET TEST SUMMARY   this={THIS_IP}  peer={PEER_IP}   control-channel RTT={rtt} ms")
    if nat_note:
        log(" " + nat_note)
    log("═" * W)
    head = f" {'PROTOCOL':<16}{'NUM':<5}{'TX ->peer':>10}{'RX <-peer':>10}"
    if p2:
        head += f"{'LOAD TX':>10}{'LOAD RX':>10}"
    head += "   VERDICT"
    log(head)
    log("─" * W)
    OPEN = 90.0
    both_open, rows = [], {}
    for n in range(0, 255):
        if n == 6:
            continue
        t1, r1 = pct(p1, "tx_to_peer", n), pct(p1, "rx_from_peer", n)
        t2, r2 = pct(p2, "tx_to_peer", n), pct(p2, "rx_from_peer", n)
        rows[n] = (t1, r1, t2, r2)
        if t1 >= OPEN and r1 >= OPEN and n != 0:
            score = min(x for x in (t2, r2) if x is not None) if p2 else min(t1, r1)
            both_open.append((score, min(t1, r1), n))

    def verdict(t, r):
        if t >= OPEN and r >= OPEN:
            return G + "OPEN both ways" + N
        if t >= OPEN and r == 0:
            return Y + "only this->peer" + N
        if r >= OPEN and t == 0:
            return Y + "only peer->this" + N
        if t >= OPEN or r >= OPEN:
            return Y + f"lossy (TX {t:.0f}% / RX {r:.0f}%)" + N
        if t > 0 or r > 0:
            return Y + f"lossy (TX {t:.0f}% / RX {r:.0f}%)" + N
        return R_ + "BLOCKED" + N

    for n in sorted(PROTO_NAMES):
        if n == 6:
            line = f" {'TCP':<16}{'6':<5}{'OPEN':>10}{'OPEN':>10}"
            if p2:
                line += f"{'OPEN':>10}{'OPEN':>10}"
            line += "   " + G + f"OPEN both ways (↑{tcp[0]} Mbps ↓{tcp[1]} Mbps)" + N
            log(line)
            continue
        t1, r1, t2, r2 = rows[n]
        line = f" {PROTO_NAMES[n]:<16}{str(n):<5}{fmt(t1):>10}{fmt(r1):>10}"
        if p2:
            line += f"{fmt(t2):>10}{fmt(r2):>10}"
        line += "   " + verdict(t1, r1)
        log(line)
    log("═" * W)
    both_open.sort(key=lambda x: (-x[0], -x[1], x[2]))
    log(f"\n {B}TUNNELING RECOMMENDATIONS{N}  (TX ->peer / RX <-peer = share of packets that arrived; OPEN >= {OPEN:.0f}%)")
    log("─" * W)
    log(f" TCP (6)   : open both ways, measured {tcp[0]} Mbps up / {tcp[1]} Mbps down (real TCP stream).")
    if both_open:
        best = [x for x in both_open][:8]
        log(" Best IP protocol numbers (open both ways, ranked by delivery" + (" under load):" if p2 else "):"))
        for i, (score, base, n) in enumerate(best, 1):
            nm = PROTO_NAMES.get(n, "unassigned/other")
            log(f"   {i}. protocol {n:<3} ({nm})  delivery {score}%")
        log(f"\n All protocol numbers open both ways : {ranges([n for _, _, n in both_open])}")
    else:
        log(R_ + " No IP protocol number was open in both directions at once." + N)
        log("  Make sure the test was started on both servers and nothing filters raw IP between them.")
    one_way = [n for n, (t1, r1, _, _) in rows.items() if (t1 >= OPEN) != (r1 >= OPEN)]
    blocked = [n for n, (t1, r1, _, _) in rows.items() if t1 < OPEN and r1 < OPEN]
    log(f" Open in ONE direction only          : {ranges(one_way)}")
    log(f" Blocked / lossy both directions     : {ranges(blocked)}")
    log("─" * W)
    log(" Note: WaterWall's packet nodes measure delivery (loss) per protocol, not Mbps. Real Mbps is only")
    log(" shown for TCP. Measure a protocol's true speed after building a tunnel on it (e.g. SpeedTest nodes).")
    log("═" * W)


# ----------------------------------------------------------------------------
def main():
    for tool in ("iptables", "iptables-save", "ip"):
        if not shutil.which(tool):
            log(R_ + f"[!] '{tool}' not found. WaterWall's RawSocket needs iptables + iproute2." + N)
            log("    Debian/Ubuntu: apt-get install -y iptables iproute2")
            return 2
    if not os.access(WW_BIN, os.X_OK):
        log(R_ + f"[!] WaterWall binary not executable: {WW_BIN}" + N)
        return 2
    BASELINE_INPUT.update(run(["iptables", "-S", "INPUT"]).stdout.splitlines())
    purge_rules_start = purge_rules()
    if purge_rules_start:
        log(f" [i] Cleaned {purge_rules_start} stale WaterWall firewall rule(s) from an earlier run.")
    os.makedirs(PROBE_DIR, exist_ok=True)

    src_ip = local_source_ip()
    nat_note = ""
    if src_ip != THIS_IP:
        nat_note = f"NAT detected: packets are sent from local {src_ip} (public {THIS_IP})."
        log(Y + " [i] " + nat_note + N)
    log(Y + " [!] During the test, packets from the peer are captured by WaterWall (TCP excluded)." + N)
    log(Y + "     Stop other tunnels/VPNs between these two IPs first, or they will drop briefly." + N)

    if not self_check():
        return 3
    ch = open_channel()
    if ch is None:
        log(R_ + f"[!] Peer did not connect on {PEER_IP}:{SYNC_PORT}. Start the Packet Tester on the other server" + N)
        log("    and make sure TCP port " + str(SYNC_PORT) + " is open on the kharej server's firewall.")
        return 4
    log(G + " [✓] Peer connected." + N)

    mode = MODE
    if not IS_SERVER:
        ch.send({"cmd": "hello", "mode": mode, "this": THIS_IP, "peer": PEER_IP})
        ack = ch.recv(20)
        if ack.get("cmd") != "hello_ack":
            log(R_ + "[!] Unexpected reply from peer." + N)
            return 4
    else:
        hello = ch.recv(30)
        mode = hello.get("mode", "quick")
        if hello.get("peer") != THIS_IP or hello.get("this") != PEER_IP:
            log(Y + f" [!] IP mismatch: peer says it is {hello.get('this')} and targets {hello.get('peer')}." + N)
        ch.send({"cmd": "hello_ack"})
        log(f" [i] Test mode chosen by the Iran side: {mode}")

    # step 2: RTT + TCP speed
    if IS_SERVER:
        serve_pings(ch)
        rtt = None
    else:
        rtt = tcp_speed(ch)
    if IS_SERVER:
        rtt = ch.recv(10)["rtt"]
    else:
        ch.send({"rtt": rtt})
    tcp = speed_exchange(ch)
    log(f"{G} [✓] RTT {rtt} ms, TCP {tcp[0]} Mbps (this->peer) / {tcp[1]} Mbps (peer->this){N}")

    log(f"{C}[*] Step 3/4: WaterWall protocol scan (all 255 IP protocol numbers, both directions)...{N}")
    p1 = run_phase(ch, "Scan", 20, 4000, src_ip, rtt)
    if p1 is None:
        log(R_ + "[!] The scan produced no data. See messages above." + N)
        purge_rules()
        return 5
    p2 = None
    if mode == "full":
        log(f"{C}[*] Step 4/4: Load test (higher packet rate per protocol)...{N}")
        p2 = run_phase(ch, "Load", 600, 4000, src_ip, rtt)
    left = purge_rules()
    if left:
        log(f" [i] Removed {left} leftover firewall rule(s) after the test.")
    summary(p1, p2, tcp, rtt, nat_note)
    try:
        ch.s.close()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    except (ConnectionError, socket.timeout, OSError, json.JSONDecodeError) as e:
        log(R_ + f"[!] Test aborted: {e}" + N)
        rc = 6
    finally:
        for p in list(children):
            stop_proc(p, grace=4)
        purge_rules()
    sys.exit(rc)
PYEOF
    chmod 600 "$PROBE_PY"
}

run_packet_probe() {
    local this_ip="$1"
    local peer_ip="$2"
    local role="$3"
    local sync_port="$4"
    local mode="$5"

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}[!] python3 is required for the Packet Tester.${NC}"
        return 1
    fi
    if [[ ! -x "$WW_BIN" ]]; then
        echo -e "${RED}[!] WaterWall core is not installed. Use option 4 (Update) first.${NC}"
        return 1
    fi

    write_probe_script
    mkdir -p "$PROBE_DIR"

    python3 "$PROBE_PY" "$this_ip" "$peer_ip" "$role" "$sync_port" "$WW_BIN" "$PROBE_DIR" "$mode" &
    ACTIVE_PY_PID=$!
    wait "$ACTIVE_PY_PID"
    local rc=$?
    ACTIVE_PY_PID=""

    echo ""
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}[✓] Packet test finished. Generated configs are in ${PROBE_DIR}/tx and ${PROBE_DIR}/rx${NC}"
    else
        echo -e "${YELLOW}[!] Packet test ended with code ${rc}.${NC}"
    fi
    return $rc
}

# ==============================================================================
# MENU ACTIONS
# ==============================================================================

menu_create_tunnel() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Create a Tunnel${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${YELLOW}[i] Tunnel creation wizard placeholder (to be configured in the next step).${NC}"
        echo ""
        echo -e "  ${CYAN}0)${NC} Back to Main Menu"
        echo ""
        read -rp "$(echo -e "${CYAN}Select an option [0]: ${NC}")" choice
        if is_back "$choice"; then
            return 0
        fi
        if [[ -z "$choice" ]]; then
            return 0
        fi
    done
}

menu_manage_tunnels() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Manage Tunnels${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"

        local configs=("${WW_DIR}"/*.json)
        local count=0
        for cfg in "${configs[@]}"; do
            if [[ ! -e "$cfg" ]]; then
                continue
            fi
            local bname
            bname=$(basename "$cfg")
            if [[ "$bname" == "core.json" ]]; then
                continue
            fi
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
        if is_back "$sub_choice"; then
            return 0
        fi
        if [[ -z "$sub_choice" ]]; then
            return 0
        fi
    done
}

menu_packet_tester() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> WaterWall Packet Tester & Bidirectional Protocol Probe${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "Tests which of the 255 IP protocol numbers pass between two servers, both ways,"
        echo -e "using WaterWall itself. Run it on BOTH servers at about the same time."
        echo ""
        echo -e "Select this server's role:"
        echo -e "  ${GREEN}1)${NC} Iran   (connects to the peer and chooses the test mode)"
        echo -e "  ${GREEN}2)${NC} Kharej (waits for the Iran side; its sync port must be reachable)"
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
        local mode="quick"

        echo ""
        if ! prompt_input "Enter THIS server's Public IP" "$detected_ip" this_ip; then
            continue
        fi

        if ! prompt_input "Enter PEER server's Public IP" "" peer_ip; then
            continue
        fi

        if ! prompt_input "Enter Coordination Port (TCP, must be open on the Kharej server)" "54321" sync_port; then
            continue
        fi

        if [[ "$role_name" == "iran" ]]; then
            echo ""
            echo -e "Test mode:"
            echo -e "  ${GREEN}1)${NC} Quick scan          (about 1 minute)"
            echo -e "  ${GREEN}2)${NC} Scan + load test    (about 1.5 minutes, shows loss at a higher packet rate)"
            read -rp "$(echo -e "${CYAN}Select mode [1-2, default 1]: ${NC}")" mode_choice
            if is_back "$mode_choice"; then
                continue
            fi
            if [[ "$mode_choice" == "2" ]]; then
                mode="full"
            fi
        else
            echo -e "${YELLOW}[i] The test mode is chosen on the Iran side.${NC}"
        fi

        echo ""
        run_packet_probe "$this_ip" "$peer_ip" "$role_name" "$sync_port" "$mode"

        pause_back
        return 0
    done
}

menu_update() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Check & Update (Script + WaterWall Core)${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${CYAN}[*] Checking GitHub for script and WaterWall Core updates...${NC}"
        echo ""

        ACTIVE_TMP_DIR=$(mktemp -d)
        local remote_script="${ACTIVE_TMP_DIR}/wwmng.sh"
        local script_needs_update="false"
        local script_check_ok="false"
        local local_hash=""
        local remote_hash=""

        if curl -fsSL --max-time 10 "$WWMNG_RAW_URL" -o "$remote_script" 2>/dev/null && [[ -s "$remote_script" ]]; then
            script_check_ok="true"
            if [[ -f "$WWMNG_BIN" ]]; then
                local_hash=$(sha256sum "$WWMNG_BIN" 2>/dev/null | awk '{print $1}')
            else
                local_hash=$(sha256sum "$0" 2>/dev/null | awk '{print $1}')
            fi
            remote_hash=$(sha256sum "$remote_script" 2>/dev/null | awk '{print $1}')
            if [[ "$local_hash" != "$remote_hash" ]]; then
                script_needs_update="true"
            fi
        fi

        local release_json
        release_json=$(curl -fsSL --max-time 10 "$WW_API_LATEST" 2>/dev/null)
        local latest_core_tag=""
        local installed_core_tag="Not Installed"
        local core_needs_update="false"
        local core_check_ok="false"

        if [[ -f "$WW_VER_FILE" ]]; then
            installed_core_tag=$(cat "$WW_VER_FILE")
        fi

        if [[ -n "$release_json" ]]; then
            latest_core_tag=$(echo "$release_json" | jq -r '.tag_name // empty')
            if [[ -n "$latest_core_tag" ]]; then
                core_check_ok="true"
                if [[ ! -x "$WW_BIN" || "$installed_core_tag" != "$latest_core_tag" ]]; then
                    core_needs_update="true"
                fi
            fi
        fi

        # Display status summary
        if [[ "$script_check_ok" == "true" ]]; then
            if [[ "$script_needs_update" == "true" ]]; then
                echo -e "  * ${BOLD}Waterwall-Manager (wwmng)${NC} : ${YELLOW}Update available${NC} (${local_hash:0:7} -> ${remote_hash:0:7})"
            else
                echo -e "  * ${BOLD}Waterwall-Manager (wwmng)${NC} : ${GREEN}Up to date${NC} (${local_hash:0:7})"
            fi
        else
            echo -e "  * ${BOLD}Waterwall-Manager (wwmng)${NC} : ${RED}Could not check GitHub${NC}"
        fi

        if [[ "$core_check_ok" == "true" ]]; then
            if [[ "$core_needs_update" == "true" ]]; then
                echo -e "  * ${BOLD}WaterWall Core${NC}            : ${YELLOW}Update available${NC} (${installed_core_tag} -> ${latest_core_tag})"
            else
                echo -e "  * ${BOLD}WaterWall Core${NC}            : ${GREEN}Up to date${NC} (${installed_core_tag})"
            fi
        else
            echo -e "  * ${BOLD}WaterWall Core${NC}            : ${RED}Could not check GitHub${NC}"
        fi

        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"

        if [[ "$script_needs_update" == "false" && "$core_needs_update" == "false" ]]; then
            echo -e "${GREEN}[✓] Both Waterwall-Manager and WaterWall Core are already on the latest version.${NC}"
            echo ""
            echo -e "  ${GREEN}1)${NC} Force Re-install Both (Script + Core)"
            echo -e "  ${CYAN}0)${NC} Back to Main Menu"
            echo ""
            read -rp "$(echo -e "${CYAN}Select an option [0-1]: ${NC}")" up_choice
            if is_back "$up_choice" || [[ -z "$up_choice" ]]; then
                rm -rf "$ACTIVE_TMP_DIR"
                ACTIVE_TMP_DIR=""
                return 0
            fi
            if [[ "$up_choice" == "1" ]]; then
                script_needs_update="true"
                core_needs_update="true"
            else
                rm -rf "$ACTIVE_TMP_DIR"
                ACTIVE_TMP_DIR=""
                continue
            fi
        else
            echo -e "${YELLOW}Do you want to apply the available update(s) now?${NC}"
            echo -e "  ${GREEN}1)${NC} Yes, update now"
            echo -e "  ${CYAN}0)${NC} No, go back"
            echo ""
            read -rp "$(echo -e "${CYAN}Select an option [0-1]: ${NC}")" confirm_up
            if is_back "$confirm_up" || [[ "$confirm_up" != "1" ]]; then
                rm -rf "$ACTIVE_TMP_DIR"
                ACTIVE_TMP_DIR=""
                return 0
            fi
        fi

        echo ""
        local restart_needed="false"

        if [[ "$script_needs_update" == "true" && "$script_check_ok" == "true" ]]; then
            echo -e "${CYAN}[*] Updating Waterwall-Manager script (${WWMNG_BIN})...${NC}"
            cp -f "$remote_script" "$WWMNG_BIN"
            chmod +x "$WWMNG_BIN"
            echo -e "${GREEN}[✓] Waterwall-Manager script updated successfully.${NC}"
            restart_needed="true"
        fi

        rm -rf "$ACTIVE_TMP_DIR"
        ACTIVE_TMP_DIR=""

        if [[ "$core_needs_update" == "true" && "$core_check_ok" == "true" ]]; then
            install_or_update_core "$release_json"
        fi

        if [[ "$restart_needed" == "true" ]]; then
            echo -e "${GREEN}[*] Reloading wwmng with the new version...${NC}"
            sleep 1
            exec "$WWMNG_BIN"
        fi

        pause_back
        return 0
    done
}

menu_uninstall() {
    print_banner
    echo -e "${BOLD}${RED}>>> Complete Uninstall (Waterwall-Manager + WaterWall Core + All Tunnels)${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}This will permanently remove:${NC}"
    echo -e "  * All running WaterWall processes and systemd tunnel services"
    echo -e "  * WaterWall Core binary, configs, logs, and probes in ${BOLD}${WW_DIR}${NC}"
    echo -e "  * The global ${BOLD}wwmng${NC} command at ${BOLD}${WWMNG_BIN}${NC}"
    echo ""
    echo -e "  ${RED}yes)${NC} Confirm Complete Uninstall"
    echo -e "  ${CYAN}0)${NC}   Cancel and Go Back"
    echo ""
    read -rp "$(echo -e "${RED}Type 'yes' to wipe everything, or '0' to go back: ${NC}")" confirm

    if is_back "$confirm"; then
        echo -e "${GREEN}[*] Uninstall cancelled.${NC}"
        sleep 1
        return 0
    fi
    if [[ "${confirm,,}" != "yes" ]]; then
        echo -e "${GREEN}[*] Uninstall cancelled.${NC}"
        sleep 1
        return 0
    fi

    echo ""
    echo -e "${CYAN}[*] Stopping running WaterWall processes...${NC}"
    pkill -TERM -f "${WW_BIN}" 2>/dev/null
    sleep 2
    pkill -9 -f "${WW_BIN}" 2>/dev/null
    purge_ww_rules

    echo -e "${CYAN}[*] Stopping and removing any Waterwall-Manager / WaterWall systemd services...${NC}"
    for svc in /etc/systemd/system/wwmng*.service /etc/systemd/system/waterwall*.service /etc/systemd/system/astro-tun*.service; do
        if [[ ! -e "$svc" ]]; then
            continue
        fi
        local svc_name
        svc_name=$(basename "$svc")
        systemctl stop "$svc_name" 2>/dev/null
        systemctl disable "$svc_name" 2>/dev/null
        rm -f "$svc"
    done
    systemctl daemon-reload 2>/dev/null

    echo -e "${CYAN}[*] Removing installation directories (${WW_DIR} & legacy /opt/astro-tun)...${NC}"
    rm -rf "${WW_DIR}" /opt/astro-tun

    echo -e "${CYAN}[*] Removing global command (${WWMNG_BIN})...${NC}"
    rm -f "${WWMNG_BIN}" /usr/local/bin/astro-tun

    echo -e "${GREEN}[✓] Waterwall-Manager, WaterWall Core, tunnels, and all configs have been completely removed.${NC}"
    exit 0
}

# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================

main_menu() {
    ensure_core_present_on_startup

    while true; do
        print_banner

        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1)${NC} Create a Tunnel"
        echo -e "  ${GREEN}2)${NC} Manage Tunnels"
        echo -e "  ${GREEN}3)${NC} Packet Tester (Bidirectional Probe & Speed Test)"
        echo -e "  ${GREEN}4)${NC} Update"
        echo -e "  ${RED}5)${NC} Uninstall Waterwall-Manager (Wipe Everything)"
        echo -e "  ${CYAN}0)${NC} Exit"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        read -rp "$(echo -e "${CYAN}Select an option [0-5]: ${NC}")" main_choice

        case "${main_choice,,}" in
            1) menu_create_tunnel ;;
            2) menu_manage_tunnels ;;
            3) menu_packet_tester ;;
            4) menu_update ;;
            5) menu_uninstall ;;
            0|e|exit|q|quit|b|back)
                echo -e "${GREEN}Exiting Waterwall-Manager. Goodbye!${NC}"
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
