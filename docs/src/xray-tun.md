# Xray TUN Manager

*Tested on OpenWrt 25.12.6*

`xray-tun.sh` routes IPv4 traffic arriving from the LAN bridge into a TUN
interface created by Xray. Xray then applies the same domain, IP, protocol,
balancer, and outbound rules used by its other inbounds.

The script owns only OpenWrt policy routing, firewall integration, init hooks,
and hotplug recovery. It never stops or removes the shared Xray service.

## Traffic flow

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                         OpenWrt 25.12.6 Router                           │
│                                                                          │
│  LAN Client ───────► br-lan (192.168.1.1/24)                             │
│                               │                                          │
│                               ▼                                          │
│             ┌─────────────────────────────────────┐                      │
│             │ IPv4 policy rule (priority 11000)   │                      │
│             │  - iif: br-lan                      │                      │
│             │  - from: 192.168.1.0/24             │                      │
│             │  - lookup: table 101                │                      │
│             └─────────────────────────────────────┘                      │
│                               │                                          │
│                 ┌─────────────┴─────────────┐                            │
│                 │                           │                            │
│                 ▼                           ▼                            │
│   ┌──────────────────────────┐  ┌──────────────────────────┐             │
│   │ Private/link-local route │  │ Internet destination     │             │
│   │ throw → normal main      │  │ default dev xray0        │             │
│   │ routing table            │  │ routing table 101        │             │
│   └──────────────────────────┘  └──────────────────────────┘             │
│                                             │                            │
│                                             ▼                            │
│                           ┌───────────────────────────────┐              │
│                           │ Xray TUN interface: xray0     │              │
│                           │ Inbound: transparent-tun      │              │
│                           │ Sniffing: HTTP / TLS / QUIC   │              │
│                           └───────────────────────────────┘              │
│                                             │                            │
│                                             ▼                            │
│                           ┌───────────────────────────────┐              │
│                           │ Shared Xray routing rules     │              │
│                           │ geoip / geosite / protocol    │              │
│                           │ balancer / direct selection   │              │
│                           └───────────────────────────────┘              │
│                                             │                            │
│                  ┌──────────────────────────┴───────────────────────┐    │
│                  ▼                                                  ▼    │
│      ┌───────────────────────┐                        ┌────────────────┐ │
│      │ Proxy outbound        │                        │ Freedom/direct │ │
│      │ VLESS / XHTTP / etc.  │                        │ outbound       │ │
│      └───────────────────────┘                        └────────────────┘ │
│                  │                                                  │    │
│                  └──────────────────────────┬───────────────────────┘    │
│                                             ▼                            │
│                         normal main table → pppoe-wan                    │
└─────────────────────────────────────────────┬────────────────────────────┘
                                              ▼
                                             ISP
```

The policy rule applies only to packets received from `br-lan`. Connections
created locally by Xray therefore keep using the normal WAN route and do not
loop back into the TUN interface.

Packets in the reply direction of an existing conntrack flow are marked before
the TUN policy rule and sent through the normal `main` table. This preserves
the return path for WAN port forwards while newly initiated LAN connections
still enter `xray0`.

Private, link-local, and multicast destinations are represented by `throw`
routes in table 101. They continue to the normal OpenWrt routing tables.

## Prerequisites

Install Xray and kernel TUN support:

```bash
apk update
apk add xray-core kmod-tun
```

The standard `/etc/init.d/xray` service must already be configured. During
`setup`, the TUN manager ensures that its required
`xray.enabled.enabled='1'` UCI flag is present. It preserves the existing
config path, format, and other native Xray settings.

Add a TUN inbound to the existing `/etc/xray/config.json`:

```json
{
  "tag": "transparent-tun",
  "protocol": "tun",
  "settings": {
    "name": "xray0",
    "mtu": 1500,
    "gateway": [
      "172.31.255.1/30"
    ]
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ],
    "routeOnly": true
  }
}
```

> [!IMPORTANT]
> Do not configure `autoSystemRoutingTable`: this script deliberately installs
> a more selective rule for forwarded LAN traffic.

If the final Xray routing rule is restricted by inbound tag, add the TUN tag:

```json
"inboundTag": [
  "transparent-tproxy",
  "transparent-tun",
  "socks-in",
  "http-in"
]
```

Validate and restart Xray after editing it:

```bash
xray run -test -format json -config /etc/xray/config.json
/etc/init.d/xray restart
```

## Installation

```bash
curl -sSL -o /usr/bin/xray-tun \
  https://raw.githubusercontent.com/MOIS3Y/owrt-scripts/main/src/xray-tun.sh
