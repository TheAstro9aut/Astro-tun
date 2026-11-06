#!/usr/bin/env bash

# ==============================================================================
# Transport Module: BitSwapMux (Multi-Port TCP & UDP + TUN + XOR + BitSwap + Raw)
# Loaded by: /usr/local/bin/wwmng
# ==============================================================================

VALID_TCP_BITS=("syn" "psh" "rst" "ack" "fin" "urg" "ece" "cwr")

is_valid_tcp_bit() {
    local candidate="${1,,}"
    local b
    for b in "${VALID_TCP_BITS[@]}"; do
        if [[ "$b" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

prompt_yes_no() {
    local prompt_text="$1"
    local default_ans="${2:-Y}"
    local var_name="$3"
    local reply=""

    while true; do
        if [[ "$default_ans" == "Y" ]]; then
            read -rp "$(echo -e "${CYAN}${prompt_text} [${GREEN}Y/n${CYAN}] (or '0' to go back): ${NC}")" reply
        else
            read -rp "$(echo -e "${CYAN}${prompt_text} [${GREEN}y/N${CYAN}] (or '0' to go back): ${NC}")" reply
        fi

        if is_back "$reply"; then
            return 1
        fi

        if [[ -z "$reply" ]]; then
            reply="$default_ans"
        fi

        case "${reply,,}" in
            y|yes)
                printf -v "$var_name" '%s' "yes"
                return 0
                ;;
            n|no)
                printf -v "$var_name" '%s' "no"
                return 0
                ;;
            *)
                echo -e "${RED}[!] Please answer y or n (or 0 to go back).${NC}"
                ;;
        esac
    done
}

