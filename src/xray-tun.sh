#!/usr/bin/env ash
# shellcheck shell=dash
#
# Xray transparent proxy manager for OpenWrt (TUN method).
# The script owns only TUN policy routing and firewall integration. Xray owns
# the TUN device, its configuration, and all proxy outbounds.

set -eu

readonly SCRIPT_VERSION="0.2.0"
readonly DEFAULT_SETTINGS_FILE="/etc/config/xray-tun"
readonly INIT_SCRIPT="/etc/init.d/xray-tun"
readonly IFACE_HOTPLUG_HOOK="/etc/hotplug.d/iface/99-xray-tun"
readonly NET_HOTPLUG_HOOK="/etc/hotplug.d/net/99-xray-tun"
readonly ACTIVE_FILE="/var/run/xray-tun.active"
readonly NFT_TABLE="xray_tun"
readonly NFT_CHAIN="reply_bypass"
readonly FIREWALL_ZONE_SECTION="xray_tun"
readonly FIREWALL_FORWARDING_SECTION="lan_to_xray_tun"

SETTINGS_FILE="${DEFAULT_SETTINGS_FILE}"
SETTINGS_DIR=""
SETTINGS_PACKAGE=""

XRAY_CONFIG="/etc/xray/config.json"
INBOUND_TAG="transparent-tun"
TUN_DEVICE="xray0"
LAN_DEVICE="br-lan"
LAN_SUBNET="192.168.1.0/24"
ROUTE_TABLE="101"
RULE_PRIORITY="11000"
REPLY_RULE_PRIORITY="10900"
REPLY_MARK="2"
REPLY_MARK_HEX="0x2"
WAIT_SECONDS="20"
BYPASS_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4"

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
#   SETTINGS_FILE
#   SETTINGS_DIR
#   SETTINGS_PACKAGE
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
# Globals:
#   SETTINGS_DIR
#   SETTINGS_PACKAGE
# Arguments:
#   $1: UCI option name.
# Outputs:
#   Option value when it exists.
#######################################
uci_get() {
  uci -c "${SETTINGS_DIR}" -q get "${SETTINGS_PACKAGE}.main.$1" 2>/dev/null || true
}

#######################################
# Load runtime settings from UCI over built-in defaults.
# Globals:
#   XRAY_CONFIG INBOUND_TAG TUN_DEVICE LAN_DEVICE LAN_SUBNET
#   ROUTE_TABLE RULE_PRIORITY REPLY_RULE_PRIORITY REPLY_MARK REPLY_MARK_HEX
#   WAIT_SECONDS BYPASS_CIDRS
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
  value="$(uci_get device)"
  [ -z "${value}" ] || TUN_DEVICE="${value}"
  value="$(uci_get lan_device)"
  [ -z "${value}" ] || LAN_DEVICE="${value}"
  value="$(uci_get lan_subnet)"
  [ -z "${value}" ] || LAN_SUBNET="${value}"
  value="$(uci_get route_table)"
  [ -z "${value}" ] || ROUTE_TABLE="${value}"
  value="$(uci_get rule_priority)"
  [ -z "${value}" ] || RULE_PRIORITY="${value}"
  value="$(uci_get reply_rule_priority)"
  [ -z "${value}" ] || REPLY_RULE_PRIORITY="${value}"
  value="$(uci_get reply_mark)"
  [ -z "${value}" ] || REPLY_MARK="${value}"
  value="$(uci_get wait_seconds)"
  [ -z "${value}" ] || WAIT_SECONDS="${value}"
  value="$(uci_get bypass_cidr)"
  [ -z "${value}" ] || BYPASS_CIDRS="${value}"

  validate_settings
}

