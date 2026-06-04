# Vim Configurator

*Tested on OpenWrt 25.12.4*

`vim-config.sh` is a utility for automating the installation of **Vim (full version)** and applying a modern, lightweight configuration (`.vimrc`).

> [!NOTE]
> Standard OpenWrt comes with a very basic `vi` (provided by BusyBox). This script installs the full-featured Vim package which supports syntax highlighting, visual mode, and more.

## Features

- **Standard Vim**: Installs the `vim-full` package for maximum compatibility and features.
- **Optimized .vimrc**: Sets up numbers, relative numbers, 2-space indentation, and mouse support.
- **Smart Undo**: Configures persistent undo history in `~/.vim/undodir`.
- **Lightweight**: Pure `ash` script with no extra dependencies.

## Installation

### Using `wget`

```bash
wget -qO /usr/bin/vim-config https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/vim-config.sh && chmod +x /usr/bin/vim-config
```

### Using `curl`

```bash
curl -sSL -o /usr/bin/vim-config https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/vim-config.sh && chmod +x /usr/bin/vim-config
```

## Usage

### Install and Configure

This command will install `vim-full` and generate a `.vimrc` in your home directory.

```bash
vim-config install
```

### Uninstall

To remove Vim and delete the configuration files:

```bash
vim-config uninstall
```

## Configuration Details

The generated `.vimrc` includes:
- `syntax on`: Enable syntax highlighting.
- `set number`: Show line numbers.
- `set tabstop=2 shiftwidth=2 expandtab`: Consistent 2-space indentation.
- `set mouse=a`: Enable mouse support for scrolling and selecting.
- `set incsearch ignorecase smartcase`: Improved search behavior.
- `set undofile`: Persistent undo across sessions.
