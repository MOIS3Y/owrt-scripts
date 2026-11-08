#!/usr/bin/env ash
# shellcheck shell=dash
#
# Xray transparent proxy manager for OpenWrt (TPROXY method).
# The script owns only TPROXY routing/firewall state. The native Xray service
# and its configuration are shared with other ingress methods.

set -eu

readonly SCRIPT_VERSION="0.4.0"
readonly DEFAULT_SETTINGS_FILE="/etc/config/xray-tproxy"
readonly NFT_RULE_FILE="/etc/xray/xray-tproxy.nft"
readonly INIT_SCRIPT="/etc/init.d/xray-tproxy"
readonly HOTPLUG_HOOK="/etc/hotplug.d/iface/99-xray-tproxy"
readonly ACTIVE_FILE="/var/run/xray-tproxy.active"

SETTINGS_FILE="${DEFAULT_SETTINGS_FILE}"
SETTINGS_DIR=""
SETTINGS_PACKAGE=""

XRAY_CONFIG="/etc/xray/config.json"
INBOUND_TAG="transparent-tproxy"
TPROXY_PORT="10807"
TPROXY_MARK="1"
ROUTE_TABLE="100"
LAN_SUBNET="192.168.1.0/24"

#######################################
# Wrap text in an ANSI color sequence.
# Arguments:
#   $1: Color name.
#   $2: Text to format.
# Outputs:
#   Formatted text without a trailing newline.
#######################################
colorize() {
  local color="$1"
  local text="$2"
  local code

  case "${color}" in
    red) code='\033[0;31m' ;;
    green) code='\033[0;32m' ;;
    yellow) code='\033[0;33m' ;;
    blue) code='\033[0;34m' ;;
    *) code='\033[0m' ;;
  esac
  printf "%b%s\033[0m" "${code}" "${text}"
}

#######################################
# Write a consistently formatted log message.
# Arguments:
#   $1: Log level: info, success, warn, or error.
#   $2: Message text.
# Outputs:
#   Message to stdout, or stderr for errors.
#######################################
log() {
  local level="$1"
  local message="$2"

  case "${level}" in
    info) printf "%s %s\n" "$(colorize blue "INFO:")" "${message}" ;;
    success) printf "%s %s\n" "$(colorize green "SUCCESS:")" "${message}" ;;
    warn) printf "%s %s\n" "$(colorize yellow "WARN:")" "${message}" ;;
    error) printf "%s %s\n" "$(colorize red "ERROR:")" "${message}" >&2 ;;
    *) printf "%s\n" "${message}" ;;
  esac
}

#######################################
# Validate and split the selected UCI settings path.
# Globals:
#   SETTINGS_FILE SETTINGS_DIR SETTINGS_PACKAGE
# Returns:
#   0 for a safe absolute path, 1 otherwise.
#######################################
validate_settings_path() {
  case "${SETTINGS_FILE}" in
    /*) ;;
    *)
      log error "Settings path must be absolute: ${SETTINGS_FILE}"
      return 1
      ;;
  esac

  case "${SETTINGS_FILE}" in
    *[!A-Za-z0-9_./-]*)
      log error "Settings path contains unsupported characters: ${SETTINGS_FILE}"
      return 1
      ;;
  esac

  SETTINGS_DIR="${SETTINGS_FILE%/*}"
  SETTINGS_PACKAGE="${SETTINGS_FILE##*/}"
  [ -n "${SETTINGS_DIR}" ] || SETTINGS_DIR="/"
}

#######################################
# Read an option from the selected UCI main section.
# Arguments:
#   $1: UCI option name.
# Outputs:
#   Option value when it exists.
#######################################
uci_get() {
  uci -c "${SETTINGS_DIR}" -q get "${SETTINGS_PACKAGE}.main.$1" 2>/dev/null || true
}

#######################################
# Load runtime settings from UCI and environment overrides.
# Globals:
#   XRAY_CONFIG INBOUND_TAG TPROXY_PORT TPROXY_MARK ROUTE_TABLE LAN_SUBNET
# Returns:
#   0 when all loaded values are valid, 1 otherwise.
#######################################
load_settings() {
  local value

  validate_settings_path || return 1

  value="$(uci_get xray_config)"
  [ -z "${value}" ] || XRAY_CONFIG="${value}"
  value="$(uci_get inbound_tag)"
  [ -z "${value}" ] || INBOUND_TAG="${value}"
  value="$(uci_get port)"
  [ -z "${value}" ] || TPROXY_PORT="${value}"
  value="$(uci_get mark)"
  [ -z "${value}" ] || TPROXY_MARK="${value}"
  value="$(uci_get route_table)"
  [ -z "${value}" ] || ROUTE_TABLE="${value}"
  value="$(uci_get lan_subnet)"
  [ -z "${value}" ] || LAN_SUBNET="${value}"

  TPROXY_PORT="${XRAY_TPROXY_PORT:-${TPROXY_PORT}}"
  validate_settings
}