#######################################
# Validate an unsigned decimal setting.
# Arguments:
#   $1: Human-readable setting name.
#   $2: Value to validate.
# Returns:
#   0 for digits only, 1 otherwise.
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
# Validate a Linux network-device name used in shell commands.
# Arguments:
#   $1: Human-readable setting name.
#   $2: Device name to validate.
# Returns:
#   0 for the accepted character set, 1 otherwise.
#######################################
validate_device_name() {
  local name="$1"
  local value="$2"

  case "${value}" in
    '' | *[!A-Za-z0-9_.:@+-]*)
      log error "${name} contains unsupported characters: ${value}"
      return 1
      ;;
  esac
}

#######################################
# Validate every loaded routing setting before use as root.
# Globals:
#   TUN_DEVICE LAN_DEVICE LAN_SUBNET ROUTE_TABLE RULE_PRIORITY
#   REPLY_RULE_PRIORITY REPLY_MARK REPLY_MARK_HEX WAIT_SECONDS BYPASS_CIDRS
# Returns:
#   0 when all settings are safe and well-formed, 1 otherwise.
#######################################
validate_settings() {
  local cidr

  validate_number "route_table" "${ROUTE_TABLE}" || return 1
  validate_number "rule_priority" "${RULE_PRIORITY}" || return 1
  validate_number "reply_rule_priority" "${REPLY_RULE_PRIORITY}" || return 1
  validate_number "reply_mark" "${REPLY_MARK}" || return 1
  validate_number "wait_seconds" "${WAIT_SECONDS}" || return 1
  validate_device_name "device" "${TUN_DEVICE}" || return 1
  validate_device_name "lan_device" "${LAN_DEVICE}" || return 1

  if [ "${REPLY_RULE_PRIORITY}" -ge "${RULE_PRIORITY}" ]; then
    log error "reply_rule_priority must be lower than rule_priority"
    return 1
  fi

  if [ "${REPLY_MARK}" -le 0 ] ||
    [ $((REPLY_MARK & (REPLY_MARK - 1))) -ne 0 ]; then
    log error "reply_mark must be a non-zero power of two: ${REPLY_MARK}"
    return 1
  fi
  REPLY_MARK_HEX="$(printf '0x%x' "${REPLY_MARK}")"

  case "${LAN_SUBNET}" in
    '' | *[!0-9./]*)
      log error "lan_subnet is not a safe IPv4 CIDR: ${LAN_SUBNET}"
      return 1
      ;;
  esac

  for cidr in ${BYPASS_CIDRS}; do
    case "${cidr}" in
      *[!0-9./]*)
        log error "bypass_cidr is not a safe IPv4 CIDR: ${cidr}"
        return 1
        ;;
    esac
  done
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
# Ensure the kernel TUN device is available.
# Outputs:
#   Installation guidance when kmod-tun is missing.
# Returns:
#   0 when /dev/net/tun exists, 1 otherwise.
#######################################
check_tun_support() {
  if [ -c /dev/net/tun ]; then
    return 0
  fi

  modprobe tun 2>/dev/null || true
  if [ -c /dev/net/tun ]; then
    return 0
  fi

  log error "TUN kernel support is unavailable. Install it with:"
  log error "apk add kmod-tun"
  return 1
}

