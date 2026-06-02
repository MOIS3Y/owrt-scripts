#!/usr/bin/env ash
#
# DHCP Static Lease Management for OpenWrt.
# Subcommands: add, del, show, edit, apply.
# Provides a full interactive menu if no command is specified.
#

set -eu

readonly SCRIPT_VERSION="0.1.0"

#######################################
# Wraps text in ANSI color codes for terminal output.
# Arguments:
#   1: Color name (red, green, yellow, blue).
#   2: Text string to be colorized.
# Outputs:
#   Writes the colorized string to stdout using %b for escape sequences.
#######################################
colorize() {
  local color; color="$1"
  local text; text="$2"
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
# Unified logging function with colored level prefixes.
# Arguments:
#   1: Log level (info, success, warn, error).
#   2: Message string.
# Outputs:
#   Writes formatted output to stdout, except for 'error' level
#    which is directed to stderr.
#######################################
log() {
  local level; level="$1"
  local msg; msg="$2"

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
# Arguments:
#   Variable number of command names.
# Returns:
#   0 if all exist, exits with 1 and logs missing if any are found.
#######################################
check_deps() {
  local missing=""; local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
      missing="${missing}${cmd} "
    fi
  done
  if [ -n "${missing}" ]; then
    log error "Missing dependencies: ${missing}"
    exit 1
  fi
}

#######################################
# Validates MAC address format using a regular expression.
# Arguments:
#   1: MAC address string (e.g., AA:BB:CC:DD:EE:FF).
# Returns:
#   0 if valid, 1 otherwise.
#######################################
validate_mac() {
  echo "$1" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

#######################################
# Validates IPv4 address format using a regular expression.
# Arguments:
#   1: IP address string (e.g., 192.168.1.1).
# Returns:
#   0 if valid, 1 otherwise.
#######################################
validate_ip() {
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

#######################################
# Searches for a UCI host section ID by Name, MAC, or IP.
# Iterates through all 'host' sections in the 'dhcp' config.
# Arguments:
#   1: Search target (hostname, MAC address, or IP address).
# Outputs:
#   Writes the found UCI section ID to stdout.
# Returns:
#   0 regardless of success; check output length to confirm findings.
#######################################
find_host_id() {
  local target; target="$1"
  local host_id; local found=""
  local hosts; hosts=$(uci -q show dhcp | grep "=host" | \
                        cut -d. -f2 | cut -d= -f1)

  for host_id in ${hosts}; do
    local n; n=$(uci -q get "dhcp.${host_id}.name" || echo "")
    local m; m=$(uci -q get "dhcp.${host_id}.mac" || echo "")
    local i; i=$(uci -q get "dhcp.${host_id}.ip" || echo "")
    if [ "${target}" = "${n}" ] || [ "${target}" = "${m}" ] || \
       [ "${target}" = "${i}" ]; then
      found="${host_id}"
      break
    fi
  done
  echo "${found}"
}

#######################################
# Interactively prompts the user to select a static lease.
# Outputs:
#   Writes the selected UCI host ID to stdout.
# Returns:
#   0 on success, 1 on failure.
#######################################
select_static_lease() {
  local hosts; hosts=$(uci -q show dhcp | grep "=host" | \
                        cut -d. -f2 | cut -d= -f1)
  if [ -z "${hosts}" ]; then
    log error "No static leases configured." >&2
    return 1
  fi

  log info "Configured Static Leases:" >&2
  local count=1
  printf "%s\n" "${hosts}" | while read -r id; do
    if [ -z "${id}" ]; then continue; fi
    local n; n=$(uci -q get "dhcp.${id}.name" || echo "-")
    local m; m=$(uci -q get "dhcp.${id}.mac" || echo "-")
    local i; i=$(uci -q get "dhcp.${id}.ip" || echo "-")
    printf "%2d) %-18s %-15s %s\n" "${count}" "${m}" "${i}" "${n}" >&2
    count=$((count + 1))
  done

  local choice
  choice=$(prompt_input "Enter Number or Name/MAC/IP")

  # Check if choice is a pure number
  if echo "${choice}" | grep -qE '^[0-9]+$'; then
    local selected_id
    selected_id=$(printf "%s\n" "${hosts}" | sed -n "${choice}p")
    if [ -n "${selected_id}" ]; then
      echo "${selected_id}"
      return 0
    fi
  fi

  # Fallback to standard search
  local id
  id=$(find_host_id "${choice}")
  if [ -n "${id}" ]; then
    echo "${id}"
    return 0
  fi

  log error "Lease not found." >&2
  return 1
}

#######################################
# Finalizes UCI changes and restarts the networking service.
# Performs a physical write to flash and restarts dnsmasq.
# Outputs:
#   Writes status messages to stdout.
#######################################
apply_changes() {
  log info "Committing changes to UCI..."
  uci commit dhcp
  log info "Restarting dnsmasq..."
  if [ -x /etc/init.d/dnsmasq ]; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
  fi
  log success "Changes applied and service restarted."
}

#######################################
# Displays a combined view of active and static DHCP leases.
# Parses /tmp/dhcp.leases for active clients and UCI for static ones.
# Outputs:
#   Writes formatted tables to stdout.
#######################################
show_leases() {
  printf "\n%s %s %s\n" "---" "$(colorize blue "Active DHCP")" "---"
  if [ -f /tmp/dhcp.leases ]; then
    printf "%-3s %-18s %-15s %s\n" "ID" "MAC" "IP" "Hostname"
    local count=1
    while read -r _ mac ip host _; do
      printf "%2d) %-18s %-15s %s\n" "${count}" "${mac}" "${ip}" "${host}"
      count=$((count + 1))
    done < /tmp/dhcp.leases
  else
    log warn "No active leases found."
  fi

  printf "\n%s %s %s\n" "---" "$(colorize blue "Static UCI")" "---"
  local hosts; hosts=$(uci -q show dhcp | grep "=host" | \
                        cut -d. -f2 | cut -d= -f1)
  if [ -z "${hosts}" ]; then
    log info "No static leases configured."
  else
    printf "%-3s %-18s %-15s %s\n" "ID" "MAC" "IP" "Hostname"
    local count=1
    printf "%s\n" "${hosts}" | while read -r id; do
      if [ -z "${id}" ]; then continue; fi
      local n; n=$(uci -q get "dhcp.${id}.name" || echo "-")
      local m; m=$(uci -q get "dhcp.${id}.mac" || echo "-")
      local i; i=$(uci -q get "dhcp.${id}.ip" || echo "-")
      printf "%2d) %-18s %-15s %s\n" "${count}" "${m}" "${i}" "${n}"
      count=$((count + 1))
    done
  fi
  printf "\n"
}

#######################################
# Prompts for user input with optional validation and default value.
# Redirects prompts to stderr to allow clean command substitution.
# Arguments:
#   1: Prompt message.
#   2: Validator function name (optional).
#   3: Default value (optional).
# Outputs:
#   Writes the validated input to stdout.
#######################################
prompt_input() {
  local msg="$1"
  local func="${2:-}"
  local default="${3:-}"
  local val
  local prompt_label="${msg}"

  if [ -n "${default}" ]; then
    prompt_label="${msg} [${default}]"
  fi

  while true; do
    printf "%s: " "$(colorize yellow "${prompt_label}")" >&2
    read -r val

    if [ -z "${val}" ] && [ -n "${default}" ]; then
      val="${default}"
    fi

    if [ -z "${val}" ]; then
      log error "Value cannot be empty."
      continue
    fi

    if [ -n "${func}" ]; then
      if "${func}" "${val}"; then
        echo "${val}"
        return 0
      else
        log error "Invalid format."
        continue
      fi
    fi
    echo "${val}"
    return 0
  done
}

#######################################
# Displays a summary and asks for user confirmation.
# Arguments:
#   1: Hostname summary.
#   2: MAC address summary.
#   3: IP address summary.
# Returns:
#   0 if user confirms (y/Y), 1 otherwise.
#######################################
confirm_settings() {
  local c
  printf "\nName: %s\nMAC:  %s\nIP:   %s\n" "$1" "$2" "$3"
  printf "%s [y/N]: " "$(colorize yellow "Apply?")"
  read -r c
  case "${c}" in
    [yY]*) return 0 ;;
    *) return 1 ;;
  esac
}

#######################################
# Stages a new static lease entry in UCI.
# Supports both direct flags and interactive smart prompting.
# Arguments:
#   Flags: -n (name), -m (mac), -i (ip), -s (silent).
#######################################
add_lease() {
  local name=""; local mac=""; local ip=""
  local silent="false"; local opt

  OPTIND=1
  while getopts "n:m:i:s" opt; do
    case "${opt}" in
      n) name="$OPTARG";;
      m) mac="$OPTARG";;
      i) ip="$OPTARG";;
      s) silent="true";;
      *) return 1;;
    esac
  done

  if [ -z "${name}" ] && [ -z "${mac}" ] && [ -z "${ip}" ]; then
    if [ "${silent}" = "true" ]; then
      log error "Need all args for silent mode."
      exit 1
    fi

    if [ -f /tmp/dhcp.leases ] && [ -s /tmp/dhcp.leases ]; then
      log info "Active Leases:" >&2
      printf "   %-18s %-15s %s\n" "MAC" "IP" "Hostname" >&2
      local i=1; local _mac; local _ip; local _name
      while read -r _ _mac _ip _name _; do
        printf "%2d) %-18s %-15s %s\n" "${i}" "${_mac}" "${_ip}" "${_name}" >&2
        i=$((i + 1))
      done < /tmp/dhcp.leases

      local choice
      choice=$(prompt_input "Enter Number to bind, or new Name for manual")

      if echo "${choice}" | grep -qE '^[0-9]+$'; then
        local entry
        entry=$(sed -n "${choice}p" /tmp/dhcp.leases)
        if [ -n "${entry}" ]; then
          mac=$(echo "${entry}" | cut -d' ' -f2)
          ip=$(echo "${entry}" | cut -d' ' -f3)
          name=$(echo "${entry}" | cut -d' ' -f4)

          log info "Promoting ${name} (${mac})." >&2
          name=$(prompt_input "Name" "" "${name}")
          ip=$(prompt_input "IP" validate_ip "${ip}")
        else
          log warn "Invalid number, proceeding to manual entry." >&2
          name="${choice}"
          mac=$(prompt_input "MAC" validate_mac)
          ip=$(prompt_input "IP" validate_ip)
        fi
      else
        name="${choice}"
        mac=$(prompt_input "MAC" validate_mac)
        ip=$(prompt_input "IP" validate_ip)
      fi
    else
      name="${name:-$(prompt_input "Name")}"
      mac="${mac:-$(prompt_input "MAC" validate_mac)}"
      ip="${ip:-$(prompt_input "IP" validate_ip)}"
    fi
  fi

  if ! validate_mac "${mac}"; then
    log error "Bad MAC: ${mac}"
    exit 1
  fi

  if ! validate_ip "${ip}"; then
    log error "Bad IP: ${ip}"
    exit 1
  fi

  if [ "${silent}" = "false" ]; then
    if ! confirm_settings "${name}" "${mac}" "${ip}"; then
      return 0
    fi
  fi

  uci add dhcp host > /dev/null
  uci set "dhcp.@host[-1].name=${name}"
  uci set "dhcp.@host[-1].mac=${mac}"
  uci set "dhcp.@host[-1].ip=${ip}"

  if [ "${silent}" = "false" ]; then
    log success "Staged: ${name} added."
  fi
}