#######################################
# Validate an unsigned decimal setting.
# Arguments:
#   $1: Human-readable setting name.
#   $2: Value to validate.
#######################################
validate_number() {
  local name="$1"
  local value="$2"

  case "${value}" in
    '' | *[!0-9]*)
      log error "${name} must be numeric: ${value}"
      return 1
      ;;
  esac
}

#######################################
# Validate settings interpolated into routing and nftables commands.
# Returns:
#   0 when settings are safe and well-formed, 1 otherwise.
#######################################
validate_settings() {
  validate_number "port" "${TPROXY_PORT}" || return 1
  validate_number "mark" "${TPROXY_MARK}" || return 1
  validate_number "route_table" "${ROUTE_TABLE}" || return 1

  if [ "${TPROXY_PORT}" -lt 1 ] || [ "${TPROXY_PORT}" -gt 65535 ]; then
    log error "port must be between 1 and 65535"
    return 1
  fi

  case "${LAN_SUBNET}" in
    '' | *[!0-9./]*)
      log error "lan_subnet is not a safe IPv4 CIDR: ${LAN_SUBNET}"
      return 1
      ;;
  esac
}

#######################################
# Verify that required executables are available.
# Arguments:
#   $@: Command names.
# Returns:
#   0 when every command exists, 1 otherwise.
#######################################
check_commands() {
  local missing=""
  local command

  for command in "$@"; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      missing="${missing}${command} "
    fi
  done

  if [ -n "${missing}" ]; then
    log error "Missing dependencies: ${missing}"
    return 1
  fi
}

#######################################
# Ensure nftables TPROXY kernel support is loaded.
# Returns:
#   0 when available, 1 with installation guidance otherwise.
#######################################
check_tproxy_support() {
  if lsmod | grep -q 'tproxy'; then
    return 0
  fi

  if modprobe nft_tproxy 2>/dev/null; then
    return 0
  fi

  log error "Missing TPROXY kernel modules. Install them with:"
  log error "apk add kmod-nft-tproxy kmod-nf-tproxy"
  return 1
}

#######################################
# Create default UCI settings without overwriting user configuration.
# Globals:
#   SETTINGS_FILE SETTINGS_DIR SETTINGS_PACKAGE
#######################################
generate_default_settings() {
  validate_settings_path || return 1
  mkdir -p "${SETTINGS_DIR}"

  if [ -f "${SETTINGS_FILE}" ]; then
    log info "Keeping existing settings at ${SETTINGS_FILE}."
    return 0
  fi

  log info "Creating default settings at ${SETTINGS_FILE}..."
  cat <<'EOF' >"${SETTINGS_FILE}"
config main 'main'
	option xray_config '/etc/xray/config.json'
	option inbound_tag 'transparent-tproxy'
	option port '10807'
	option mark '1'
	option route_table '100'
	option lan_subnet '192.168.1.0/24'
EOF
}

#######################################
# Validate the shared Xray JSON configuration with the Xray binary.
# Globals:
#   XRAY_CONFIG
# Returns:
#   0 for a readable valid configuration, 1 otherwise.
#######################################
validate_xray_config() {
  if [ ! -r "${XRAY_CONFIG}" ]; then
    log error "Xray configuration is not readable: ${XRAY_CONFIG}"
    return 1
  fi

  if ! xray run -test -format json -config "${XRAY_CONFIG}" >/dev/null 2>&1; then
    log error "Xray configuration validation failed: ${XRAY_CONFIG}"
    return 1
  fi
}

#######################################
# Confirm that the native OpenWrt Xray service is enabled.
# Returns:
#   0 when enabled in /etc/config/xray, 1 otherwise.
#######################################
check_xray_service_enabled() {
  if [ "$(uci -q get xray.enabled.enabled 2>/dev/null || true)" = 1 ]; then
    return 0
  fi

  log error "The native Xray service is disabled in /etc/config/xray."
  log error "Enable and configure that shared service before using TPROXY."
  return 1
}

