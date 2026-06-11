# Xray TProxy Manager

*Tested on OpenWrt 25.12.4*

`xray-tproxy.sh` is a management utility for Xray transparent proxying. It uses the **TPROXY** method, which is robust, supports both TCP and UDP natively (preventing DNS/QUIC leaks), and is easy to configure on modern OpenWrt versions using `fw4` (nftables).

> [!IMPORTANT]
> This script is specifically designed for OpenWrt versions using `fw4` (nftables). If you are on an older version with `iptables` (fw3), it will not work without significant modifications.

## What is a Transparent Proxy?

A transparent proxy intercepts network traffic at the router level and forwards it to a proxy client (like Xray) without requiring any configuration on the connected devices. Your phones, PCs, and IoT devices will automatically have their traffic routed through Xray, completely unaware that a proxy is involved.

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

## Usage

The script provides five main commands:

```bash
# 1. Prepare configuration and generate nftables rules
xray-tproxy setup

# 2. Start Xray service and apply firewall TPROXY routing
xray-tproxy start

# 3. Check the current status of Xray and routing rules
xray-tproxy status

# 4. Stop Xray and remove TPROXY routing rules (restores default routing)
xray-tproxy stop

# 5. Clean up all generated configurations
xray-tproxy teardown
```

## How it works

### Firewall Integration

Instead of creating complex separate tables that might conflict with OpenWrt's routing, this script injects a custom chain `xray_tproxy` into the standard `fw4` inet table.

> [!NOTE]
> The script automatically detects your LAN subnet to avoid proxying local traffic.

```text
table inet fw4 {
    chain xray_tproxy {
        # Skip local/private networks
        ip daddr { 127.0.0.0/8, 192.168.0.0/16, ... } return

        # Apply TPROXY for TCP and UDP
        meta l4proto { tcp, udp } tproxy to :10807 meta mark set 1 accept
    }
}
```

When you run `start`, the script adds a jump rule to the `mangle_prerouting` chain:
`nft add rule inet fw4 mangle_prerouting jump xray_tproxy`

Additionally, it applies policy routing (`ip rule` and `ip route`) to route marked packets into the local loopback, where Xray intercepts them.

### Environment Variables

You can override the default TPROXY port (10807) by setting an environment variable:

```bash
XRAY_TPROXY_PORT=12345 xray-tproxy setup
```