#######################################
# Modifies an existing static lease field.
# Arguments:
#   1: Target search string (optional).
#######################################
edit_lease() {
  local target; target="${1:-}"
  local id; local field; local val

  if [ -z "${target}" ]; then
    id=$(select_static_lease) || return 1
  else
    id=$(find_host_id "${target}")
    if [ -z "${id}" ]; then
      log error "Not found."
      return 1
    fi
  fi

  local current_name
  current_name=$(uci -q get "dhcp.${id}.name" || echo "unknown")

  log info "Editing: ${current_name}"
  printf "1) Name  2) MAC  3) IP  4) Cancel\nChoice: "
  read -r field

  case "${field}" in
    1)
      val=$(prompt_input "New Name")
      uci set "dhcp.${id}.name=${val}"
      ;;
    2)
      val=$(prompt_input "New MAC" validate_mac)
      uci set "dhcp.${id}.mac=${val}"
      ;;
    3)
      val=$(prompt_input "New IP" validate_ip)
      uci set "dhcp.${id}.ip=${val}"
      ;;
    *)
      log info "Cancelled."
      return 0
      ;;
  esac
  log success "Staged: update for ${current_name}."
}

#######################################
# Removes a static lease section from UCI.
# Arguments:
#   1: Target search string (optional).
#######################################
del_lease() {
  local target; target="${1:-}"
  local id

  if [ -z "${target}" ]; then
    id=$(select_static_lease) || return 1
  else
    id=$(find_host_id "${target}")
    if [ -z "${id}" ]; then
      log error "Not found."
      return 1
    fi
  fi

  local name
  name=$(uci -q get "dhcp.${id}.name" || echo "unknown")
  uci delete "dhcp.${id}"
  log success "Staged: ${name} deleted."
}

