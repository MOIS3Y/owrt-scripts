#!/usr/bin/env ash
# shellcheck shell=dash
#
# Zsh + Oh My Zsh installer for OpenWrt.
# Installs zsh, oh-my-zsh, and plugins (autosuggestions, syntax-highlighting)
# without git dependency. Supports installation and removal.
#

set -eu

readonly SCRIPT_VERSION="0.1.0"
readonly OMZ_REPO="ohmyzsh/ohmyzsh"

# Use HOME with fallback to /root
readonly USER_HOME="${HOME:-/root}"
readonly OMZ_DIR="${USER_HOME}/.oh-my-zsh"

# Plugin URLs (split to stay under 79 chars)
readonly GH_PLUGINS="https://github.com/zsh-users"
readonly TAR_BALL="archive/refs/heads/master.tar.gz"
readonly PLUGIN_SYNTAX_URL="${GH_PLUGINS}/zsh-syntax-highlighting/${TAR_BALL}"
readonly PLUGIN_SUGGEST_URL="${GH_PLUGINS}/zsh-autosuggestions/${TAR_BALL}"

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
# Checks and installs system packages using apk or opkg.
#######################################
install_pkgs() {
  log info "Checking system dependencies..."
  if command -v apk > /dev/null 2>&1; then
    apk add zsh curl tar
  elif command -v opkg > /dev/null 2>&1; then
    opkg update
    opkg install zsh curl tar
  else
    log error "No package manager found (apk/opkg)."
    return 1
  fi
}

#######################################
# Downloads and extracts a tarball to a destination.
# Arguments:
#   1: Source URL
#   2: Destination directory
#######################################
fetch_and_extract() {
  local url="$1"
  local dest="$2"

  log info "Downloading from ${url}..."
  mkdir -p "${dest}"
  curl -sSL "${url}" | tar -xz -C "${dest}" --strip-components=1
}

#######################################
# Installation logic.
#######################################
cmd_install() {
  install_pkgs || return 1

  if [ -d "${OMZ_DIR}" ]; then
    log warn "Oh My Zsh is already installed in ${OMZ_DIR}."
  else
    log info "Installing Oh My Zsh..."
    local omz_url="https://github.com/${OMZ_REPO}/${TAR_BALL}"
    fetch_and_extract "${omz_url}" "${OMZ_DIR}" || return 1
  fi

  # Install Plugins
  local plugin_dir="${OMZ_DIR}/custom/plugins"
  
  log info "Installing zsh-syntax-highlighting..."
  local syntax_path="${plugin_dir}/zsh-syntax-highlighting"
  fetch_and_extract "${PLUGIN_SYNTAX_URL}" "${syntax_path}" || return 1
  
  log info "Installing zsh-autosuggestions..."
  local suggest_path="${plugin_dir}/zsh-autosuggestions"
  fetch_and_extract "${PLUGIN_SUGGEST_URL}" "${suggest_path}" || return 1

  # Initial .zshrc setup
  if [ ! -f "${USER_HOME}/.zshrc" ]; then
    log info "Creating initial .zshrc..."
    cp "${OMZ_DIR}/templates/zshrc.zsh-template" "${USER_HOME}/.zshrc"
    
    # Disable updates using the modern zstyle method (essential without git)
    # We insert it at the top to ensure it's picked up
    sed -i "1i zstyle ':omz:update' mode disabled" "${USER_HOME}/.zshrc"
    
    # Configure plugins (removing git as it's not installed)
    local plugins_regex='s/plugins=(git)/plugins=(zsh-syntax-highlighting '
    plugins_regex="${plugins_regex}zsh-autosuggestions)/"
    sed -i "${plugins_regex}" "${USER_HOME}/.zshrc"
  fi

  # Change shell for current user
  local current_user
  current_user=$(id -un)
  log info "Changing default shell to zsh for user ${current_user}..."
  sed -i "s|^\(${current_user}:.*:\)/bin/ash|\1/usr/bin/zsh|" /etc/passwd

  log success "Installation complete! Please log out and log back in."
}

#######################################
# Update logic.
#######################################
cmd_update() {
  log info "Updating Oh My Zsh and plugins..."
  
  if [ ! -d "${OMZ_DIR}" ]; then
    log error "Oh My Zsh is not installed. Run 'install' first."
    return 1
  fi

  # Update OMZ Core
  log info "Updating Oh My Zsh core..."
  local omz_url="https://github.com/${OMZ_REPO}/${TAR_BALL}"
  fetch_and_extract "${omz_url}" "${OMZ_DIR}" || return 1

  # Update Plugins
  local plugin_dir="${OMZ_DIR}/custom/plugins"
  
  log info "Updating zsh-syntax-highlighting..."
  local syntax_path="${plugin_dir}/zsh-syntax-highlighting"
  fetch_and_extract "${PLUGIN_SYNTAX_URL}" "${syntax_path}" || return 1
  
  log info "Updating zsh-autosuggestions..."
  local suggest_path="${plugin_dir}/zsh-autosuggestions"
  fetch_and_extract "${PLUGIN_SUGGEST_URL}" "${suggest_path}" || return 1

  log success "Update complete! Please restart your Zsh session."
}

#######################################
# Removal logic.
#######################################
cmd_uninstall() {
  log info "Uninstalling Oh My Zsh and restoring ash..."
  
  # Restore ash shell for current user
  local current_user
  current_user=$(id -un)
  log info "Restoring default shell to ash for user ${current_user}..."
  sed -i "s|^\(${current_user}:.*:\)/usr/bin/zsh|\1/bin/ash|" /etc/passwd
  
  log info "Removing Oh My Zsh files (preserving history)..."
  rm -rf "${OMZ_DIR}"
  rm -f "${USER_HOME}/.zshrc"

  log info "Removing zsh packages..."
  if command -v apk > /dev/null 2>&1; then
    apk del zsh || true
  elif command -v opkg > /dev/null 2>&1; then
    opkg remove zsh || true
  fi

  log success "Oh My Zsh and Zsh removed. Default shell restored to ash."
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

OpenWrt Zsh + Oh My Zsh Installer.

$(colorize blue "Commands:")
  $(colorize green "install")    Install zsh, oh-my-zsh, and plugins.
  $(colorize green "update")     Update oh-my-zsh and plugins to latest.
  $(colorize green "uninstall")  Remove everything and restore ash shell.
  $(colorize green "version")    Show version information.

$(colorize blue "Global Options:")
  -h, --help     Show this help message.
  -v, --version  Show the script version.
EOF
}

#######################################
# Script entry point.
#######################################
main() {
  if [ $# -eq 0 ]; then
    usage
    return 1
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    install)
      cmd_install
      ;;
    update)
      cmd_update
      ;;
    uninstall)
      cmd_uninstall
      ;;
    version|-v|--version)
      show_version
      ;;
    help|-h|--help)
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