#######################################
# Enable the shared native Xray instance without changing its config source.
# Side Effects:
#   Adds or updates only xray.enabled.enabled in /etc/config/xray.
# Returns:
#   0 on success, 1 if the native Xray config section is unavailable.
#######################################
configure_xray_service_enabled() {
  if ! uci -q get xray.config >/dev/null 2>&1; then
    log error "The native Xray config section is missing from /etc/config/xray."
    return 1
  fi

  if [ "$(uci -q get xray.enabled.enabled 2>/dev/null || true)" = 1 ]; then
    return 0
  fi

  log info "Enabling the shared Xray instance in /etc/config/xray..."
  uci set xray.enabled=enabled
  uci set xray.enabled.enabled='1'
  uci commit xray
}

#######################################
# Start the shared Xray service when it is not already running.
# Returns:
#   0 when Xray is ready, 1 on timeout or service failure.
#######################################
ensure_xray_running() {
  local attempts=0

  if /etc/init.d/xray status >/dev/null 2>&1; then
    return 0
  fi

  log info "Starting the shared Xray service..."
  /etc/init.d/xray start || return 1

  while ! /etc/init.d/xray status >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 10 ]; then
      log error "Xray did not become ready."
      return 1
    fi
    sleep 1
  done
}

#######################################
# Generate the rc.common wrapper used at boot and shutdown.
# Globals:
#   INIT_SCRIPT SETTINGS_FILE
#######################################
generate_init_script() {
  local self_path
  self_path="$(readlink -f "$0")"

  log info "Generating init script at ${INIT_SCRIPT}..."
  cat <<EOF >"${INIT_SCRIPT}"
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
  ${self_path} -c ${SETTINGS_FILE} _start_daemon
}

stop() {
  ${self_path} -c ${SETTINGS_FILE} _stop_daemon
}
EOF
  chmod +x "${INIT_SCRIPT}"
}

#######################################
# Generate the iface hook that restores rules after network events.
# Globals:
#   HOTPLUG_HOOK ACTIVE_FILE SETTINGS_FILE
#######################################
generate_hotplug_hook() {
  local self_path
  self_path="$(readlink -f "$0")"

  log info "Generating hotplug hook at ${HOTPLUG_HOOK}..."
  mkdir -p /etc/hotplug.d/iface
  cat <<EOF >"${HOTPLUG_HOOK}"
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
[ -e "${ACTIVE_FILE}" ] || exit 0
(
  sleep 5
  ${self_path} -c ${SETTINGS_FILE} _reload_rules
) &
EOF
  chmod +x "${HOTPLUG_HOOK}"
}

#######################################
# Render the nftables TPROXY chain from validated settings.
# Globals:
#   NFT_RULE_FILE LAN_SUBNET TPROXY_PORT TPROXY_MARK
#######################################
generate_nft_rules() {
  local local_networks="127.0.0.0/8, 192.168.0.0/16, 10.0.0.0/8"
  local other_networks="172.16.0.0/12, 224.0.0.0/4, 255.255.255.255/32"

  log info "Generating nftables rules at ${NFT_RULE_FILE}..."
  mkdir -p /etc/xray
  cat <<EOF >"${NFT_RULE_FILE}"
table inet fw4 {
  chain xray_tproxy {
    ct direction reply return
    fib daddr type local return
    ip saddr != ${LAN_SUBNET} return
    ip daddr { ${local_networks}, ${other_networks} } return
    meta l4proto { tcp, udp } th dport { 53, 853 } return
    meta l4proto { tcp, udp } counter tproxy to :${TPROXY_PORT} \\
      meta mark set ${TPROXY_MARK} accept
  }
}
EOF
}

#######################################
# Install settings, rules, lifecycle integration, and autostart.
# Returns:
#   0 on success, 1 when a prerequisite or validation fails.
#######################################
cmd_setup() {
  generate_default_settings || return 1
  load_settings || return 1
  check_commands uci nft xray ip modprobe || return 1
  check_tproxy_support || return 1
  validate_xray_config || return 1
  configure_xray_service_enabled || return 1
  check_xray_service_enabled || return 1

  generate_nft_rules
  generate_init_script
  generate_hotplug_hook

  log info "Enabling TPROXY autostart..."
  "${INIT_SCRIPT}" enable
  log success "Setup complete. Settings: ${SETTINGS_FILE}"
  log info "Run 'xray-tproxy start' to activate TPROXY now."
}

