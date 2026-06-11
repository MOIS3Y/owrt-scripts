#!/usr/bin/env ash
# shellcheck shell=dash
#
# Xray Transparent Proxy Management for OpenWrt (TPROXY method).
# Tested on: OpenWrt 25.12.4
#
# This script configures routing, firewall rules, and the native xray daemon
# to establish a transparent proxy. It manages its own lifecycle integration
# (init scripts and hotplug hooks) via 'setup' and 'teardown' commands.

set -eu

readonly SCRIPT_VERSION="0.3.0"
readonly XRAY_CONF_FILE="/etc/xray/config.json"
readonly NFT_RULE_FILE="/etc/xray/xray-tproxy.nft"
readonly INIT_SCRIPT="/etc/init.d/xray-tproxy"
readonly HOTPLUG_HOOK="/etc/hotplug.d/iface/99-xray-tproxy"

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
# Validates existence of required system utilities and kernel modules.
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
      log error "Missing TPROXY kernel modules. Install them:"
      log error "apk add kmod-nft-tproxy kmod-nf-tproxy"
      return 1
    fi
  fi

  return 0
}

#######################################
# Writes the OpenWrt init script wrapper to disk.
# Globals:
#   INIT_SCRIPT
# Arguments:
#   None
# Outputs:
#   Creates the init script and makes it executable.
# Returns:
#   0 on success.
#######################################
generate_init_script() {
  local self_path
  self_path="$(readlink -f "$0")"

  log info "Generating init script at ${INIT_SCRIPT}..."
  cat <<EOF > "${INIT_SCRIPT}"
#!/bin/sh /etc/rc.common

START=99
STOP=10

EXTRA_COMMANDS="setup teardown status"

start() {
  ${self_path} _start_daemon
}

stop() {
  ${self_path} _stop_daemon
}

status() {
  ${self_path} status
}

setup() {
  ${self_path} setup
}

teardown() {
  ${self_path} teardown
}
EOF
  chmod +x "${INIT_SCRIPT}"
}

#######################################
# Writes the OpenWrt hotplug hook to disk.
# Globals:
#   HOTPLUG_HOOK
# Arguments:
#   None
# Outputs:
#   Creates the interface hotplug hook.
# Returns:
#   0 on success.
#######################################
generate_hotplug_hook() {
  local self_path
  self_path="$(readlink -f "$0")"

  log info "Generating hotplug hook at ${HOTPLUG_HOOK}..."
  mkdir -p /etc/hotplug.d/iface
  cat <<EOF > "${HOTPLUG_HOOK}"
#!/bin/sh
if [ "\$ACTION" = "ifup" ]; then
  (
    sleep 5
    ${self_path} _reload_rules
  ) &
fi
EOF
}

#######################################
# Writes the nftables TPROXY rule definitions to disk.
# Globals:
#   NFT_RULE_FILE
#   LAN_SUBNET
#   TPROXY_PORT
#   TPROXY_MARK
# Arguments:
#   None
# Outputs:
#   Creates the nftables rule file.
# Returns:
#   0 on success.
#######################################
generate_nft_rules() {
  log info "Generating nftables rules at ${NFT_RULE_FILE}..."
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
    meta l4proto { tcp, udp } tproxy to :${TPROXY_PORT} \\
      meta mark set ${TPROXY_MARK} accept
  }
}
EOF
}

#######################################
# Configures UCI settings for the xray daemon.
# Globals:
#   XRAY_CONF_FILE
# Arguments:
#   None
# Outputs:
#   Modifies and commits UCI configuration.
# Returns:
#   0 on success.
#######################################
configure_uci() {
  log info "Setting up UCI configuration for Xray..."
  uci -q delete xray.enabled || true
  uci -q delete xray.config || true
  uci set xray.enabled=enabled
  uci set xray.enabled.enabled='1'
  uci set xray.config=config
  uci set xray.config.format='json'
  uci set xray.config.conffiles="${XRAY_CONF_FILE}"
  uci commit xray
}

#######################################
# Prepares configuration, rules, init script, and hooks.
# Globals:
#   INIT_SCRIPT
# Arguments:
#   None
# Outputs:
#   Writes files and configures the system.
# Returns:
#   0 on success.
#######################################
cmd_setup() {
  if [ -x "${INIT_SCRIPT}" ]; then
    log info "Setup has already been run. Use 'teardown' to reset."
    return 0
  fi

  configure_uci
  generate_nft_rules
  generate_init_script
  generate_hotplug_hook

  log info "Enabling init service..."
  "${INIT_SCRIPT}" enable

  log success "Setup complete."
  log info "Run '$(colorize green "xray-tproxy.sh start")' to activate."
  return 0
}

