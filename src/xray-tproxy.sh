#!/usr/bin/env ash
# shellcheck shell=dash
#
# Xray Transparent Proxy Management for OpenWrt (TPROXY method).
# Tested on: OpenWrt 25.12.4
#
# Required Xray configuration snippet (config.json):
# "inbounds": [
#   {
#     "tag": "transparent-tproxy",
#     "port": 10807,
#     "protocol": "dokodemo-door",
#     "settings": { "network": "tcp,udp", "followRedirect": true },
#     "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
#     "sniffing": {
#       "enabled": true,
#       "destOverride": [ "http", "tls", "quic" ],
#       "routeOnly": true
#     }
#   }
# ]
#
# This script creates an isolated nftables table for TPROXY routing,
# avoiding interference with fw4 internals. It routes both TCP and UDP
# through Xray, effectively preventing DNS and QUIC leaks.

set -eu

readonly SCRIPT_VERSION="0.2.0"
readonly XRAY_CONF_FILE="/etc/xray/config.json"
readonly NFT_RULE_FILE="/etc/xray/xray-tproxy.nft"

readonly TPROXY_PORT="${XRAY_TPROXY_PORT:-10807}"
readonly TPROXY_MARK="1"
readonly ROUTE_TABLE="100"
readonly LAN_SUBNET="192.168.1.0/24"

#######################################
# Wraps text in ANSI color codes for terminal output.
# Globals:
#   None
# Arguments:
#   1: Color name (e.g., red, green)
#   2: Text string to format
# Outputs:
#   Writes colorized string to stdout.
# Returns:
#   0
#######################################
colorize() {
  local color="$1"
  local text="$2"
  local code

  case "${color}" in
    red)    code='\033[0;31m' ;;
    green)  code='\033[0;32m' ;;
    yellow) code='\033[0;33m' ;;
    blue)   code='\033[0;34m' ;;
    *)      code='\033[0m'    ;;
  esac
  printf "%b%s\033[0m" "${code}" "${text}"
}

#######################################
# Unified logging function.
# Globals:
#   None
# Arguments:
#   1: Log level (info, success, warn, error)
#   2: Message string
# Outputs:
#   Writes formatted log messages to stdout or stderr.
# Returns:
#   0
#######################################
log() {
  local level="$1"
  local msg="$2"

  case "${level}" in
    info)    printf "%s %s\n" "$(colorize blue "INFO:")" "${msg}" ;;
    success) printf "%s %s\n" "$(colorize green "SUCCESS:")" "${msg}" ;;
    warn)    printf "%s %s\n" "$(colorize yellow "WARN:")" "${msg}" ;;
    error)   printf "%s %s\n" "$(colorize red "ERROR:")" "${msg}" >&2 ;;
    *)       printf "%s\n" "${msg}" ;;
  esac
}

#######################################
# Validates existence of required system utilities.
# Globals:
#   None
# Arguments:
#   $@: List of command names to verify
# Outputs:
#   Writes error messages for missing tools to stderr.
# Returns:
#   0 if all tools are found, 1 otherwise.
#######################################
check_deps() {
  local missing=""
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
      missing="${missing}${cmd} "
    fi
  done
  if [ -n "${missing}" ]; then
    log error "Missing dependencies: ${missing}"
    return 1
  fi

  # Check for kernel tproxy support
  if ! lsmod | grep -q "tproxy"; then
    # Try to load it if installed but not loaded
    if ! modprobe nft_tproxy 2>/dev/null; then
      log error "Missing TPROXY kernel modules. Please install them:"
      log error "apk add kmod-nft-tproxy kmod-nf-tproxy"
      return 1
    fi
  fi

  return 0
}

#######################################
# Configures UCI settings and creates nftables rule file.
# Globals:
#   XRAY_CONF_FILE
#   NFT_RULE_FILE
#   LAN_SUBNET
#   TPROXY_PORT
#   TPROXY_MARK
# Arguments:
#   None
# Outputs:
#   Writes configuration state to system and standard output.
# Returns:
#   0 on success.
#######################################
cmd_setup() {
  log info "Setting up UCI configuration for Xray..."

  uci -q delete xray.enabled || true
  uci -q delete xray.config || true
  uci set xray.enabled=enabled
  uci set xray.enabled.enabled='1'
  uci set xray.config=config
  uci set xray.config.format='json'
  uci set xray.config.conffiles="${XRAY_CONF_FILE}"
  uci commit xray

  log info "Generating ${NFT_RULE_FILE}..."
  mkdir -p /etc/xray

  local l_nets="127.0.0.0/8, 192.168.0.0/16, 10.0.0.0/8"
  local o_nets="172.16.0.0/12, 224.0.0.0/4, 255.255.255.255/32"

  cat <<EOF > "${NFT_RULE_FILE}"
table inet fw4 {
  chain xray_tproxy {
    # Only process LAN traffic
    ip saddr != ${LAN_SUBNET} return

    # Bypass local network destinations
    ip daddr { ${l_nets}, ${o_nets} } return

    # Apply TPROXY for TCP and UDP
    meta l4proto { tcp, udp } tproxy to :${TPROXY_PORT} meta mark set ${TPROXY_MARK} accept
  }
}
EOF

  log success "Setup complete. Run 'start' to apply and launch."
  return 0
}

#######################################
# Removes configuration and cleans up files.
# Globals:
#   NFT_RULE_FILE
# Arguments:
#   None
# Outputs:
#   Writes progress logs to stdout.
# Returns:
#   0 on success.
#######################################
cmd_teardown() {
  log info "Stopping service and flushing rules..."
  cmd_stop || true

  log info "Cleaning up UCI and rule files..."

  uci -q delete xray.enabled || true
  uci commit xray

  rm -f "${NFT_RULE_FILE}"

  log success "Teardown complete."
  return 0
}

