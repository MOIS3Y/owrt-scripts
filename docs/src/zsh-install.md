# Zsh Installer

*Tested on OpenWrt 25.12.4*

`zsh-install.sh` is a utility for automating the installation and removal of **Zsh**, **Oh My Zsh**, and popular plugins on OpenWrt. It is designed to be lightweight and does not require `git`.

> [!IMPORTANT]
> Zsh and Oh My Zsh can consume a significant amount of flash memory (approx. 5-10 MB depending on the number of plugins and themes). Ensure your router has enough free space in `/overlay`.

## Features

- **No Git Dependency**: Downloads components as tarballs to save space and avoid extra dependencies.
- **Auto-Config**: Automatically sets up `.zshrc` with recommended plugins.
- **Smart Shell Switch**: Changes the default shell for `root` from `ash` to `zsh`.
- **Easy Removal**: Includes an `uninstall` command to restore `ash` and clean up all files.

## Installation

### Using `wget`

```bash
wget -qO /usr/bin/zsh-install https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/zsh-install.sh && chmod +x /usr/bin/zsh-install
```

### Using `curl`

```bash
curl -sSL -o /usr/bin/zsh-install https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/zsh-install.sh && chmod +x /usr/bin/zsh-install
```

## Usage

### Install Zsh and Oh My Zsh

This command will install `zsh`, `curl`, and `tar`, download Oh My Zsh, install `zsh-syntax-highlighting` and `zsh-autosuggestions` plugins, and change your default shell.

```bash
zsh-install install
```

> [!TIP]
> After installation, you need to log out and log back in (or restart the SSH session) to see the changes.

### Update Oh My Zsh and Plugins

Since this installer doesn't use `git`, the standard Oh My Zsh auto-update feature is disabled. You can manually update the core and plugins by running:

```bash
zsh-install update
```

This will download the latest versions and overwrite the files in `${HOME}/.oh-my-zsh` while preserving your `.zshrc` and history.

### Command History and Flash Wear

By default, Zsh is configured to save command history to `${HOME}/.zsh_history`.

> [!NOTE]
> Persistent history is essential for the **zsh-autosuggestions** plugin to work across sessions. If you are concerned about flash memory wear (e.g., if you run thousands of commands daily), you can limit the history size in your `.zshrc` or disable it, but autosuggestions will only work for the current session.

### Uninstall and Restore Ash

If you want to revert all changes and go back to the default `ash` shell:

```bash
zsh-install uninstall
```

## How it works

1. **Dependency Check**: Uses `apk` (OpenWrt 24+) or `opkg` to install necessary system packages.
2. **Component Fetching**: Downloads the latest master branches of Oh My Zsh and plugins as `.tar.gz` archives.
3. **Shell Configuration**: Modifies `/etc/passwd` to change the login shell for the `root` user.
4. **Cleanup**: The `uninstall` command restores the original shell path in `/etc/passwd` and removes `/root/.oh-my-zsh`, `.zshrc`, and history files.
