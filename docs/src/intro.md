# Introduction

Welcome! This is a collection of scripts I've written and gathered to manage my router.

I built these tools to make my life easier when dealing with routine router maintenance and advanced network setups. While these scripts are tailored for my specific hardware and firmware version, they should work on most modern OpenWrt installations that use `fw4` (nftables).

## Why scripts?

While the LuCI web interface is great, I find myself working in the terminal more often. UCI (Unified Configuration Interface) is powerful, but typing long commands for every static lease or firewall rule can be tedious. These scripts act as wrappers around UCI and other system tools to provide a more streamlined experience.

## My Setup

- **Hardware**: ASUS TUF-AX4200
- **Firmware**: OpenWrt 25.12.4 r32933-4ccb782af7
- **Firewall**: fw4 (nftables)

## What's inside?

- **[DHCP Lease Manager](dhcp-lease.md)**: Interactive and CLI tool for static IP assignments.
- **[Xray TProxy Manager](xray-tproxy.md)**: A helper to manage transparent proxying for Xray with nftables.

Feel free to browse, use, or adapt these scripts for your own needs! ❤️