# Formats "60627, 48843, 2096" or "60627 48843 2096" into "[60627, 48843, 2096]"
format_port_array() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr ',' ' ' | tr -s ' ')
    local arr=()
    local p
    for p in $cleaned; do
        if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le 65535 ]]; then
            arr+=("$p")
        else
            return 1
        fi
    done
    if [[ ${#arr[@]} -eq 0 ]]; then
        return 1
    fi
    local joined=""
    local i
    for (( i=0; i<${#arr[@]}; i++ )); do
        if [[ $i -gt 0 ]]; then
            joined="${joined}, "
        fi
        joined="${joined}${arr[$i]}"
    done
    echo "[${joined}]"
    return 0
}

prompt_bit_pair() {
    local direction_label="$1"
    local def_bit1="$2"
    local def_bit2="$3"
    local out_bit1="$4"
    local out_bit2="$5"
    local b1=""
    local b2=""

    while true; do
        echo ""
        echo -e "${BOLD}${WHITE}Configure ${direction_label}:${NC}"
        echo -e "  Valid TCP flags in WaterWall: ${GREEN}syn, psh, rst, ack, fin, urg, ece, cwr${NC}"
        if ! prompt_input "  First TCP bit" "$def_bit1" b1; then
            return 1
        fi
        b1="${b1,,}"
        if ! is_valid_tcp_bit "$b1"; then
            echo -e "${RED}  [!] Invalid TCP bit '${b1}'. Choose from: syn, psh, rst, ack, fin, urg, ece, cwr${NC}"
            continue
        fi

        if ! prompt_input "  Second TCP bit to swap with '${b1}'" "$def_bit2" b2; then
            return 1
        fi
        b2="${b2,,}"
        if ! is_valid_tcp_bit "$b2"; then
            echo -e "${RED}  [!] Invalid TCP bit '${b2}'. Choose from: syn, psh, rst, ack, fin, urg, ece, cwr${NC}"
            continue
        fi

        if [[ "$b1" == "$b2" ]]; then
            echo -e "${RED}  [!] The two TCP bits must be different to swap them (e.g., psh and syn).${NC}"
            continue
        fi

        printf -v "$out_bit1" '%s' "$b1"
        printf -v "$out_bit2" '%s' "$b2"
        return 0
    done
}

write_bitswapmux_configs() {
    local role="$1"
    local iran_ip="$2"
    local kharej_ip="$3"
    local ports_json_array="$4"
    local port_tcp_mux="$5"
    local port_udp_mux="$6"
    local mux_conns="$7"
    local final_ip="$8"
    local xor_key="$9"
    local cfg_file="${10}"
    local mtu_val="${11}"
    local up_b1="${12}"
    local up_b2="${13}"
    local dw_b1="${14}"
    local dw_b2="${15}"

    local cfg_path="${WW_DIR}/${cfg_file}"
    ROLLBACK_FILES=("$cfg_path" "$WW_CORE_JSON")

    if [[ "$role" == "iran" ]]; then
        cat > "$cfg_path" <<EOF
{
    "name": "iran-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "${iran_ip}",
        "ip_server_kharej": "${kharej_ip}",
        "port_tcp_mux": ${port_tcp_mux},
        "port_udp_mux": ${port_udp_mux},
        "each_worker_mux_connections_count": ${mux_conns}
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${ports_json_array},
                "nodelay": true,
                "large-send-buffer": true,
                "large-recv-buffer": true
            },
            "next": "header-tcp"
        },
        {
            "name": "header-tcp",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "mux-client-tcp"
        },
        {
            "name": "mux-client-tcp",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "tcp-out-tcp"
        },
        {
            "name": "tcp-out-tcp",
            "type": "TcpConnector",
            "settings": {
                "address": "10.10.0.2",
                "port": \$port_tcp_mux\$,
                "nodelay": true
            }
        },
        {
            "name": "users_inbound_udp",
            "type": "UdpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${ports_json_array},
                "large-send-buffer": true,
                "large-recv-buffer": true
            },
            "next": "udp-client"
        },
        {
            "name": "udp-client",
            "type": "UdpOverTcpClient",
            "settings": {},
            "next": "header-udp"
        },
        {
            "name": "header-udp",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "mux-client-udp"
        },
        {
            "name": "mux-client-udp",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "tcp-out-udp"
        },
        {
            "name": "tcp-out-udp",
            "type": "TcpConnector",
            "settings": {
                "address": "10.10.0.2",
                "port": \$port_udp_mux\$,
                "nodelay": true
            }
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun1",
                "device-ip": "10.10.0.1/24",
                "device-mtu": ${mtu_val}
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_iran\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_kharej\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "10.10.0.2"
                    },
                    "dest-ip": {
                        "ipv4": "10.10.0.1"
                    }
                }
            },
            "next": "splitter"
        },
        {
            "name": "splitter",
            "type": "PacketSplitStream",
            "settings": {
                "up": "obfuscator-c",
                "down": "obfuscator-s"
            }
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": ${xor_key},
                "skip": "transport"
            },
            "next": "ip-manipulator-up"
        },
        {
            "name": "ip-manipulator-up",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-${up_b1}": "packet->${up_b2}",
                "up-tcp-bit-${up_b2}": "packet->${up_b1}"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.12.12.12/32"
            }
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": ${xor_key},
                "skip": "transport"
            },
            "next": "ip-manipulator"
        },
        {
            "name": "ip-manipulator",
            "type": "IpManipulator",
            "settings": {
                "dw-tcp-bit-${dw_b1}": "packet->${dw_b2}",
                "dw-tcp-bit-${dw_b2}": "packet->${dw_b1}"
            },
            "next": "rd2"
        },
        {
            "name": "rd2",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_kharej\$
            }
        }
    ]
}
EOF
    else
        cat > "$cfg_path" <<EOF
{
  "name": "foreign-tcp-bitswap-mux",
  "variables": {
    "ip_server_iran": "${iran_ip}",
    "ip_server_kharej": "${kharej_ip}",
    "port_tcp_mux": ${port_tcp_mux},
    "port_udp_mux": ${port_udp_mux},
    "final_ip": "${final_ip}"
  },
  "nodes": [
    {
      "name": "users_inbound",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": \$port_tcp_mux\$,
        "nodelay": true,
        "large-send-buffer": true,
        "large-recv-buffer": true
      },
      "next": "mux-s"
    },
    {
      "name": "mux-s",
      "type": "MuxServer",
      "settings": {},
      "next": "header-server"
    },
    {
      "name": "header-server",
      "type": "HeaderServer",
      "settings": {
        "override": "dest_context->port"
      },
      "next": "tcp-out"
    },
    {
      "name": "tcp-out",
      "type": "TcpConnector",
      "settings": {
        "address": \$final_ip\$,
        "port": "dest_context->port",
        "nodelay": true
      }
    },
    {
      "name": "users_inbound_udp",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": \$port_udp_mux\$,
        "nodelay": true,
        "large-send-buffer": true,
        "large-recv-buffer": true
      },
      "next": "mux-s-udp"
    },
    {
      "name": "mux-s-udp",
      "type": "MuxServer",
      "settings": {},
      "next": "header-server-udp"
    },
    {
      "name": "header-server-udp",
      "type": "HeaderServer",
      "settings": {
        "override": "dest_context->port"
      },
      "next": "udp-server-node"
    },
    {
      "name": "udp-server-node",
      "type": "UdpOverTcpServer",
      "settings": {},
      "next": "udp-out"
    },
    {
      "name": "udp-out",
      "type": "UdpConnector",
      "settings": {
        "address": \$final_ip\$,
        "port": "dest_context->port",
        "large-send-buffer": true,
        "large-recv-buffer": true
      }
    },
    {
      "name": "my tun2",
      "type": "TunDevice",
      "settings": {
        "device-name": "wtun2",
        "device-ip": "10.20.0.1/24",
        "device-mtu": ${mtu_val}
      },
      "next": "ipcorrect"
    },
    {
      "name": "ipcorrect",
      "type": "IpOverrider",
      "settings": {
        "up": {
          "source-ip": {
            "ipv4": "10.10.0.2"
          },
          "dest-ip": {
            "ipv4": "10.10.0.1"
          }
        },
        "down": {
          "source-ip": {
            "ipv4": "10.10.0.2"
          },
          "dest-ip": {
            "ipv4": "10.10.0.1"
          }
        }
      },
      "next": "obfuscator-s"
    },
    {
      "name": "obfuscator-s",
      "type": "ObfuscatorServer",
      "settings": {
        "method": "xor",
        "xor_key": ${xor_key},
        "skip": "transport"
      },
      "next": "ip-manipulator-in"
    },
    {
      "name": "ip-manipulator-in",
      "type": "IpManipulator",
      "settings": {
        "dw-tcp-bit-${dw_b1}": "packet->${dw_b2}",
        "dw-tcp-bit-${dw_b2}": "packet->${dw_b1}"
      },
      "next": "rdin"
    },
    {
      "name": "rdin",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": \$ip_server_iran\$
      }
    },
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "wtun1",
        "device-ip": "10.10.0.1/24",
        "device-mtu": ${mtu_val}
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "up": {
          "source-ip": {
            "ipv4": \$ip_server_kharej\$
          },
          "dest-ip": {
            "ipv4": \$ip_server_iran\$
          }
        },
        "down": {
          "source-ip": {
            "ipv4": "10.10.0.2"
          },
          "dest-ip": {
            "ipv4": "10.10.0.1"
          }
        }
      },
      "next": "obfuscator-c"
    },
    {
      "name": "obfuscator-c",
      "type": "ObfuscatorClient",
      "settings": {
        "method": "xor",
        "xor_key": ${xor_key},
        "skip": "transport"
      },
      "next": "ip-manipulator"
    },
    {
      "name": "ip-manipulator",
      "type": "IpManipulator",
      "settings": {
        "up-tcp-bit-${up_b1}": "packet->${up_b2}",
        "up-tcp-bit-${up_b2}": "packet->${up_b1}"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "12.13.12.13"
      }
    }
  ]
}
EOF
    fi

    # Write core.json matching your exact template
    cat > "$WW_CORE_JSON" <<EOF
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "DEBUG",
            "file": "internal.log",
            "console": true
        },
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
            "loglevel": "DEBUG",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 0,
        "ram-profile": "server",
        "mtu": ${mtu_val},
        "libs-path": "libs/"
    },
    "configs": [
        "${cfg_file}"
    ]
}
EOF

    ROLLBACK_FILES=()
    return 0
}