#######################################
# Create the initial UCI settings without overwriting user configuration.
# Globals:
#   SETTINGS_FILE SETTINGS_DIR SETTINGS_PACKAGE
# Outputs:
#   Progress information.
# Returns:
#   0 on success, 1 on path or UCI failure.
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
	option inbound_tag 'transparent-tun'
	option device 'xray0'
	option lan_device 'br-lan'
	option lan_subnet '192.168.1.0/24'
	option route_table '101'
	option rule_priority '11000'
	option reply_rule_priority '10900'
	option reply_mark '2'
	option wait_seconds '20'

	list bypass_cidr '10.0.0.0/8'
	list bypass_cidr '172.16.0.0/12'
	list bypass_cidr '192.168.0.0/16'
	list bypass_cidr '169.254.0.0/16'
	list bypass_cidr '224.0.0.0/4'
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
  log error "Enable and configure that shared service before using TUN."
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
# Outputs:
#   Startup progress and readiness errors.
# Returns:
#   0 when Xray is running, 1 on timeout or service failure.
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
# Wait until the configured TUN inbound creates its network device.
# Globals:
#   TUN_DEVICE WAIT_SECONDS INBOUND_TAG XRAY_CONFIG
# Returns:
#   0 when the device appears, 1 after the configured timeout.
#######################################
wait_for_tun_device() {
  local elapsed=0

  while ! ip link show dev "${TUN_DEVICE}" >/dev/null 2>&1; do
    if [ "${elapsed}" -ge "${WAIT_SECONDS}" ]; then
      log error "${TUN_DEVICE} was not created within ${WAIT_SECONDS} seconds."
      log error "Check that the ${INBOUND_TAG} TUN inbound is present in ${XRAY_CONFIG}."
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

#######################################
# Generate the rc.common wrapper used for boot and shutdown ordering.
# Globals:
#   INIT_SCRIPT SETTINGS_FILE
# Outputs:
#   Progress information.
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
# Generate hooks that restore routes after network or TUN-device events.
# Globals:
#   IFACE_HOTPLUG_HOOK NET_HOTPLUG_HOOK ACTIVE_FILE TUN_DEVICE
#   SETTINGS_FILE
# Outputs:
#   Progress information.
#######################################
generate_hotplug_hooks() {
  local self_path
  self_path="$(readlink -f "$0")"

  log info "Generating network hotplug hooks..."
  mkdir -p /etc/hotplug.d/iface /etc/hotplug.d/net

  cat <<EOF >"${IFACE_HOTPLUG_HOOK}"
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
[ -e "${ACTIVE_FILE}" ] || exit 0
(
  sleep 2
  ${self_path} -c ${SETTINGS_FILE} _reload_routes
) &
EOF

  cat <<EOF >"${NET_HOTPLUG_HOOK}"
#!/bin/sh
[ "\$ACTION" = "add" ] || exit 0
[ "\$DEVICENAME" = "${TUN_DEVICE}" ] || exit 0
[ -e "${ACTIVE_FILE}" ] || exit 0
(
  sleep 1
  ${self_path} -c ${SETTINGS_FILE} _reload_routes
) &
EOF

  chmod +x "${IFACE_HOTPLUG_HOOK}" "${NET_HOTPLUG_HOOK}"
}

#######################################
# Create the persistent fw4 zone and LAN-to-TUN forwarding.
# Globals:
#   TUN_DEVICE FIREWALL_ZONE_SECTION FIREWALL_FORWARDING_SECTION
# Side Effects:
#   Commits /etc/config/firewall and reloads fw4.
#######################################
configure_firewall() {
  log info "Configuring firewall zone for ${TUN_DEVICE}..."

  uci -q delete "firewall.${FIREWALL_ZONE_SECTION}" || true
  uci set "firewall.${FIREWALL_ZONE_SECTION}=zone"
  uci set "firewall.${FIREWALL_ZONE_SECTION}.name=xray_tun"
  uci add_list "firewall.${FIREWALL_ZONE_SECTION}.device=${TUN_DEVICE}"
  uci set "firewall.${FIREWALL_ZONE_SECTION}.input=REJECT"
  uci set "firewall.${FIREWALL_ZONE_SECTION}.output=ACCEPT"
  uci set "firewall.${FIREWALL_ZONE_SECTION}.forward=REJECT"
  uci set "firewall.${FIREWALL_ZONE_SECTION}.masq=0"

  uci -q delete "firewall.${FIREWALL_FORWARDING_SECTION}" || true
  uci set "firewall.${FIREWALL_FORWARDING_SECTION}=forwarding"
  uci set "firewall.${FIREWALL_FORWARDING_SECTION}.src=lan"
  uci set "firewall.${FIREWALL_FORWARDING_SECTION}.dest=xray_tun"
  uci commit firewall
  /etc/init.d/firewall reload
}

#######################################
# Remove only firewall sections owned by this script.
# Globals:
#   FIREWALL_ZONE_SECTION FIREWALL_FORWARDING_SECTION
# Side Effects:
#   Commits /etc/config/firewall and reloads fw4.
#######################################
remove_firewall() {
  uci -q delete "firewall.${FIREWALL_FORWARDING_SECTION}" || true
  uci -q delete "firewall.${FIREWALL_ZONE_SECTION}" || true
  uci commit firewall
  /etc/init.d/firewall reload
}

#######################################
# Install settings, lifecycle integration, firewall state, and autostart.
# Returns:
#   0 on success, 1 when a prerequisite or validation fails.
#######################################
cmd_setup() {
  generate_default_settings || return 1
  load_settings || return 1
  check_commands uci xray ip nft modprobe || return 1
  check_tun_support || return 1
  validate_xray_config || return 1
  configure_xray_service_enabled || return 1
  check_xray_service_enabled || return 1

  generate_init_script
  generate_hotplug_hooks
  configure_firewall

  log info "Enabling TUN autostart..."
  "${INIT_SCRIPT}" enable
  log success "Setup complete. Settings: ${SETTINGS_FILE}"
  log info "Run 'xray-tun start' to activate TUN routing now."
}

#######################################
# Install the prerouting rule that marks reply-direction LAN packets.
# Globals:
#   NFT_TABLE NFT_CHAIN LAN_DEVICE LAN_SUBNET REPLY_MARK_HEX
# Notes:
#   Bitwise OR preserves packet-mark bits owned by other applications.
#######################################
install_reply_bypass_nft() {
  nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
  nft -f - <<EOF
table inet ${NFT_TABLE} {
  chain ${NFT_CHAIN} {
    type filter hook prerouting priority mangle; policy accept;
    iifname "${LAN_DEVICE}" ip saddr ${LAN_SUBNET} ct direction reply \
      meta mark set meta mark | ${REPLY_MARK_HEX}
  }
}
EOF
}

#######################################
# Remove the reply-direction packet-marking table owned by this script.
# Globals:
#   NFT_TABLE
#######################################
remove_reply_bypass_nft() {
  nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
}

#######################################
# Delete this script's exact reply-bypass policy rule, including duplicates.
# Globals:
#   REPLY_RULE_PRIORITY REPLY_MARK_HEX
#######################################
remove_reply_policy_rule() {
  while ip -4 rule del priority "${REPLY_RULE_PRIORITY}" \
    fwmark "${REPLY_MARK_HEX}/${REPLY_MARK_HEX}" table main 2>/dev/null; do
    :
  done
}

#######################################
# Delete this script's exact LAN policy rule, including duplicates.
# Globals:
#   RULE_PRIORITY LAN_DEVICE LAN_SUBNET ROUTE_TABLE
#######################################
remove_policy_rule() {
  while ip -4 rule del priority "${RULE_PRIORITY}" iif "${LAN_DEVICE}" \
    from "${LAN_SUBNET}" table "${ROUTE_TABLE}" 2>/dev/null; do
    :
  done
}

#######################################
# Rebuild reply bypass, table 101-style routes, and LAN policy rules.
# Globals:
#   ACTIVE_FILE TUN_DEVICE BYPASS_CIDRS ROUTE_TABLE RULE_PRIORITY
#   REPLY_RULE_PRIORITY REPLY_MARK_HEX LAN_DEVICE LAN_SUBNET
# Returns:
#   0 when inactive or successfully applied, 1 when the TUN device is absent.
#######################################
cmd_reload_routes() {
  local cidr

  [ -e "${ACTIVE_FILE}" ] || return 0
  ip link show dev "${TUN_DEVICE}" >/dev/null 2>&1 || return 1

  remove_reply_policy_rule
  remove_policy_rule
  ip -4 route flush table "${ROUTE_TABLE}" 2>/dev/null || true
  install_reply_bypass_nft

  for cidr in ${BYPASS_CIDRS}; do
    ip -4 route add throw "${cidr}" table "${ROUTE_TABLE}"
  done
  ip -4 route add default dev "${TUN_DEVICE}" table "${ROUTE_TABLE}"
  ip -4 rule add priority "${REPLY_RULE_PRIORITY}" \
    fwmark "${REPLY_MARK_HEX}/${REPLY_MARK_HEX}" lookup main
  ip -4 rule add priority "${RULE_PRIORITY}" iif "${LAN_DEVICE}" \
    from "${LAN_SUBNET}" lookup "${ROUTE_TABLE}"
}

#######################################
# Remove all runtime policy-routing state owned by this script.
# Globals:
#   ROUTE_TABLE
#######################################
remove_tun_routes() {
  remove_reply_policy_rule
  remove_policy_rule
  ip -4 route flush table "${ROUTE_TABLE}" 2>/dev/null || true
  remove_reply_bypass_nft
}

#######################################
# Activate TUN delivery after Xray and its device are ready.
# Side Effects:
#   Creates ACTIVE_FILE and installs runtime routes.
# Returns:
#   0 on success, 1 without leaving the mode marked active.
#######################################
cmd_start_daemon() {
  check_tun_support || return 1
  check_xray_service_enabled || return 1
  validate_xray_config || return 1
  ensure_xray_running || return 1
  wait_for_tun_device || return 1

  mkdir -p "${ACTIVE_FILE%/*}"
  touch "${ACTIVE_FILE}"

  if ! cmd_reload_routes; then
    rm -f "${ACTIVE_FILE}"
    remove_tun_routes
    return 1
  fi

  log success "TUN routing is active through ${TUN_DEVICE}."
}

#######################################
# Deactivate TUN delivery while leaving the shared Xray daemon running.
# Side Effects:
#   Removes ACTIVE_FILE, the policy rule, and the custom route table.
#######################################
cmd_stop_daemon() {
  rm -f "${ACTIVE_FILE}"
  log info "Removing TUN policy routing..."
  remove_tun_routes
  log success "TUN routing is inactive. The shared Xray service was left running."
}

#######################################
# Invoke the installed init wrapper to activate TUN routing.
# Returns:
#   The init action status.
#######################################
cmd_start() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" start
}

