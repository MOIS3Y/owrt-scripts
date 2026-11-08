# Xray TProxy Manager

*Tested on OpenWrt 25.12.6*

`xray-tproxy.sh` is a management utility for Xray transparent proxying. It uses the **TPROXY** method, which is robust, supports both TCP and UDP natively, and is easy to configure on modern OpenWrt versions using `fw4` (nftables). DNS and DoT ports are deliberately left to the regular firewall path so they can be handled consistently by a local encrypted-DNS service.

Unlike simple shell scripts, this utility acts as an **installer and lifecycle manager**. It generates a native OpenWrt `init.d` service and a `hotplug` hook, ensuring that transparent interception is reconstructed after router reboots, PPPoE reconnections, and `fw4` firewall reloads.

The native Xray daemon is a shared dependency. Stopping or removing TPROXY leaves Xray running, so its SOCKS, HTTP, TUN, and other inbounds remain available.

> [!IMPORTANT]
> This script is specifically designed for OpenWrt versions using `fw4` (nftables). If you are on an older version with `iptables` (fw3), it will not work without significant modifications.

## Architecture & Traffic Flow

The following diagram illustrates how traffic flows through the router when `xray-tproxy` is active. Our script intercepts traffic on the LAN bridge and redirects it to the native Xray daemon.

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        OpenWrt 25.12.6 Router                          │
│                                                                        │
│  LAN Client ───────► br-lan (192.168.1.1)                              │
│                               │                                        │
│                               ▼                                        │
│             ┌───────────────────────────────────┐                      │
│             │ nft inet fw4 mangle_prerouting    │                      │
│             │   └─► jump xray_tproxy (index 0)  │                      │
│             │                                   │                      │
│             │ chain xray_tproxy:                │                      │
│             │  - bypass: reply / local IPs      │                      │
│             │  - bypass: LAN/Private subnets    │                      │
│             │  - bypass: DNS/DoT ports 53/853   │                      │
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

### DNS and encrypted-DNS integration

The TPROXY chain deliberately returns TCP and UDP traffic for destination
ports `53` and `853` before the final TPROXY rule. This avoids a conflict with
OpenWrt services such as `https-dns-proxy`, whose `force_dns` rules run later
in the nftables hook order.

With `https-dns-proxy` and `force_dns` enabled, the resulting flow is:

```text
LAN DNS/53 -> bypass Xray TPROXY -> force_dns redirect -> dnsmasq
           -> local https-dns-proxy -> upstream DoH

LAN DoT/853 -> bypass Xray TPROXY -> force_dns reject
```

This bypass only affects transparent interception of client packets addressed
to ports `53` and `853`. Xray's built-in DNS, domain-based routing, sniffing,
and SOCKS/HTTP inbounds continue to work normally.

## Prerequisites

Before using this script, you need to have `xray-core` and the required `tproxy` kernel modules installed.

```bash
apk update
apk add xray-core kmod-nf-tproxy kmod-nft-tproxy kmod-nft-core kmod-nft-nat kmod-nft-fib
```

*Tip: After installing kernel modules (`kmod-*`), you may need to restart your router for them to load correctly.*

You also need a basic configuration in `/etc/xray/config.json` that includes a `dokodemo-door` inbound with `followRedirect: true` and tproxy stream settings.

The standard `/etc/init.d/xray` service must be configured. During `setup`, the
TPROXY manager ensures that its required `xray.enabled.enabled='1'` UCI flag is
present. It preserves the existing config path, format, and other native Xray
settings.

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

# 2. Start Xray when necessary and activate TPROXY routing.
#    (The init script will automatically do this on boot).
xray-tproxy start

# 3. Check the current status of Xray, policy routing, and nftables.
xray-tproxy status

# 4. Remove TPROXY routing. The shared Xray process keeps running.
xray-tproxy stop

# Control whether TPROXY is reconstructed after reboot.
xray-tproxy enable
xray-tproxy disable

# 5. Completely remove all generated configs, init scripts, and hooks.
xray-tproxy teardown
```

`teardown` preserves the native Xray service, `/etc/xray/config.json`, and the
script settings file.

### Automatic Recovery

You do not need to manually run `start` after network interruptions.
The generated hook (`/etc/hotplug.d/iface/99-xray-tproxy`) listens for `ifup` events. If PPPoE reconnects or the firewall reloads, the script pauses briefly for `fw4` and then re-injects the `xray_tproxy` chain and routing rules. A runtime marker prevents hotplug from reactivating TPROXY after an explicit `stop`.

### Settings

`setup` creates `/etc/config/xray-tproxy` without overwriting an existing file:

```uci
config main 'main'
        option xray_config '/etc/xray/config.json'
        option inbound_tag 'transparent-tproxy'
        option port '10807'
        option mark '1'
        option route_table '100'
        option lan_subnet '192.168.1.0/24'
```

Use an alternative UCI settings file with `-c`:

```bash
xray-tproxy -c /etc/config/xray-tproxy-home setup
xray-tproxy -c /etc/config/xray-tproxy-home start
```

The selected path is embedded in the generated init and hotplug integration,
so the same settings are used after reboot.

### Environment Variables

You can override the default TPROXY port (10807) by setting an environment variable during `setup`:

```bash
XRAY_TPROXY_PORT=12345 xray-tproxy setup
```
