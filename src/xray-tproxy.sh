#!/usr/bin/env ash
# shellcheck shell=dash
#
# Xray Transparent Proxy Management for OpenWrt (NAT REDIRECT method).
# Tested on: OpenWrt 25.12.4 r32933-4ccb782af7
#
# Required Xray configuration snippet (config.json):
# "inbounds": [
#   {
#     "tag": "transparent-tproxy",
#     "port": 10807,
#     "protocol": "dokodemo-door",
#     "settings": { "network": "tcp,udp", "followRedirect": true },
#     "streamSettings": { "sockopt": { "tproxy": "redirect" } },
#     "sniffing": {
#       "enabled": true,
#       "destOverride": [ "http", "tls", "quic" ],
#       "routeOnly": true
#     }
#   }
# ]
#
# Firewall (fw4/nftables) Note:
# This script injects a custom chain `xray_redirect` directly into the
# `fw4` inet table and links it via a jump from the standard `dstnat` chain.
# This approach ensures full compatibility with the modern fw4 architecture
# without requiring separate custom tables or `firewall.user` scripts.
#

set -eu

readonly SCRIPT_VERSION="0.1.0"
readonly XRAY_CONF_FILE="/etc/xray/config.json"
readonly NFT_RULE_FILE="/etc/xray/xray-redirect.nft"

# Default port, can be overridden via environment variable
readonly REDIRECT_PORT="${XRAY_REDIRECT_PORT:-10807}"

#######################################
# Wraps text in ANSI color codes for terminal output.
# Arguments:
#   1: Color name
#   2: Text string
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
# Arguments:
#   1: Log level
#   2: Message string
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
  return 0
}

#######################################
# Configures UCI settings and creates nftables rule file.
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

  local local_nets="127.0.0.0/8, 192.168.0.0/16, 10.0.0.0/8"
  local other_nets="172.16.0.0/12, 224.0.0.0/4, 255.255.255.255/32"

  cat <<EOF > "${NFT_RULE_FILE}"
# Xray REDIRECT rules for fw4
table inet fw4 {
    chain xray_redirect {
        # Only process LAN traffic
        ip saddr != 192.168.1.0/24 return

        # Bypass local network destinations
        ip daddr { ${local_nets}, ${other_nets} } return

        # Redirect TCP traffic to Xray
        meta l4proto tcp redirect to :${REDIRECT_PORT}
    }
}
EOF

  log success "Setup complete. Run 'start' to apply and launch."
  return 0
}

#######################################
# Removes configuration and cleans up files.
# Returns:
#   0 on success.
#######################################
cmd_teardown() {
  log info "Cleaning up UCI and rule files..."

  uci -q delete xray.enabled || true
  uci commit xray

  rm -f "${NFT_RULE_FILE}"

  log success "Teardown complete."
  return 0
}

#######################################
# Starts Xray daemon and applies rules.
# Returns:
#   0 on success, 1 on error.
#######################################
cmd_start() {
  log info "Enabling and starting Xray service..."
  /etc/init.d/xray enable
  /etc/init.d/xray start

  log info "Applying nftables REDIRECT rules..."
  if [ ! -f "${NFT_RULE_FILE}" ]; then
    log error "Rule file ${NFT_RULE_FILE} not found. Run 'setup' first."
    return 1
  fi

  # Inject our rules directly into fw4 dstnat chain
  nft -f "${NFT_RULE_FILE}"
  nft add rule inet fw4 dstnat jump xray_redirect

  log success "Xray started and routing is active."
  return 0
}

#######################################
# Stops Xray and flushes routing rules.
# Returns:
#   0 on success.
#######################################
cmd_stop() {
  log info "Stopping Xray service..."
  /etc/init.d/xray stop || true
  /etc/init.d/xray disable || true

  log info "Flushing active nftables Xray rules..."

  local rule_line handle
  # Extract the handle of the jump rule we added to dstnat
  rule_line=$(nft -a list chain inet fw4 dstnat 2>/dev/null \
    | grep 'jump xray_redirect' || true)

  if [ -n "$rule_line" ]; then
    handle="${rule_line##* }"
    nft delete rule inet fw4 dstnat handle "$handle" 2>/dev/null || true
  fi

  # Flush and delete our custom chain
  nft flush chain inet fw4 xray_redirect 2>/dev/null || true
  nft delete chain inet fw4 xray_redirect 2>/dev/null || true

  log success "Xray stopped. Default routing restored."
  return 0
}

#######################################
# Displays script version.
#######################################
show_version() {
  local name="${0##*/}"
  name="${name%.sh}"
  printf "%s version %s\n" "${name}" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Displays detailed usage information.
#######################################
usage() {
  local name="${0##*/}"
  name="${name%.sh}"
  cat << EOF
Usage: $(colorize yellow "${name}") $(colorize green "COMMAND")

OpenWrt Xray REDIRECT Manager.
Tested on: OpenWrt 25.12.4

$(colorize blue "Commands:")
  $(colorize green "setup")     Prepares config and generates rule files.
  $(colorize green "start")     Starts Xray and applies firewall routing.
  $(colorize green "stop")      Stops Xray and flushes active rules.
  $(colorize green "teardown")  Removes configurations and files.

$(colorize blue "Global Options:")
  -h, --help     Show this help message.
  -v, --version  Show the script version.

$(colorize blue "Environment:")
  XRAY_REDIRECT_PORT  Overrides the default port (10807).
EOF
}

#######################################
# Script entry point.
#######################################
main() {
  if ! check_deps uci nft xray grep; then
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