#######################################
# Invoke the installed init wrapper to deactivate TUN routing.
# Returns:
#   The init action status.
#######################################
cmd_stop() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" stop
}

#######################################
# Recreate TUN runtime routing through the public lifecycle commands.
#######################################
cmd_restart() {
  cmd_stop
  cmd_start
}

#######################################
# Enable reconstruction of TUN routing during boot.
#######################################
cmd_enable() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" enable
  log success "TUN autostart enabled."
}

#######################################
# Disable boot-time activation without changing current runtime state.
#######################################
cmd_disable() {
  [ -x "${INIT_SCRIPT}" ] || {
    log error "Init script not found. Run 'setup' first."
    return 1
  }
  "${INIT_SCRIPT}" disable
  log success "TUN autostart disabled. Current runtime state was not changed."
}

#######################################
# Remove owned runtime, init, hotplug, and firewall integration.
# Notes:
#   Preserves the shared Xray service and script settings file.
#######################################
cmd_teardown() {
  log info "Removing TUN integration..."
  if [ -x "${INIT_SCRIPT}" ]; then
    "${INIT_SCRIPT}" stop || true
    "${INIT_SCRIPT}" disable || true
  else
    rm -f "${ACTIVE_FILE}"
    remove_tun_routes
  fi

  remove_firewall
  rm -f "${INIT_SCRIPT}" "${IFACE_HOTPLUG_HOOK}" "${NET_HOTPLUG_HOOK}"
  log success "TUN integration removed."
  log info "The shared Xray service and ${SETTINGS_FILE} were preserved."
}

