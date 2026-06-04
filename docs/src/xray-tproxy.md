# Xray TProxy Manager

*Tested on OpenWrt 25.12.4*

`xray-tproxy.sh` is a management utility for Xray transparent proxying. It uses the **NAT REDIRECT** method, which is robust and easy to configure on modern OpenWrt versions using `fw4` (nftables).

> [!IMPORTANT]
> This script is specifically designed for OpenWrt versions using `fw4` (nftables). If you are on an older version with `iptables` (fw3), it will not work without significant modifications.

## What is a Transparent Proxy?

A transparent proxy intercepts network traffic at the router level and forwards it to a proxy client (like Xray) without requiring any configuration on the connected devices. Your phones, PCs, and IoT devices will automatically have their traffic routed through Xray, completely unaware that a proxy is involved.

## Common Use Cases

- **Whole-Home Bypass**: Circumvent ISP censorship or geo-blocks for all devices on your local network simultaneously.
- **Unsupported Devices**: Route traffic for devices that don't support VPN apps or custom proxy settings (e.g., Apple TV, smart TVs, game consoles, IoT devices).
- **Centralized Routing**: Use Xray's powerful internal routing rules to decide which domains/IPs go through the proxy tunnel and which go directly to the internet, managed entirely in one place on the router.

> [!NOTE]
> This script handles the **firewall redirection** part. It catches all TCP traffic and sends it to Xray. You must still configure Xray's routing rules (`routing` object in `config.json`) to define what actually gets proxied and what goes direct.

## Prerequisites

Before using this script, you need to have `xray-core` installed and a basic configuration in `/etc/xray/config.json` that includes a `dokodemo-door` inbound with `followRedirect: true`.

> [!TIP]
> You can install Xray on OpenWrt using `apk add xray-core`. For older versions, use `opkg install`.

Example Xray inbound:
```json
"inbounds": [
  {
    "tag": "transparent-redirect",
    "port": 10807,
    "protocol": "dokodemo-door",
    "settings": { "network": "tcp,udp", "followRedirect": true },
    "streamSettings": { "sockopt": { "tproxy": "redirect" } }
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

The script provides four main commands:

```bash
# 1. Prepare configuration and generate nftables rules
xray-tproxy setup

# 2. Start Xray service and apply firewall redirection
xray-tproxy start

# 3. Stop Xray and remove redirection rules (restores default routing)
xray-tproxy stop

# 4. Clean up all generated configurations
xray-tproxy teardown
```

## How it works

### Firewall Integration

Instead of creating complex separate tables, this script injects a custom chain `xray_redirect` into the standard `fw4` inet table.

> [!NOTE]
> The script automatically detects your LAN subnet to avoid proxying local traffic.

```text
table inet fw4 {
    chain xray_redirect {
        # Skip local/private networks
        ip daddr { 127.0.0.0/8, 192.168.0.0/16, ... } return

        # Redirect everything else to Xray port
        meta l4proto tcp redirect to :10807
    }
}
```

When you run `start`, the script adds a jump rule to the `dstnat` chain:
`nft add rule inet fw4 dstnat jump xray_redirect`

### Environment Variables

You can override the default redirection port (10807) by setting an environment variable:

```bash
XRAY_REDIRECT_PORT=12345 xray-tproxy setup
```
