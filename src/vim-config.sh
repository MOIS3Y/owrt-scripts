#!/usr/bin/env ash
# shellcheck shell=dash
#
# Vim installer and configuration for OpenWrt.
# Installs vim-full and sets up a modern, lightweight .vimrc.
#

set -eu

readonly SCRIPT_VERSION="0.1.0"
readonly USER_HOME="${HOME:-/root}"
readonly VIMRC_PATH="${USER_HOME}/.vimrc"

#######################################
# Wraps text in ANSI color codes for terminal output.
# Arguments:
#   1: Color name (red, green, yellow, blue).
#   2: Text string to be colorized.
# Outputs:
#   Writes the colorized string to stdout.
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
# Unified logging function with colored level prefixes.
# Arguments:
#   1: Log level (info, success, warn, error).
#   2: Message string.
# Outputs:
#   Writes formatted output to stdout/stderr.
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
# Installs the vim-full package using the available package manager.
# Returns:
#   0 on success, 1 on failure.
#######################################
install_pkgs() {
  log info "Installing vim-full..."
  if command -v apk > /dev/null 2>&1; then
    apk add vim-full
  elif command -v opkg > /dev/null 2>&1; then
    opkg update
    opkg install vim-full
  else
    log error "No package manager found (apk/opkg)."
    return 1
  fi
}

#######################################
# Generates a minimal and functional .vimrc configuration.
# Outputs:
#   Writes the .vimrc file to the user's home directory.
# Returns:
#   0 on success, 1 on failure.
#######################################
setup_vimrc() {
  log info "Generating ${VIMRC_PATH}..."
  
  cat << EOF > "${VIMRC_PATH}"
" Managed by vim-config.sh
syntax on
set number
set tabstop=2
set shiftwidth=2
set expandtab
set smartindent
set mouse=a
set ignorecase
set smartcase
set incsearch
set noswapfile
set nobackup
set undodir=${USER_HOME}/.vim/undodir
set undofile
set background=dark

" Colorscheme fix for some terminals
if !has('gui_running') && &term =~ 'xterm'
  set t_Co=256
endif
EOF

  mkdir -p "${USER_HOME}/.vim/undodir"
  log success "Vim configuration applied."
}

#######################################
# Removes Vim and its associated configuration and undo files.
# Returns:
#   0 on success.
#######################################
cmd_uninstall() {
  log info "Removing Vim and configuration..."
  
  rm -f "${VIMRC_PATH}"
  rm -rf "${USER_HOME}/.vim"

  if command -v apk > /dev/null 2>&1; then
    apk del vim-full || true
  elif command -v opkg > /dev/null 2>&1; then
    opkg remove vim-full || true
  fi

  log success "Vim uninstalled and config removed."
}

#######################################
# Orchestrates the full installation and configuration process.
# Returns:
#   0 on success, 1 on failure.
#######################################
cmd_install() {
  install_pkgs || return 1
  setup_vimrc || return 1
  log success "Vim is ready to use."
}

#######################################
# Displays the current script version.
# Outputs:
#   Writes the version string to stdout.
#######################################
show_version() {
  local name="${0##*/}"
  name="${name%.sh}"
  printf "%s version %s\n" "${name}" "$(colorize green "${SCRIPT_VERSION}")"
}

#######################################
# Displays detailed usage information.
# Outputs:
#   Writes help text to stdout.
#######################################
usage() {
  local name="${0##*/}"
  name="${name%.sh}"
  cat << EOF
Usage: $(colorize yellow "${name}") $(colorize green "COMMAND")

OpenWrt Vim Installer and Configurator.

$(colorize blue "Commands:")
  $(colorize green "install")    Install vim-full and apply configuration.
  $(colorize green "uninstall")  Remove Vim and cleanup configurations.
  $(colorize green "version")    Show version information.

$(colorize blue "Global Options:")
  -h, --help     Show this help message.
  -v, --version  Show the script version.
EOF
}

#######################################
# Script entry point.
# Arguments:
#   Variable number of command-line arguments.
# Returns:
#   0 on success, 1 on failure.
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