#######################################
# Report shared Xray, TUN device, routing, and firewall state.
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

  if ip link show dev "${TUN_DEVICE}" >/dev/null 2>&1; then
    log success "TUN device ${TUN_DEVICE} exists."
  else
    log warn "TUN device ${TUN_DEVICE} is missing."
    all_ok=false
  fi

  if [ -e "${ACTIVE_FILE}" ]; then
    log success "TUN runtime mode is active."
  else
    log warn "TUN runtime mode is inactive."
    all_ok=false
  fi

  if ip -4 rule list | grep -q "${RULE_PRIORITY}:.*iif ${LAN_DEVICE}.*lookup ${ROUTE_TABLE}"; then
    log success "LAN policy rule uses table ${ROUTE_TABLE}."
  else
    log warn "LAN policy rule for table ${ROUTE_TABLE} is missing."
    all_ok=false
  fi

  if ip -4 rule list |
    grep -q "${REPLY_RULE_PRIORITY}:.*fwmark ${REPLY_MARK_HEX}/${REPLY_MARK_HEX}.*lookup main"; then
    log success "Reply-direction packets bypass TUN through the main table."
  else
    log warn "Reply-bypass policy rule is missing."
    all_ok=false
  fi

  if nft list chain inet "${NFT_TABLE}" "${NFT_CHAIN}" 2>/dev/null |
    grep -q 'ct direction reply'; then
    log success "Conntrack reply marking is active."
  else
    log warn "Conntrack reply marking is missing."
    all_ok=false
  fi

  if ip -4 route list table "${ROUTE_TABLE}" 2>/dev/null |
    grep -q "^default dev ${TUN_DEVICE}"; then
    log success "Table ${ROUTE_TABLE} routes Internet traffic to ${TUN_DEVICE}."
  else
    log warn "Default route through ${TUN_DEVICE} is missing from table ${ROUTE_TABLE}."
    all_ok=false
  fi

  if [ "$(uci -q get firewall.${FIREWALL_ZONE_SECTION}.name 2>/dev/null || true)" = xray_tun ] &&
    [ "$(uci -q get firewall.${FIREWALL_FORWARDING_SECTION}.dest 2>/dev/null || true)" = xray_tun ]; then
    log success "Firewall permits LAN forwarding to the TUN zone."
  else
    log warn "TUN firewall integration is missing."
    all_ok=false
  fi

  if [ "${all_ok}" = true ]; then
    log success "TUN is fully active."
    return 0
  fi

  log error "TUN is inactive or partially configured."
  return 1
}