run_bitswapmux_wizard() {
    while true; do
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Create Tunnel: BitSwapMux (Multi-Port TCP + UDP + TUN + XOR + BitSwap)${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "Select this server's role:"
        echo -e "  ${GREEN}1)${NC} Iran            (Default config: ${BOLD}config_iran.json${NC})"
        echo -e "  ${GREEN}2)${NC} Foreign / Kharej (Default config: ${BOLD}config_kharej.json${NC})"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -rp "$(echo -e "${CYAN}Select server role [0-2]: ${NC}")" role_opt

        if is_back "$role_opt"; then
            return 0
        fi

        local role=""
        local default_cfg=""
        case "$role_opt" in
            1)
                role="iran"
                default_cfg="config_iran.json"
                ;;
            2)
                role="kharej"
                default_cfg="config_kharej.json"
                ;;
            *)
                echo -e "${RED}[!] Invalid option. Please select 1, 2, or 0.${NC}"
                sleep 1
                continue
                ;;
        esac

        local detected_ip
        detected_ip=$(get_public_ip)
        local iran_ip=""
        local kharej_ip=""
        local raw_ports=""
        local ports_json_array="[]"
        local port_tcp_mux="44431"
        local port_udp_mux="44432"
        local mux_conns="8"
        local final_ip="127.0.0.1"
        local xor_key="90"
        local use_def_cfg=""
        local cfg_file=""
        local use_def_mtu=""
        local mtu_val="1400"

        echo ""
        if [[ "$role" == "iran" ]]; then
            if ! prompt_input "Enter Iran Server Public IP (THIS server)" "$detected_ip" iran_ip; then
                continue
            fi
            if ! prompt_input "Enter Foreign (Kharej) Server Public IP" "" kharej_ip; then
                continue
            fi

            while true; do
                echo ""
                echo -e "${YELLOW}[i] Enter one or multiple user inbound ports (carries both TCP & UDP).${NC}"
                if ! prompt_input "Tunneled Ports (comma-separated, e.g. 60627, 48843, 2096)" "60627, 48843, 2096" raw_ports; then
                    ports_json_array=""
                    break
                fi
                if ports_json_array=$(format_port_array "$raw_ports"); then
                    break
                else
                    echo -e "${RED}[!] Invalid port list. Enter valid port numbers (1-65535) separated by commas.${NC}"
                fi
            done
            if [[ -z "$ports_json_array" ]]; then
                continue
            fi

            echo ""
            echo -e "${YELLOW}[i] WaterWall-to-WaterWall internal Mux ports (must match Foreign server & not be used by Xray/SS):${NC}"
            if ! prompt_input "Enter TCP Mux Transport Port (port_tcp_mux)" "44431" port_tcp_mux; then
                continue
            fi
            if ! prompt_input "Enter UDP Mux Transport Port (port_udp_mux)" "44432" port_udp_mux; then
                continue
            fi
            if ! prompt_input "Enter Mux connections per worker (each_worker_mux_connections_count)" "8" mux_conns; then
                continue
            fi
        else
            if ! prompt_input "Enter Foreign (Kharej) Server Public IP (THIS server)" "$detected_ip" kharej_ip; then
                continue
            fi
            if ! prompt_input "Enter Iran Server Public IP" "" iran_ip; then
                continue
            fi

            echo ""
            echo -e "${YELLOW}[i] WaterWall-to-WaterWall internal Mux ports (must match Iran server & not be used by Xray/SS):${NC}"
            if ! prompt_input "Enter TCP Mux Transport Port (port_tcp_mux)" "44431" port_tcp_mux; then
                continue
            fi
            if ! prompt_input "Enter UDP Mux Transport Port (port_udp_mux)" "44432" port_udp_mux; then
                continue
            fi
            echo ""
            echo -e "${YELLOW}[i] All tunneled TCP & UDP ports from Iran are restored automatically via HeaderServer and sent to final_ip.${NC}"
            if ! prompt_input "Enter Local Target IP on Foreign Server (final_ip)" "127.0.0.1" final_ip; then
                continue
            fi
        fi

        echo ""
        if ! prompt_input "Enter Obfuscator XOR Key (0-255, must match on both servers)" "90" xor_key; then
            continue
        fi

        # Config file name with default (Y/n)
        echo ""
        if ! prompt_yes_no "Use default tunnel config filename '${default_cfg}'?" "Y" use_def_cfg; then
            continue
        fi
        if [[ "$use_def_cfg" == "yes" ]]; then
            cfg_file="$default_cfg"
        else
            if ! prompt_input "Enter custom tunnel config filename" "$default_cfg" cfg_file; then
                continue
            fi
            if [[ "$cfg_file" != *.json ]]; then
                cfg_file="${cfg_file}.json"
            fi
        fi

        # MTU for core.json & TunDevice with default (Y/n) of 1400
        echo ""
        if ! prompt_yes_no "Use default MTU of 1400 in core.json and TunDevice?" "Y" use_def_mtu; then
            continue
        fi
        if [[ "$use_def_mtu" == "yes" ]]; then
            mtu_val="1400"
        else
            if ! prompt_input "Enter custom MTU (e.g. 1350 - 1500)" "1350" mtu_val; then
                continue
            fi
        fi

        # TCP Bit Swap configuration for UP and DW
        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${YELLOW}${BOLD}[!] TCP BIT-SWAP PAIRING RULE (MUST MATCH ACROSS IRAN & FOREIGN):${NC}"
        echo -e "${YELLOW}    * Iran UP bits (Iran -> Foreign)  MUST equal  Foreign DW bits (ip-manipulator-in)${NC}"
        echo -e "${YELLOW}    * Iran DW bits (Foreign -> Iran)  MUST equal  Foreign UP bits (ip-manipulator)${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"

        local up_b1=""
        local up_b2=""
        local dw_b1=""
        local dw_b2=""

        if [[ "$role" == "iran" ]]; then
            if ! prompt_bit_pair "Iran UP Bits (up-tcp-bit in ip-manipulator-up, must match Foreign DW)" "psh" "syn" up_b1 up_b2; then
                continue
            fi
            if ! prompt_bit_pair "Iran DW Bits (dw-tcp-bit in ip-manipulator, must match Foreign UP)" "psh" "rst" dw_b1 dw_b2; then
                continue
            fi
        else
            if ! prompt_bit_pair "Foreign DW Bits (dw-tcp-bit in ip-manipulator-in, must match Iran UP)" "psh" "syn" dw_b1 dw_b2; then
                continue
            fi
            if ! prompt_bit_pair "Foreign UP Bits (up-tcp-bit in ip-manipulator, must match Iran DW)" "psh" "rst" up_b1 up_b2; then
                continue
            fi
        fi

        # Confirmation Summary
        print_banner
        echo -e "${BOLD}${MAGENTA}>>> Confirm Tunnel Configuration${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  * ${BOLD}Transport${NC}          : ${GREEN}BitSwapMux (Multi-Port TCP + UDP)${NC}"
        echo -e "  * ${BOLD}Server Role${NC}        : ${GREEN}${role^^}${NC}"
        echo -e "  * ${BOLD}Iran Server IP${NC}     : ${CYAN}${iran_ip}${NC}"
        echo -e "  * ${BOLD}Foreign Server IP${NC}  : ${CYAN}${kharej_ip}${NC}"
        if [[ "$role" == "iran" ]]; then
            echo -e "  * ${BOLD}Inbound TCP/UDP${NC}    : ${CYAN}${ports_json_array}${NC}"
            echo -e "  * ${BOLD}Mux Per Worker${NC}     : ${CYAN}${mux_conns}${NC}"
        else
            echo -e "  * ${BOLD}Target final_ip${NC}    : ${CYAN}${final_ip}${NC} (auto-restores all ports via HeaderServer)"
        fi
        echo -e "  * ${BOLD}Mux Ports (TCP/UDP)${NC}: ${CYAN}${port_tcp_mux} / ${port_udp_mux}${NC}"
        echo -e "  * ${BOLD}XOR Obfuscator Key${NC} : ${CYAN}${xor_key}${NC}"
        echo -e "  * ${BOLD}Tunnel Config Name${NC} : ${YELLOW}${cfg_file}${NC} (referenced in core.json)"
        echo -e "  * ${BOLD}MTU (Core & TUN)${NC}   : ${YELLOW}${mtu_val}${NC}"
        echo -e "  * ${BOLD}UP TCP Bit-Swap${NC}    : ${GREEN}\"up-tcp-bit-${up_b1}\": \"packet->${up_b2}\"${NC}, ${GREEN}\"up-tcp-bit-${up_b2}\": \"packet->${up_b1}\"${NC}"
        echo -e "  * ${BOLD}DW TCP Bit-Swap${NC}    : ${GREEN}\"dw-tcp-bit-${dw_b1}\": \"packet->${dw_b2}\"${NC}, ${GREEN}\"dw-tcp-bit-${dw_b2}\": \"packet->${dw_b1}\"${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"

        local confirm_create=""
        if ! prompt_yes_no "Create tunnel configs and start systemd service now?" "Y" confirm_create; then
            continue
        fi

        if [[ "$confirm_create" != "yes" ]]; then
            echo -e "${YELLOW}[*] Tunnel creation cancelled.${NC}"
            sleep 1
            return 0
        fi

        echo ""
        echo -e "${CYAN}[*] Writing ${cfg_file} and core.json...${NC}"
        write_bitswapmux_configs \
            "$role" "$iran_ip" "$kharej_ip" "$ports_json_array" \
            "$port_tcp_mux" "$port_udp_mux" "$mux_conns" "$final_ip" \
            "$xor_key" "$cfg_file" "$mtu_val" \
            "$up_b1" "$up_b2" "$dw_b1" "$dw_b2"

        echo -e "${CYAN}[*] Installing and starting systemd service (${WW_SERVICE_NAME})...${NC}"
        install_and_start_tunnel_service "$cfg_file"

        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}${BOLD}[✓] Tunnel created and started!${NC}"
        echo -e "  * ${BOLD}Tunnel Config Path${NC} : ${CYAN}${WW_DIR}/${cfg_file}${NC}"
        echo -e "  * ${BOLD}Core Config Path${NC}   : ${CYAN}${WW_CORE_JSON}${NC}"
        echo -e "  * ${BOLD}WaterWall Binary${NC}   : ${CYAN}${WW_BIN}${NC}"
        echo -e "  * ${BOLD}Systemd Service${NC}    : ${CYAN}/etc/systemd/system/${WW_SERVICE_NAME}${NC}"
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"

        local go_main=""
        echo ""
        if prompt_yes_no "Return to the Main Menu?" "Y" go_main; then
            if [[ "$go_main" == "yes" ]]; then
                return 0
            else
                echo -e "${GREEN}Exiting Waterwall-Manager. Goodbye!${NC}"
                exit 0
            fi
        fi
        return 0
    done
}