#######################################
# Re-applies the nftables chain and routing rules if missing.
# Globals:
#   NFT_RULE_FILE
#   TPROXY_MARK
#   ROUTE_TABLE
# Arguments:
#   None
# Outputs:
#   Modifies fw4 nftables and routing rules in memory.
# Returns:
#   0 on success.
#######################################
cmd_reload_rules() {
  # If the base table doesn't exist, fw4 is not ready.
  if ! nft list table inet fw4 >/dev/null 2>&1; then
    return 0
  fi

  # Only reload if the service is intended to be enabled in UCI.
  if [ "$(uci -q get xray.enabled.enabled)" != "1" ]; then
    return 0
  fi

  # Restore policy routing if missing (flushed by network restart).
  if ! ip rule list | grep -q "lookup ${ROUTE_TABLE}"; then
    ip rule add fwmark "${TPROXY_MARK}" table "${ROUTE_TABLE}" \
      2>/dev/null || true
  fi

  if ! ip route list table "${ROUTE_TABLE}" 2>/dev/null | grep -q "default"; then
    ip route add local default dev lo table "${ROUTE_TABLE}" \
      2>/dev/null || true
  fi

  # Re-apply the base chain definitions safely. If the chain exists, flush it
  # first to prevent accumulating duplicate rules on successive reloads.
  if nft list chain inet fw4 xray_tproxy >/dev/null 2>&1; then
    nft flush chain inet fw4 xray_tproxy 2>/dev/null || true
  fi

  if [ -f "${NFT_RULE_FILE}" ]; then
    nft -f "${NFT_RULE_FILE}" 2>/dev/null || true
  fi

  # Ensure the jump rule is present in mangle_prerouting.
  # Use 'insert' instead of 'add' to place it at the TOP of the chain.
  # This prevents standard fw4 rules (like mwan3 or QoS) from accepting
  # or routing the packet before our transparent proxy logic catches it.
  if ! nft list chain inet fw4 mangle_prerouting 2>/dev/null | \
      grep -q 'jump xray_tproxy'; then
    nft insert rule inet fw4 mangle_prerouting jump xray_tproxy \
      2>/dev/null || true
  fi
  return 0
}

#######################################
# Activates routing and firewall rules.
# Called internally by the init script wrapper.
# Globals:
#   NFT_RULE_FILE
# Arguments:
#   None
# Outputs:
#   Applies rules to the system.
# Returns:
#   0 on success, 1 on error.
#######################################
cmd_start_daemon() {
  log info "Applying policy routing and nftables rules..."
  if [ ! -f "${NFT_RULE_FILE}" ]; then
    log error "Rule file ${NFT_RULE_FILE} not found. Run 'setup' first."
    return 1
  fi

  # cmd_reload_rules is fully idempotent and handles all state enforcement
  cmd_reload_rules

  log info "Starting native xray daemon..."
  /etc/init.d/xray start || true

  log success "TPROXY rules activated."
  return 0
}

#######################################
# Removes routing and firewall rules.
# Called internally by the init script wrapper.
# Globals:
#   TPROXY_MARK
#   ROUTE_TABLE
# Arguments:
#   None
# Outputs:
#   Removes rules from the system.
# Returns:
#   0 on success.
#######################################
cmd_stop_daemon() {
  log info "Stopping native xray daemon..."
  /etc/init.d/xray stop || true

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

  log success "TPROXY rules deactivated."
  return 0
}

#######################################
# Public wrapper to start the service.
# Globals:
#   INIT_SCRIPT
# Arguments:
#   None
# Outputs:
#   Invokes init script.
# Returns:
#   0 on success, 1 on error.
#######################################
cmd_start() {
  if [ ! -x "${INIT_SCRIPT}" ]; then
    log error "Init script not found. Run 'setup' first."
    return 1
  fi
  "${INIT_SCRIPT}" start
}

#######################################
# Public wrapper to stop the service.
# Globals:
#   INIT_SCRIPT
# Arguments:
#   None
# Outputs:
#   Invokes init script.
# Returns:
#   0 on success, 1 on error.
#######################################
cmd_stop() {
  if [ ! -x "${INIT_SCRIPT}" ]; then
    log error "Init script not found. Already stopped or missing."
    return 1
  fi
  "${INIT_SCRIPT}" stop
}

#######################################
# Disables service and removes all generated files and rules.
# Globals:
#   INIT_SCRIPT
#   HOTPLUG_HOOK
#   NFT_RULE_FILE
# Arguments:
#   None
# Outputs:
#   Removes files and rules.
# Returns:
#   0 on success.
#######################################
cmd_teardown() {
  log info "Stopping service and flushing rules..."
  if [ -x "${INIT_SCRIPT}" ]; then
    "${INIT_SCRIPT}" stop || true
    "${INIT_SCRIPT}" disable || true
  fi

  log info "Cleaning up generated files and UCI configuration..."
  uci -q delete xray.enabled || true
  uci commit xray

  rm -f "${NFT_RULE_FILE}"
  rm -f "${INIT_SCRIPT}"
  rm -f "${HOTPLUG_HOOK}"

  log success "Teardown complete. System restored."
  return 0
}

#######################################
# Checks and displays current daemon and routing status.
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

  if ip rule list | grep -q "lookup ${ROUTE_TABLE}"; then
    log success "TPROXY policy routing is active."
  else
    log warn "TPROXY policy routing is NOT active."
    all_ok=false
  fi

  if nft list chain inet fw4 mangle_prerouting 2>/dev/null | \
      grep -q 'jump xray_tproxy'; then
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

$(colorize blue "Lifecycle Commands:")
  $(colorize green "setup")     Prepare configs, init scripts, and hooks.
  $(colorize green "start")     Apply rules and start the proxy.
  $(colorize green "status")    Check if proxy and routing are active.
  $(colorize green "stop")      Stop the proxy and restore default routing.
  $(colorize green "teardown")  Completely remove all configs and hooks.

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
    _start_daemon)
      cmd_start_daemon || return 1
      ;;
    _stop_daemon)
      cmd_stop_daemon || return 1
      ;;
    _reload_rules)
      cmd_reload_rules || return 1
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
