# Setup Guide

Complete step-by-step guide to build this stack from scratch. Commands were run on OpenWrt 25.12 (apk-based) on a Raspberry Pi 4. Adjust IPs and hostnames for your environment.

> **Convention used below**
> - `Pi #` — run on the Raspberry Pi over SSH
> - `PC >` — run on your Windows PC (Command Prompt unless PowerShell is stated)
> - Upstream/ISP router assumed at `10.0.0.1`; the Pi's LAN is `192.168.1.0/24`

---

## Contents

1. [Flash OpenWrt](#1-flash-openwrt)
2. [First SSH Session](#2-first-ssh-session)
3. [Configure WAN and LAN](#3-configure-wan-and-lan)
4. [DNS Blocking (adblock-fast)](#4-dns-blocking-adblock-fast)
5. [Tailscale (install this before WireGuard)](#5-tailscale)
6. [WireGuard VPN Server](#6-wireguard-vpn-server)
7. [Dynamic DNS (DuckDNS)](#7-dynamic-dns-duckdns)
8. [Port Forwarding](#8-port-forwarding)
9. [WireGuard Client Setup](#9-wireguard-client-setup)
10. [Security Hardening](#10-security-hardening)
11. [Monitoring (Prometheus + Grafana)](#11-monitoring-prometheus--grafana)
12. [Verification Checklist](#12-verification-checklist)

---

## 1. Flash OpenWrt

1. Download the Pi 4 image (`bcm27xx/bcm2711`) from the [OpenWrt table of hardware](https://openwrt.org/toh/raspberry_pi_foundation/raspberry_pi).
2. Flash it to the microSD card with Raspberry Pi Imager or Balena Etcher.
3. Physical connections **for initial setup**:
   - Pi built-in ethernet → your PC directly (OpenWrt defaults the built-in port to LAN)
4. Boot the Pi.

## 2. First SSH Session

OpenWrt defaults to `192.168.1.1` with no root password and does not run DHCP toward your PC in all setups, so give the PC a static IP first:

```
PC > netsh interface ip set address "Ethernet" static 192.168.1.50 255.255.255.0 192.168.1.1
PC > ssh root@192.168.1.1
```

Set a root password immediately:

```
Pi # passwd
```

## 3. Configure WAN and LAN

The Pi 4 has one ethernet port. A router needs two interfaces, so a USB 3.0 gigabit adapter (ASIX AX88179 — driver is built into the OpenWrt kernel) provides the second one.

Target layout:

| Physical port | Interface | Role |
|---|---|---|
| Built-in ethernet | `eth0` | WAN → ISP router |
| USB adapter | `eth1` | LAN → PC / switch |

**Run the config first, then swap cables** (the SSH session drops when the network restarts):

```
Pi # uci set network.lan.device='eth1'
Pi # uci set network.wan=interface
Pi # uci set network.wan.device='eth0'
Pi # uci set network.wan.proto='dhcp'
Pi # uci commit network
Pi # service network restart
```

Now swap cables: built-in port → ISP router, USB adapter → PC. SSH back in (`ssh root@192.168.1.1`) and verify:

```
Pi # ping 8.8.8.8          # raw connectivity
Pi # ping google.com       # DNS resolution
Pi # apk update            # package lists — should list ~11,000 packages
```

All three must succeed before continuing.

## 4. DNS Blocking (adblock-fast)

```
Pi # apk add adblock-fast luci-app-adblock-fast gawk grep sed coreutils-sort
Pi # uci set adblock-fast.config.enabled='1'
```

adblock-fast ships with a catalog of pre-configured blocklists (`file_url` entries), all disabled by default. Enable a reasonable trio — Hagezi Pro, StevenBlack, AdAway:

```
Pi # uci set adblock-fast.@file_url[0].enabled='1'    # Hagezi - Pro
Pi # uci set adblock-fast.@file_url[3].enabled='1'    # StevenBlack - Unified hosts
Pi # uci set adblock-fast.@file_url[11].enabled='1'   # AdAway - Hosts
Pi # uci commit adblock-fast
Pi # service adblock-fast enable
Pi # service adblock-fast start
```

> Index numbers can shift between package versions. Run `uci show adblock-fast` to confirm which index maps to which list.

Expected output ends with something like:

```
[STAT] adblock-fast 1.2.4-r2 is blocking 251852 domains (with dnsmasq.servers)
```

Enable DNS query logging so blocks are visible:

```
Pi # uci set dhcp.@dnsmasq[0].logqueries='1'
Pi # uci commit dhcp
Pi # service dnsmasq restart
```

Watch it work:

```
Pi # logread -f | grep NXDOMAIN
```

Browse any ad-heavy site from a LAN device — blocked domains stream past as `config <domain> is NXDOMAIN`.

## 5. Tailscale

Install Tailscale **before** WireGuard. It provides an independent SSH path into the Pi that survives any firewall or network misconfiguration you might make later.

```
Pi # apk add tailscale iptables ip6tables
Pi # service tailscale enable
Pi # service tailscale start
Pi # tailscale up
```

Authenticate via the printed URL, then record the Tailscale IP:

```
Pi # tailscale ip
```

From now on, `ssh root@<tailscale-ip>` works from any of your devices on the tailnet, regardless of the state of the LAN.

## 6. WireGuard VPN Server

### Install and generate keys

```
Pi # apk add wireguard-tools kmod-wireguard
Pi # mkdir -p /etc/wireguard
Pi # wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
Pi # wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key
Pi # chmod 600 /etc/wireguard/*_private.key
```

### Configure the interface (UCI — `wg-quick` does not exist on OpenWrt)

```
Pi # uci set network.wg0=interface
Pi # uci set network.wg0.proto='wireguard'
Pi # uci set network.wg0.private_key="$(cat /etc/wireguard/server_private.key)"
Pi # uci set network.wg0.listen_port='51820'
Pi # uci add_list network.wg0.addresses='10.9.0.1/24'

Pi # uci add network wireguard_wg0
Pi # uci set network.@wireguard_wg0[-1].name='client1'
Pi # uci set network.@wireguard_wg0[-1].public_key="$(cat /etc/wireguard/client_public.key)"
Pi # uci add_list network.@wireguard_wg0[-1].allowed_ips='10.9.0.2/32'

Pi # uci commit network
Pi # service network restart
```

### Firewall

```
Pi # uci add firewall rule
Pi # uci set firewall.@rule[-1].name='Allow-WireGuard'
Pi # uci set firewall.@rule[-1].src='wan'
Pi # uci set firewall.@rule[-1].dest_port='51820'
Pi # uci set firewall.@rule[-1].proto='udp'
Pi # uci set firewall.@rule[-1].target='ACCEPT'

Pi # uci add firewall zone
Pi # uci set firewall.@zone[-1].name='wireguard'
Pi # uci set firewall.@zone[-1].input='ACCEPT'
Pi # uci set firewall.@zone[-1].output='ACCEPT'
Pi # uci set firewall.@zone[-1].forward='ACCEPT'
Pi # uci add_list firewall.@zone[-1].network='wg0'

Pi # uci add firewall forwarding
Pi # uci set firewall.@forwarding[-1].src='wireguard'
Pi # uci set firewall.@forwarding[-1].dest='wan'

Pi # uci commit firewall
Pi # service firewall restart
```

Verify the interface is up:

```
Pi # wg show
```

## 7. Dynamic DNS (DuckDNS)

Residential public IPs rotate. DuckDNS gives you a fixed hostname that follows the IP.

1. Create a free subdomain + token at [duckdns.org](https://www.duckdns.org).
2. Install the update script (see [`scripts/ddns-update.sh`](scripts/ddns-update.sh)):

```
Pi # cat > /etc/ddns-update.sh << 'EOF'
#!/bin/sh
curl "https://www.duckdns.org/update?domains=YOUR_SUBDOMAIN&token=YOUR_TOKEN&ip=" -o /tmp/duckdns.log
EOF
Pi # chmod +x /etc/ddns-update.sh
```

3. Test, then schedule it every 5 minutes:

```
Pi # sh /etc/ddns-update.sh && cat /tmp/duckdns.log     # must print OK
Pi # echo "*/5 * * * * /etc/ddns-update.sh" >> /etc/crontabs/root
Pi # service cron enable
Pi # service cron start
```

## 8. Port Forwarding

On the **ISP router's** admin page, forward:

| Setting | Value |
|---|---|
| Protocol | UDP |
| External port | 51820 |
| Internal host | the Pi (select by MAC or its WAN-side IP) |
| Internal port | 51820 |

Without this rule, WireGuard packets from the internet die at the ISP router.

## 9. WireGuard Client Setup

Create the client config (template at [`wireguard/client.conf.example`](wireguard/client.conf.example)):

```ini
[Interface]
PrivateKey = <contents of client_private.key>
Address = 10.9.0.2/24
DNS = 10.9.0.1

[Peer]
PublicKey = <contents of server_public.key>
Endpoint = YOUR_SUBDOMAIN.duckdns.org:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

- `DNS = 10.9.0.1` routes client DNS through adblock-fast — VPN clients get ad/malware blocking anywhere in the world.
- `AllowedIPs = 0.0.0.0/0` tunnels *all* client traffic through the Pi.

Import into the WireGuard app (scan a QR code for phones):

```
Pi # apk add qrencode
Pi # qrencode -t ansiutf8 < /path/to/client1.conf
```

**Test from an outside network** (phone on mobile data — testing from inside the LAN causes a routing loop and will appear broken). A working tunnel shows a recent handshake:

```
Pi # wg show
  latest handshake: 6 seconds ago
  transfer: 65.09 KiB received, 188.98 KiB sent
```

## 10. Security Hardening

### Force DNS — clients cannot bypass the filter

```
Pi # uci add firewall redirect
Pi # uci set firewall.@redirect[-1].name='Force-DNS'
Pi # uci set firewall.@redirect[-1].src='lan'
Pi # uci set firewall.@redirect[-1].dest='lan'
Pi # uci set firewall.@redirect[-1].proto='tcp udp'
Pi # uci set firewall.@redirect[-1].src_dport='53'
Pi # uci set firewall.@redirect[-1].dest_port='53'
Pi # uci set firewall.@redirect[-1].target='DNAT'
Pi # uci commit firewall && service firewall restart
```

### Block SSH from WAN

```
Pi # uci add firewall rule
Pi # uci set firewall.@rule[-1].name='Block-SSH-WAN'
Pi # uci set firewall.@rule[-1].src='wan'
Pi # uci set firewall.@rule[-1].dest_port='22'
Pi # uci set firewall.@rule[-1].proto='tcp'
Pi # uci set firewall.@rule[-1].target='DROP'
Pi # uci commit firewall && service firewall restart
```

### SSH keys only

On the PC:

```
PC > ssh-keygen -t ed25519 -C "openwrt-key"
PC > type %USERPROFILE%\.ssh\id_ed25519.pub
```

On the Pi (dropbear, not OpenSSH):

```
Pi # mkdir -p /etc/dropbear
Pi # echo "<paste the ssh-ed25519 line>" >> /etc/dropbear/authorized_keys
Pi # chmod 600 /etc/dropbear/authorized_keys
```

**Test key login from a second terminal before disabling passwords**, then:

```
Pi # uci set dropbear.@dropbear[0].PasswordAuth='off'
Pi # uci set dropbear.@dropbear[0].RootPasswordAuth='off'
Pi # uci commit dropbear
Pi # service dropbear restart
```

Confirm passwords are rejected:

```
PC > ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@192.168.1.1
→ Permission denied (publickey)
```

## 11. Monitoring (Prometheus + Grafana)

### Exporters on the Pi

System metrics (port 9100) and dnsmasq/DNS metrics (port 9101):

```
Pi # apk add prometheus-node-exporter-lua \
      prometheus-node-exporter-lua-openwrt \
      prometheus-node-exporter-lua-nat_traffic \
      prometheus-node-exporter-lua-netstat \
      prometheus-node-exporter-lua-thermal \
      prometheus-node-exporter-ucode-dnsmasq

Pi # uci set prometheus-node-exporter-lua.main.listen_interface='*'
Pi # uci commit prometheus-node-exporter-lua
Pi # service prometheus-node-exporter-lua enable
Pi # service prometheus-node-exporter-lua restart

Pi # uci set prometheus-node-exporter-ucode.main.listen_interface='*'
Pi # uci commit prometheus-node-exporter-ucode
Pi # service prometheus-node-exporter-ucode enable
Pi # service prometheus-node-exporter-ucode restart
```

> Both exporters default to `listen_interface='loopback'` and are unreachable from the network until this is changed. `listen_address` alone is **not** sufficient — `listen_interface` takes precedence.

Verify:

```
Pi # netstat -tlnp | grep -E "9100|9101"     # both must show 0.0.0.0
Pi # curl -s http://localhost:9101/metrics | grep dnsmasq_dns
```

### Prometheus + Grafana on a PC (Docker)

Config: [`prometheus/prometheus.yml`](prometheus/prometheus.yml)

```
PC (PowerShell) > mkdir C:\monitoring
# copy prometheus.yml into C:\monitoring, then:

PC (PowerShell) > docker network create monitoring

PC (PowerShell) > docker run -d --name prometheus --restart always `
    --network monitoring -p 9090:9090 `
    -v C:\monitoring\prometheus.yml:/etc/prometheus/prometheus.yml `
    prom/prometheus

PC (PowerShell) > docker run -d --name grafana --restart always `
    --network monitoring -p 8080:3000 `
    grafana/grafana
```

> Windows + Hyper-V reserves large TCP port ranges (often 3000–3600). If a `docker run` fails with *"an attempt was made to access a socket in a way forbidden"*, pick another host port. Check reservations with `netsh interface ipv4 show excludedportrange protocol=tcp`.

### Wire it together

1. Prometheus targets: `http://localhost:9090/targets` — both jobs must be **UP**.
2. Grafana: `http://localhost:8080` (admin/admin on first login).
3. Add data source → Prometheus → URL `http://prometheus:9090` (container-to-container DNS on the `monitoring` network).
4. Import community dashboard **11147** for system metrics.
5. Build a DNS panel with these queries (**Code** mode, query type **Instant**):

| Panel | PromQL |
|---|---|
| Blocked queries | `dnsmasq_dns_local_answered_total` |
| Allowed queries | `dnsmasq_dns_queries_forwarded_total` |
| Total queries | `dnsmasq_dns_local_answered_total + dnsmasq_dns_queries_forwarded_total` |
| Block rate % | `dnsmasq_dns_local_answered_total / (dnsmasq_dns_local_answered_total + dnsmasq_dns_queries_forwarded_total) * 100` (unit: Percent 0-100) |

## 12. Verification Checklist

| Check | Command / method | Pass condition |
|---|---|---|
| Internet from Pi | `ping 8.8.8.8` | replies |
| DNS from Pi | `ping google.com` | resolves + replies |
| Ad blocking | `nslookup doubleclick.net 192.168.1.1` from a client | NXDOMAIN / 0.0.0.0 |
| Live block log | `logread -f \| grep NXDOMAIN` | blocked domains stream while browsing |
| VPN from outside | phone on mobile data → `wg show` | recent `latest handshake` |
| VPN routes traffic | whatismyip.com on the phone | shows home IP, not carrier IP |
| DuckDNS | `nslookup YOUR_SUBDOMAIN.duckdns.org` | current home public IP |
| Tailscale backdoor | `ssh root@<tailscale-ip>` from off-LAN | shell |
| Password SSH dead | `ssh -o PreferredAuthentications=password ...` | Permission denied (publickey) |
| Reboot survival | `reboot`, wait 60 s | all services return (`wg show`, `service adblock-fast status`, `service tailscale status`, `crontab -l`) |
| Monitoring | `http://localhost:9090/targets` | all targets UP |