#######################################
# Idempotently restore TPROXY policy routing and nftables interception.
# Globals:
#   ACTIVE_FILE NFT_RULE_FILE TPROXY_MARK ROUTE_TABLE
# Returns:
#   0 when inactive or successfully applied, 1 on rule failure.
#######################################
cmd_reload_rules() {
  [ -e "${ACTIVE_FILE}" ] || return 0
  [ -f "${NFT_RULE_FILE}" ] || {
    log error "Rule file is missing: ${NFT_RULE_FILE}"
    return 1
  }

  nft list table inet fw4 >/dev/null 2>&1 || return 0

  if ! ip -4 rule list | grep -q "fwmark 0x$(printf '%x' "${TPROXY_MARK}").*lookup ${ROUTE_TABLE}"; then
    ip -4 rule add fwmark "${TPROXY_MARK}" table "${ROUTE_TABLE}"
  fi

  if ! ip -4 route list table "${ROUTE_TABLE}" | grep -q '^local default dev lo'; then
    ip -4 route replace local default dev lo table "${ROUTE_TABLE}"
  fi

  if nft list chain inet fw4 xray_tproxy >/dev/null 2>&1; then
    nft flush chain inet fw4 xray_tproxy
  fi
  nft -f "${NFT_RULE_FILE}"

  if ! nft list chain inet fw4 mangle_prerouting 2>/dev/null |
    grep -q 'jump xray_tproxy'; then
    nft insert rule inet fw4 mangle_prerouting jump xray_tproxy
  fi
}

#######################################
# Remove all TPROXY runtime state owned by this script.
# Globals:
#   TPROXY_MARK ROUTE_TABLE
#######################################
remove_tproxy_rules() {
  local handle

  while :; do
    handle="$(nft -a list chain inet fw4 mangle_prerouting 2>/dev/null |
      awk '/jump xray_tproxy/ { print $NF; exit }')"
    [ -n "${handle}" ] || break
    nft delete rule inet fw4 mangle_prerouting handle "${handle}" 2>/dev/null || break
  done

  nft flush chain inet fw4 xray_tproxy 2>/dev/null || true
  nft delete chain inet fw4 xray_tproxy 2>/dev/null || true

  while ip -4 rule del fwmark "${TPROXY_MARK}" table "${ROUTE_TABLE}" 2>/dev/null; do
    :
  done
  ip -4 route flush table "${ROUTE_TABLE}" 2>/dev/null || true
}

#######################################
# Activate interception after the shared Xray service is ready.
# Side Effects:
#   Creates ACTIVE_FILE and installs routing/firewall state.
#######################################
cmd_start_daemon() {
  check_xray_service_enabled || return 1
  validate_xray_config || return 1
  ensure_xray_running || return 1

  mkdir -p "${ACTIVE_FILE%/*}"
  touch "${ACTIVE_FILE}"

  if ! cmd_reload_rules; then
    rm -f "${ACTIVE_FILE}"
    remove_tproxy_rules
    return 1
  fi

  log success "TPROXY routing is active."
}

#######################################
# Deactivate interception while leaving the shared Xray service running.
#######################################
cmd_stop_daemon() {
  rm -f "${ACTIVE_FILE}"
  log info "Removing TPROXY routing and nftables rules..."
  remove_tproxy_rules
  log success "TPROXY routing is inactive. The shared Xray service was left running."
}

#######################################
# Invoke the installed init wrapper to activate TPROXY.
#######################################
cmd_start() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" start
}

#######################################
# Invoke the installed init wrapper to deactivate TPROXY.
#######################################
cmd_stop() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" stop
}

#######################################
# Recreate TPROXY runtime routing through public lifecycle commands.
#######################################
cmd_restart() {
  cmd_stop
  cmd_start
}

#######################################
# Enable TPROXY reconstruction during boot.
#######################################
cmd_enable() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" enable
  log success "TPROXY autostart enabled."
}

#######################################
# Disable boot activation without changing current runtime state.
#######################################
cmd_disable() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" disable
  log success "TPROXY autostart disabled. Current runtime state was not changed."
}

#######################################
# Remove owned runtime, init, hotplug, and nftables integration.
# Notes:
#   Preserves the shared Xray service and script settings file.
#######################################
cmd_teardown() {
  log info "Removing TPROXY integration..."
  if [ -x "${INIT_SCRIPT}" ]; then
    "${INIT_SCRIPT}" stop || true
    "${INIT_SCRIPT}" disable || true
  else
    rm -f "${ACTIVE_FILE}"
    remove_tproxy_rules
  fi

  rm -f "${NFT_RULE_FILE}" "${INIT_SCRIPT}" "${HOTPLUG_HOOK}"
  log success "TPROXY integration removed."
  log info "The shared Xray service and ${SETTINGS_FILE} were preserved."
}

