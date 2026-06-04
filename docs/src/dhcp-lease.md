# DHCP Lease Manager

*Tested on OpenWrt 25.12.4*

The `dhcp-lease.sh` script is a tool I wrote to manage static DHCP leases on OpenWrt without having to touch the web interface or remember complex UCI commands.

> [!NOTE]
> This script is a wrapper around `uci`. It ensures that all changes follow OpenWrt's configuration standards.

## Installation

> [!NOTE]
> Make sure you have `wget` or `curl` installed on your router (`apk add curl` or `apk add wget-ssl`). For older versions, use `opkg install`.

### Using `wget`

```bash
wget -qO /usr/bin/dhcp-lease https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/dhcp-lease.sh && chmod +x /usr/bin/dhcp-lease
```

### Using `curl`

```bash
curl -sSL -o /usr/bin/dhcp-lease https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/dhcp-lease.sh && chmod +x /usr/bin/dhcp-lease
```

## Features

- **Interactive Menu**: Run the script without arguments to get a user-friendly menu.
- **CLI Commands**: Direct subcommands for automation (`add`, `del`, `show`, `edit`, `apply`).
- **Validation**: Checks for valid MAC and IP addresses before applying changes.
- **Service Restart**: Automatically restarts `dnsmasq` to apply new leases.

## Usage

### Interactive Mode

Simply run the script:

```bash
dhcp-lease
```

You will see an interactive menu that displays both currently active DHCP leases and your static UCI configurations:

```text
--- DHCP MENU ---
1) Show  2) Add  3) Edit  4) Delete  5) Apply  6) Exit
Choice: 1

--- Active DHCP ---
ID  MAC                IP              Hostname
 1) a2:b3:c4:d5:e6:f7  192.168.1.152   android-phone
 2) 11:22:33:44:55:66  192.168.1.102   smart-vacuum
 3) aa:bb:cc:dd:ee:ff  192.168.1.245   pixel-phone
 4) 99:88:77:66:55:44  192.168.1.189   *
 5) de:ad:be:ef:00:11  192.168.1.97    desktop-pc
 6) fe:dc:ba:98:76:54  192.168.1.200   home-server-vms
 7) 00:11:22:33:44:55  192.168.1.100   home-server

--- Static UCI ---
ID  MAC                IP              Hostname
 1) de:ad:be:ef:00:11  192.168.1.97    desktop-pc
 2) 02:46:8a:ce:13:57  192.168.1.98    desktop-wifi
 3) 13:57:9b:df:24:68  192.168.1.99    work-laptop
 4) 00:11:22:33:44:55  192.168.1.100   home-server
 5) fe:dc:ba:98:76:54  192.168.1.200   home-server-vms

--- DHCP MENU ---
1) Show  2) Add  3) Edit  4) Delete  5) Apply  6) Exit
```

### CLI Mode

If you want to use it in scripts or for quick actions:

```bash
# Add a new lease
dhcp-lease add -n "MyPC" -m "AA:BB:CC:DD:EE:FF" -i "192.168.1.100"

# List all static leases
dhcp-lease show

# Delete a lease by name, MAC, or IP
dhcp-lease del "MyPC"

# Apply pending changes (restarts dnsmasq)
dhcp-lease apply
```

> [!TIP]
> Use the `apply` command after making multiple changes to minimize `dnsmasq` restarts.

## How it works

The script uses `uci` to manipulate the `/etc/config/dhcp` file. When you add or edit a lease, it creates a `host` section. 

> [!IMPORTANT]
> Changes made via `add`, `del`, or `edit` are staged. You **must** run `apply` (or `uci commit dhcp`) to make them permanent and active.