#######################################
# Print the script version.
#######################################
show_version() {
  printf "xray-tun version %s\n" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Print command and option documentation.
#######################################
usage() {
  cat <<EOF
Usage: $(colorize yellow "xray-tun") [OPTIONS] $(colorize green "COMMAND")

Manage OpenWrt policy routing and firewall integration for an Xray TUN
inbound. The shared Xray service is never stopped or removed.

Commands:
  setup       Create settings, init/hotplug integration, and firewall rules.
  start       Start Xray if needed and route LAN traffic through TUN.
  stop        Remove TUN routing without stopping Xray.
  restart     Reapply TUN routing.
  status      Show Xray, TUN-device, routing, and firewall status.
  enable      Enable TUN routing at boot.
  disable     Disable TUN at boot without changing the current state.
  teardown    Remove TUN integration while preserving Xray and settings.

Options:
  -c, --config FILE  Script settings file (default: ${DEFAULT_SETTINGS_FILE}).
  -h, --help         Show this help message.
  -v, --version      Show the script version.
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
    start) check_commands xray ip nft modprobe && cmd_start ;;
    stop) check_commands ip nft && cmd_stop ;;
    restart) check_commands xray ip nft modprobe && cmd_restart ;;
    status) check_commands ip nft && cmd_status ;;
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    teardown) check_commands ip nft && cmd_teardown ;;
    _start_daemon) check_commands xray ip nft modprobe && cmd_start_daemon ;;
    _stop_daemon) check_commands ip nft && cmd_stop_daemon ;;
    _reload_routes) check_commands ip nft && cmd_reload_routes ;;
    *)
      log error "Unknown command: ${command}"
      usage
      return 1
      ;;
  esac
}

main "$@"