#######################################
# Report shared Xray, policy-routing, and nftables state.
# Returns:
#   0 only when every required component is active, 1 otherwise.
#######################################
cmd_status() {
  local all_ok=true

  log info "Settings: ${SETTINGS_FILE}"
  log info "Xray config: ${XRAY_CONFIG}"
  log info "Expected inbound: ${INBOUND_TAG}"

  if /etc/init.d/xray status >/dev/null 2>&1; then
    log success "Xray service is running."
  else
    log warn "Xray service is not running."
    all_ok=false
  fi

  if [ -e "${ACTIVE_FILE}" ]; then
    log success "TPROXY runtime mode is active."
  else
    log warn "TPROXY runtime mode is inactive."
    all_ok=false
  fi

  if ip -4 rule list | grep -q "lookup ${ROUTE_TABLE}"; then
    log success "Policy rule points marked traffic to table ${ROUTE_TABLE}."
  else
    log warn "Policy rule for table ${ROUTE_TABLE} is missing."
    all_ok=false
  fi

  if ip -4 route list table "${ROUTE_TABLE}" 2>/dev/null |
    grep -q '^local default dev lo'; then
    log success "Table ${ROUTE_TABLE} has the local default route."
  else
    log warn "Table ${ROUTE_TABLE} has no local default route."
    all_ok=false
  fi

  if nft list chain inet fw4 mangle_prerouting 2>/dev/null |
    grep -q 'jump xray_tproxy'; then
    log success "nftables TPROXY interception is installed."
  else
    log warn "nftables TPROXY interception is missing."
    all_ok=false
  fi

  if [ "${all_ok}" = true ]; then
    log success "TPROXY is fully active."
    return 0
  fi

  log error "TPROXY is inactive or partially configured."
  return 1
}

#######################################
# Print the script version.
#######################################
show_version() {
  printf "xray-tproxy version %s\n" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Print command and option documentation.
#######################################
usage() {
  cat <<EOF
Usage: $(colorize yellow "xray-tproxy") [OPTIONS] $(colorize green "COMMAND")

Manage OpenWrt policy routing and nftables interception for an Xray TPROXY
inbound. The shared Xray service is never stopped or removed.

Commands:
  setup       Create settings, init integration, rules, and enable autostart.
  start       Start Xray if needed and activate TPROXY routing.
  stop        Remove TPROXY routing without stopping Xray.
  restart     Reapply TPROXY routing.
  status      Show Xray, policy-routing, and nftables status.
  enable      Enable TPROXY at boot.
  disable     Disable TPROXY at boot without changing the current state.
  teardown    Remove TPROXY integration while preserving Xray and settings.

Options:
  -c, --config FILE  Script settings file (default: ${DEFAULT_SETTINGS_FILE}).
  -h, --help         Show this help message.
  -v, --version      Show the script version.

Environment:
  XRAY_TPROXY_PORT   Override the configured TPROXY port for this invocation.
EOF
}

#######################################
# Parse global options and dispatch one lifecycle command.
# Arguments:
#   $@: Command-line arguments.
# Returns:
#   The selected command status.
#######################################
main() {
  local command=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -c | --config)
        [ $# -ge 2 ] || {
          log error "$1 requires a file path."
          return 1
        }
        SETTINGS_FILE="$2"
        shift 2
        ;;
      -h | --help | help)
        usage
        return 0
        ;;
      -v | --version | version)
        show_version
        return 0
        ;;
      -*)
        log error "Unknown option: $1"
        return 1
        ;;
      *)
        command="$1"
        shift
        break
        ;;
    esac
  done

  [ -n "${command}" ] || {
    usage
    return 1
  }
  [ $# -eq 0 ] || {
    log error "Unexpected argument: $1"
    return 1
  }

  check_commands uci || return 1
  if [ "${command}" != setup ]; then
    load_settings || return 1
  fi

  case "${command}" in
    setup) cmd_setup ;;
    start) check_commands nft xray ip && cmd_start ;;
    stop) check_commands nft ip && cmd_stop ;;
    restart) check_commands nft xray ip && cmd_restart ;;
    status) check_commands nft ip && cmd_status ;;
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    teardown) check_commands nft ip && cmd_teardown ;;
    _start_daemon) check_commands nft xray ip && cmd_start_daemon ;;
    _stop_daemon) check_commands nft ip && cmd_stop_daemon ;;
    _reload_rules) check_commands nft ip && cmd_reload_rules ;;
    *)
      log error "Unknown command: ${command}"
      usage
      return 1
      ;;
  esac
}

main "$@"