chmod +x /usr/bin/xray-tun
```

## Usage

```bash
# Create settings, firewall integration, init service, and hotplug hooks.
# setup also enables TUN routing after future reboots but does not start it now.
xray-tun setup

# Route LAN clients through the TUN inbound now.
xray-tun start

# Inspect Xray, xray0, policy routing, and firewall state.
xray-tun status

# Remove TUN routing without stopping Xray.
xray-tun stop

# Control reconstruction after reboot.
xray-tun enable
xray-tun disable

# Remove TUN integration while preserving Xray and script settings.
xray-tun teardown
```

`stop` removes the policy rule and flushes table 101. The `xray0` interface can
remain visible because it belongs to the running Xray TUN inbound, but no LAN
traffic is routed into it.

## Settings

`setup` creates `/etc/config/xray-tun` without overwriting an existing file:

```uci
config main 'main'
        option xray_config '/etc/xray/config.json'
        option inbound_tag 'transparent-tun'
        option device 'xray0'
        option lan_device 'br-lan'
        option lan_subnet '192.168.1.0/24'
        option route_table '101'
        option rule_priority '11000'
        option reply_rule_priority '10900'
        option reply_mark '2'
        option wait_seconds '20'

        list bypass_cidr '10.0.0.0/8'
        list bypass_cidr '172.16.0.0/12'
        list bypass_cidr '192.168.0.0/16'
        list bypass_cidr '169.254.0.0/16'
        list bypass_cidr '224.0.0.0/4'
```

Use another UCI settings file with `-c`:

```bash
xray-tun -c /etc/config/xray-tun-home setup
xray-tun -c /etc/config/xray-tun-home start
```

The generated init service and hotplug hooks retain the selected path.

`reply_mark` is a single packet-mark bit used to recognize conntrack reply
traffic. The script preserves all other mark bits and matches this bit with a
mask, allowing common `mwan3` and `pbr` mark ranges to coexist. Change the
value to another power of two if local policy-routing software already owns
bit `0x2`. `reply_rule_priority` must be numerically lower than
`rule_priority` so the reply bypass is evaluated first.

## Port forwards

TUN policy routing must not capture replies from services reached through a
WAN port forward. The manager installs the following logical path:

```text
New LAN connection
  → unmarked → table 101 → xray0

Reply to an existing WAN connection
  → conntrack reply → mark bit 0x2 → main table → WAN
```

This distinction also permits a LAN Xray server to use the router as an
upstream transparent proxy: replies on its public listener return directly to
the remote client, while separate outbound connections created by that server
are new flows and continue through the router's TUN inbound.

## Reboot and recovery

`setup` creates and enables `/etc/init.d/xray-tun`. During boot it starts Xray
if necessary, waits for `xray0`, and reconstructs table 101 and its policy rule.

The interface hotplug hook restores routing after network events. A separate
device hotplug hook handles recreation of `xray0` after an Xray restart. Both
hooks check `/var/run/xray-tun.active`, so an explicit `stop` remains stopped
for the rest of the current boot.

## Switching between TPROXY and TUN

Both inbounds can stay in the same Xray configuration. Only one OpenWrt
delivery mechanism should be active for the same LAN traffic.

TPROXY to TUN:

```bash
xray-tproxy stop
xray-tun start
xray-tproxy disable
xray-tun enable
```

TUN to TPROXY:

```bash
xray-tun stop
xray-tproxy start
xray-tun disable
xray-tproxy enable
```

The scripts do not call each other or change each other's state.
