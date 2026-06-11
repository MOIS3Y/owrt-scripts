# Xray TProxy Manager

*Tested on OpenWrt 25.12.4*

`xray-tproxy.sh` is a management utility for Xray transparent proxying. It uses the **TPROXY** method, which is robust, supports both TCP and UDP natively (preventing DNS/QUIC leaks), and is easy to configure on modern OpenWrt versions using `fw4` (nftables).

Unlike simple bash scripts, this utility acts as an **installer and lifecycle manager**. It generates a native OpenWrt `init.d` daemon and a `hotplug` hook, ensuring that your transparent proxy automatically survives router reboots, PPPoE reconnections, and `fw4` firewall reloads.

> [!IMPORTANT]
> This script is specifically designed for OpenWrt versions using `fw4` (nftables). If you are on an older version with `iptables` (fw3), it will not work without significant modifications.

## Architecture & Traffic Flow

The following diagram illustrates how traffic flows through the router when `xray-tproxy` is active. Our script intercepts traffic on the LAN bridge and redirects it to the native Xray daemon.

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        OpenWrt 25.12.4 Router                          │
│                                                                        │
│  LAN Client ───────► br-lan (192.168.1.1)                              │
│                               │                                        │
│                               ▼                                        │
│             ┌───────────────────────────────────┐                      │
│             │ nft inet fw4 mangle_prerouting    │                      │
│             │   └─► jump xray_tproxy (index 0)  │                      │
│             │                                   │                      │
│             │ chain xray_tproxy:                │                      │
│             │  - bypass: LAN/Private subnets    │                      │
│             │  - TPROXY: TCP/UDP to port 10807  │                      │
│             │            meta mark set 1        │                      │
│             └───────────────────────────────────┘                      │
│                               │                                        │
│                               ▼ (mark 1, ip rule → table 100)          │
│             ┌───────────────────────────────────┐                      │
│             │ policy routing (table 100)        │                      │
│             │  - ip route add local default     │                      │
│             │    dev lo                         │                      │
│             └───────────────────────────────────┘                      │
│                               │                                        │
│                               ▼                                        │
│             ┌───────────────────────────────────┐                      │
│             │ Native Xray Daemon (/etc/init.d)  │                      │
│             │ Inbound: 10807 (dokodemo-door)    │                      │
│             │ Sniffing: TLS / HTTP / QUIC       │                      │
│             │ Routing: Managed by config.json   │                      │
│             └───────────────────────────────────┘                      │
│                               │                                        │
│         ┌─────────────────────┼─────────────────────┐                  │
│         ▼                     ▼                     ▼                  │
│ ┌───────────────┐     ┌───────────────┐     ┌───────────────┐          │
│ │ Direct Out    │     │ Proxy Out     │     │ Block / Drop  │          │
│ │ (e.g. geo:ru) │     │ (VLESS/Shadow)│     │ (e.g. ads)    │          │
│ └───────────────┘     └───────────────┘     └───────────────┘          │
│         │                     │                                        │
└─────────┼─────────────────────┼────────────────────────────────────────┘
          ▼                     ▼
        eth0 / pppoe-wan ──► ISP (Internet)
```

## Common Use Cases

- **Whole-Home Bypass**: Circumvent ISP censorship or geo-blocks for all devices on your local network simultaneously.
- **Unsupported Devices**: Route traffic for devices that don't support VPN apps or custom proxy settings (e.g., Apple TV, smart TVs, game consoles, IoT devices).
- **Centralized Routing**: Use Xray's powerful internal routing rules to decide which domains/IPs go through the proxy tunnel and which go directly to the internet, managed entirely in one place on the router.

> [!NOTE]
> This script handles the **firewall routing** part. It catches TCP and UDP traffic using policy routing and firewall marks, and sends it to Xray. You must still configure Xray's routing rules (`routing` object in `config.json`) to define what actually gets proxied and what goes direct.

## Prerequisites

Before using this script, you need to have `xray-core` and the required `tproxy` kernel modules installed.

```bash
apk update
apk add xray-core kmod-nf-tproxy kmod-nft-tproxy kmod-nft-core kmod-nft-nat kmod-nft-fib
```

*Tip: After installing kernel modules (`kmod-*`), you may need to restart your router for them to load correctly.*

You also need a basic configuration in `/etc/xray/config.json` that includes a `dokodemo-door` inbound with `followRedirect: true` and tproxy stream settings.

**Example Xray inbound:**
```json
"inbounds": [
  {
    "tag": "transparent-tproxy",
    "port": 10807,
    "protocol": "dokodemo-door",
    "settings": {
      "network": "tcp,udp",
      "followRedirect": true
    },
    "streamSettings": {
      "sockopt": {
        "tproxy": "tproxy"
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }
]
```

## Installation

> [!NOTE]
> Make sure you have `wget` or `curl` installed on your router (`apk add curl` or `apk add wget-ssl`). For older versions, use `opkg install`.

### Using `wget`

```bash
wget -qO /usr/bin/xray-tproxy https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/xray-tproxy.sh && chmod +x /usr/bin/xray-tproxy
```

### Using `curl`

```bash
curl -sSL -o /usr/bin/xray-tproxy https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/xray-tproxy.sh && chmod +x /usr/bin/xray-tproxy
```

## Usage (Lifecycle Commands)

This script manages its own lifecycle. The commands are strictly idempotent, meaning you can safely run them multiple times.

```bash
# 1. Prepare configuration, generate init script and hotplug hook.
#    (Must be run once after downloading).
xray-tproxy setup

# 2. Start Xray service and activate TPROXY routing.
#    (The init script will automatically do this on boot).
xray-tproxy start

# 3. Check the current status of Xray, iptables, and nftables.
xray-tproxy status

# 4. Stop Xray and remove routing rules (restores direct internet).
xray-tproxy stop

# 5. Completely remove all generated configs, init scripts, and hooks.
xray-tproxy teardown
```

### Automatic Recovery

You do not need to manually run `start` after network interruptions.
The generated hook (`/etc/hotplug.d/iface/99-xray-tproxy`) listens for `ifup` events. If your PPPoE reconnects or the firewall reloads, the script will automatically pause for a few seconds to let `fw4` settle, and then seamlessly re-inject the `xray_tproxy` chain and routing rules.

### Environment Variables

You can override the default TPROXY port (10807) by setting an environment variable during `setup`:

```bash
XRAY_TPROXY_PORT=12345 xray-tproxy setup
```