#######################################
# Starts Xray daemon and applies TPROXY rules.
# Globals:
#   NFT_RULE_FILE
#   TPROXY_MARK
#   ROUTE_TABLE
# Arguments:
#   None
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success, 1 on error.
#######################################
cmd_start() {
  log info "Enabling and starting Xray service..."
  /etc/init.d/xray enable
  /etc/init.d/xray start

  log info "Applying policy routing..."
  ip rule add fwmark "${TPROXY_MARK}" table "${ROUTE_TABLE}" \
    2>/dev/null || true
  ip route add local default dev lo table "${ROUTE_TABLE}" \
    2>/dev/null || true

  log info "Applying nftables TPROXY rules..."
  if [ ! -f "${NFT_RULE_FILE}" ]; then
    log error "Rule file ${NFT_RULE_FILE} not found. Run 'setup'."
    return 1
  fi

  nft -f "${NFT_RULE_FILE}"
  nft add rule inet fw4 mangle_prerouting jump xray_tproxy

  log success "Xray started and transparent proxy is active."
  return 0
}

#######################################
# Stops Xray and flushes TPROXY routing rules.
# Globals:
#   TPROXY_MARK
#   ROUTE_TABLE
# Arguments:
#   None
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 on success.
#######################################
cmd_stop() {
  log info "Stopping Xray service..."
  /etc/init.d/xray stop || true
  /etc/init.d/xray disable || true

  log info "Flushing active nftables TPROXY rules..."
  local line handle
  line=$(nft -a list chain inet fw4 mangle_prerouting 2>/dev/null | \
    grep 'jump xray_tproxy' || true)
  if [ -n "${line}" ]; then
    handle="${line##* }"
    nft delete rule inet fw4 mangle_prerouting handle "${handle}" \
      2>/dev/null || true
  fi
  nft flush chain inet fw4 xray_tproxy 2>/dev/null || true
  nft delete chain inet fw4 xray_tproxy 2>/dev/null || true

  log info "Removing policy routing..."
  while ip rule del fwmark "${TPROXY_MARK}" table "${ROUTE_TABLE}" \
    2>/dev/null; do :; done
  ip route del local default dev lo table "${ROUTE_TABLE}" \
    2>/dev/null || true

  log success "Xray stopped. Default routing restored."
  return 0
}

#######################################
# Checks and displays current status.
# Globals:
#   TPROXY_MARK
#   ROUTE_TABLE
# Arguments:
#   None
# Outputs:
#   Writes status to stdout.
# Returns:
#   0 if running, 1 otherwise.
#######################################
cmd_status() {
  local all_ok=true

  if /etc/init.d/xray status >/dev/null 2>&1; then
    log success "Xray service is running."
  else
    log warn "Xray service is NOT running."
    all_ok=false
  fi

  if ip rule list | grep -q "fwmark 0x${TPROXY_MARK} lookup ${ROUTE_TABLE}"; then
    log success "TPROXY policy routing is active."
  else
    log warn "TPROXY policy routing is NOT active."
    all_ok=false
  fi

  if nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -q 'jump xray_tproxy'; then
    log success "nftables TPROXY rules are applied."
  else
    log warn "nftables TPROXY rules are NOT applied."
    all_ok=false
  fi

  if [ "${all_ok}" = "true" ]; then
    log success "TPROXY is fully active and configured correctly."
    return 0
  else
    log error "TPROXY is partially or completely disabled."
    return 1
  fi
}

#######################################
# Displays script version.
# Globals:
#   SCRIPT_VERSION
# Arguments:
#   None
# Outputs:
#   Writes version to stdout.
# Returns:
#   0
#######################################
show_version() {
  local name="${0##*/}"
  name="${name%.sh}"
  printf "%s version %s\n" "${name}" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Displays detailed usage information.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes usage help to stdout.
# Returns:
#   0
#######################################
usage() {
  local name="${0##*/}"
  name="${name%.sh}"
  cat << EOF
Usage: $(colorize yellow "${name}") $(colorize green "COMMAND")

OpenWrt Xray TPROXY Manager.
Tested on: OpenWrt 25.12.4

$(colorize blue "Commands:")
  $(colorize green "setup")     Prepares config and generates rule files.
  $(colorize green "start")     Starts Xray and applies firewall routing.
  $(colorize green "status")    Checks if Xray and routing are active.
  $(colorize green "stop")      Stops Xray and flushes active rules.
  $(colorize green "teardown")  Removes configurations and files.

$(colorize blue "Global Options:")
  -h, --help     Show this help message.
  -v, --version  Show the script version.

$(colorize blue "Environment:")
  XRAY_TPROXY_PORT  Overrides the default port (10807).
EOF
}

#######################################
# Script entry point.
# Globals:
#   None
# Arguments:
#   $@: Command line arguments
# Outputs:
#   Dispatches to subcommands.
# Returns:
#   0 on success, 1 on failure.
#######################################
main() {
  if ! check_deps uci nft xray ip; then
    return 1
  fi

  if [ $# -eq 0 ]; then
    usage
    return 1
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    setup)
      cmd_setup || return 1
      ;;
    start)
      cmd_start || return 1
      ;;
    status)
      cmd_status || return 1
      ;;
    stop)
      cmd_stop || return 1
      ;;
    teardown)
      cmd_teardown || return 1
      ;;
    -v|--version|version)
      show_version
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      log error "Unknown command: ${cmd}"
      usage
      return 1
      ;;
  esac
}

if ! main "$@"; then
  exit 1
fi
