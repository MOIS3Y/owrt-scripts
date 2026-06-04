# OpenWrt Scripts

<p align="center">
  <a href="https://github.com/MOIS3Y/owrt-scripts/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge&labelColor=101418" alt="License">
  </a>
  <a href="https://github.com/MOIS3Y/owrt-scripts/blob/main/flake.nix">
    <img src="https://img.shields.io/badge/Nix-Enabled-blueviolet?style=for-the-badge&logo=nixos&logoColor=white&labelColor=101418" alt="Nix">
  </a>
  <a href="https://openwrt.org">
    <img src="https://img.shields.io/badge/OpenWrt-25.12.4-success?style=for-the-badge&logo=openwrt&logoColor=white&labelColor=101418" alt="OpenWrt">
  </a>
  <a href="https://mois3y.github.io/owrt-scripts/">
    <img src="https://img.shields.io/badge/Docs-Latest-blue?style=for-the-badge&labelColor=101418" alt="Docs">
  </a>
</p>

My personal collection of scripts for OpenWrt management.

This repository contains a set of utility scripts I use on my **ASUS TUF-AX4200** (running **OpenWrt 25.12.4**). These tools help me automate routine tasks like managing DHCP leases and configuring transparent proxying with Xray.

I've decided to share them in case someone finds them useful for their own setup.

---

## Features

- **`dhcp-lease.sh`**: Easily manage static DHCP leases via CLI or an interactive menu.
- **`xray-tproxy.sh`**: Manage Xray transparent proxy (NAT REDIRECT) using modern `nftables` (fw4).
- **UCI-native**: All scripts interact with OpenWrt's configuration system properly.
- **Lightweight**: Written in `ash`, no heavy dependencies required on the router.

## Usage

For detailed installation instructions, prerequisites, and command examples, please refer to the [Documentation](https://mois3y.github.io/owrt-scripts/).

## Development

This project uses **Nix** for the development environment. It provides all necessary tools like `mdbook`, `shellcheck`, and `bats`.

```bash
nix develop
```

## Credits & Inspiration

- [OpenWrt Project](https://openwrt.org/)
- [Xray-core](https://github.com/XTLS/Xray-core)

---

> [!WARNING]
> These scripts are provided "as is". Always back up your router configuration before making changes.