#######################################
# Main interactive loop.
#######################################
interactive_menu() {
  local choice
  while true; do
    printf "\n--- %s ---\n" "$(colorize blue "DHCP MENU")"
    printf "1) Show  2) Add  3) Edit  4) Delete  "
    printf "5) Apply  6) Exit\n"
    printf "Choice: "
    read -r choice

    case "${choice}" in
      1) show_leases ;;
      2) add_lease ;;
      3) edit_lease ;;
      4) del_lease ;;
      5) apply_changes ;;
      6) log info "Bye!"; exit 0 ;;
      *) log warn "Unknown choice." ;;
    esac
  done
}

#######################################
# Displays script version.
#######################################
show_version() {
  printf "dhcp-lease.sh version %s\n" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Displays detailed usage information.
#######################################
usage() {
  cat << EOF
Usage: $(colorize yellow "$(basename "$0")") $(colorize green "COMMAND") [OPTIONS]

OpenWrt DHCP Static Lease Manager. Starts interactive menu if no command.

$(colorize blue "Commands:")
  $(colorize green "add") [-n name] [-m mac] [-i ip] [-s]
      Adds a static lease. Interactively allows picking from active leases.
      -n NAME  Hostname
      -m MAC   MAC address (AA:BB:CC:DD:EE:FF)
      -i IP    Static IPv4 address
      -s       Silent: no confirmation, no colors, auto-apply

  $(colorize green "del") [TARGET]
      Deletes a static lease by Number, Name, MAC, or IP.

  $(colorize green "edit") [TARGET]
      Edits a static lease by Number, Name, MAC, or IP.

  $(colorize green "show")
      Lists active (dynamic) and configured static leases.

  $(colorize green "apply")
      Commits all staged changes and restarts the DHCP service.

  $(colorize green "help")
      Shows this help message.

  $(colorize green "version")
      Shows the script version.

$(colorize blue "Global Options:")
  -h, --help     Show this help message.
  -v, --version  Show the script version.
EOF
}

#######################################
# Script entry point.
#######################################
main() {
  check_deps uci sed

  if [ $# -eq 0 ]; then
    interactive_menu
    return
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    -h|--help|help)
      usage
      ;;
    -v|--version|version)
      show_version
      ;;
    add)
      add_lease "$@"
      local is_s="false"
      local a
      for a in "$@"; do
        if [ "$a" = "-s" ]; then
          is_s="true"
        fi
      done
      if [ "${is_s}" = "true" ]; then
        apply_changes
      fi
      ;;
    del)
      del_lease "${1:-}"
      apply_changes
      ;;
    edit)
      edit_lease "${1:-}"
      apply_changes
      ;;
    show)
      show_leases
      ;;
    apply)
      apply_changes
      ;;
    *)
      log error "Unknown command: ${cmd}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
