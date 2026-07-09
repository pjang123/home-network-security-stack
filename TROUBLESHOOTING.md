# Troubleshooting

Every one of these issues was actually hit while building this project. Documented here with root cause and fix.

---

## Networking

### `apk update` fails: "wget: Operation not permitted" / "unexpected end of file"

**Symptom:** Every package download errors out even though the config looks fine.

**Root cause:** The Pi has no route to the internet at all. On a fresh OpenWrt install the single built-in ethernet port is assigned to `br-lan`, so there is **no WAN interface** — and no default route.

**Diagnose:**

```
ip route        # no "default via ..." line = no internet path
ip addr         # eth0 shows "master br-lan" = it's being used as LAN
ping 8.8.8.8    # "Network unreachable" confirms it
```

**Fix:** A Pi 4 has one ethernet port; a router needs two. Add a USB ethernet adapter, then assign the built-in port to WAN and the USB adapter to LAN (see SETUP.md §3).

---

### PC randomly loses internet when the Pi is plugged into the same router

**Symptom:** PC connectivity comes and goes after connecting the Pi to the ISP router.

**Root cause:** Two DHCP servers on one network segment. OpenWrt runs its own DHCP server on the LAN by default; when the Pi's LAN port is plugged into the ISP router's network, both answer DHCP requests and race. Devices that get their lease from the Pi receive a 192.168.1.x address with no working upstream — dead internet.

**Fix (immediate):** disable DHCP on the Pi:

```
uci set dhcp.lan.ignore=1
uci commit dhcp
service dnsmasq restart
```

Then renew the PC lease: `ipconfig /release && ipconfig /renew`.

**Fix (proper):** finish the WAN/LAN split so the Pi's DHCP only serves devices behind its LAN port.

---

### SSH connection times out after changing the Pi's IP or subnet

**Symptom:** `ssh root@192.168.1.1` (or the new IP) times out after a network change.

**Root cause:** PC and Pi are now on different subnets. A host with a 10.0.0.x address cannot reach 192.168.1.1 without a route, and vice versa.

**Diagnose:** `arp -a` on the PC and look for the Pi's MAC address — this reveals which IP it actually has, regardless of what you expected.

**Fix:** temporarily put the PC on the Pi's subnet:

```
netsh interface ip set address "Ethernet" static 192.168.1.50 255.255.255.0 192.168.1.1
```

SSH in, fix or confirm the Pi's config, then set the PC back to DHCP:

```
netsh interface ip set address "Ethernet" dhcp
netsh interface ip set dns "Ethernet" dhcp
```

**Prevention:** Tailscale. Its IP works regardless of local subnet mishaps — this is exactly why it is installed before any risky network changes.

---

### Ping sweep shows every 6th IP as "up"

**Symptom:** `for /l %i ... ping ...` sweep reports dozens of hosts in a suspiciously regular pattern.

**Root cause:** Windows ping-sweep loops of this kind produce false positives (the `&&` fires on any 0 exit, and some gateways answer for absent hosts).

**Fix:** don't sweep — read `arp -a` and match by MAC address, or check the ISP router's client list.

---

## WireGuard

### `wg-quick: not found`

**Root cause:** OpenWrt does not ship `wg-quick`. WireGuard interfaces are managed as UCI network interfaces (`proto='wireguard'`).

**Fix:** configure via UCI (SETUP.md §6) and manage with `service network restart` / `wg show`.

---

### Activating the tunnel from inside the LAN kills the client's internet

**Symptom:** Activating the WireGuard client on a PC that is *already on the Pi's LAN* drops all connectivity; `wg show` on the server shows no handshake.

**Root cause:** Routing loop. `AllowedIPs = 0.0.0.0/0` tells the client to send *everything* into the tunnel — including the tunnel's own packets to the endpoint, which is on the same network. Hairpin NAT through consumer ISP routers usually doesn't work either.

**Fix:** test from a genuinely external network (phone on mobile data). A successful tunnel shows:

```
wg show
  latest handshake: 6 seconds ago
  transfer: 65.09 KiB received, 188.98 KiB sent
```

---

### No handshake from outside

Checklist, in order:

1. Port forward UDP 51820 on the ISP router → the Pi (protocol must be UDP).
2. Firewall rule `Allow-WireGuard` on `src='wan'` exists and firewall restarted.
3. Endpoint hostname resolves to the *current* public IP (`nslookup yoursub.duckdns.org` vs `curl ifconfig.me` on the Pi).
4. Client `PublicKey` = server's public key, and server peer entry has the *client's* public key. Crossed keys fail silently.

---

## DNS / adblock-fast

### "No blocked list URLs nor blocked-domains enabled!"

**Symptom:** Service fails to start even after adding URLs via `uci add_list adblock-fast.config.blocked_url=...`.

**Root cause:** adblock-fast reads its lists from `file_url` config sections, not from the `blocked_url` option. The package ships a catalog of `file_url` entries, all `enabled='0'`.

**Fix:** enable entries from the built-in catalog instead:

```
uci show adblock-fast | grep -E "name|enabled"   # find the indexes
uci set adblock-fast.@file_url[3].enabled='1'
uci commit adblock-fast
service adblock-fast restart
```

Also install the recommended tools it warns about: `apk add gawk grep sed coreutils-sort`.

---

### `logread | grep NXDOMAIN` shows nothing even though blocking works

**Root cause:** dnsmasq does not log queries by default.

**Fix:**

```
uci set dhcp.@dnsmasq[0].logqueries='1'
uci commit dhcp
service dnsmasq restart
```

Note: `udhcpc: no lease, failing` printed during the dnsmasq restart is a harmless background DHCP retry, not an error with your change — confirm with `ping 8.8.8.8`.

---

## Monitoring

### Prometheus target DOWN: "connection refused" on 9100/9101

**Root cause:** Both OpenWrt exporters default to `listen_interface='loopback'` — they only answer on 127.0.0.1. Setting `listen_address='0.0.0.0:9101'` is **not** enough; `listen_interface` wins.

**Fix:**

```
uci set prometheus-node-exporter-lua.main.listen_interface='*'
uci commit prometheus-node-exporter-lua
service prometheus-node-exporter-lua restart

uci set prometheus-node-exporter-ucode.main.listen_interface='*'
uci commit prometheus-node-exporter-ucode
service prometheus-node-exporter-ucode restart

netstat -tlnp | grep -E "9100|9101"    # must show 0.0.0.0, not 127.0.0.1
```

---

### Docker: "ports are not available ... access a socket in a way forbidden"

**Root cause:** Windows (Hyper-V/WSL2) reserves large TCP port ranges. Ports 3000–3607 are commonly inside an excluded range, so Grafana's default 3000 fails.

**Diagnose:**

```
netsh interface ipv4 show excludedportrange protocol=tcp
```

**Fix:** map to a host port outside the excluded ranges, e.g. `-p 8080:3000`. If a container was created before the failure, `docker rm <name>` before re-running (name conflicts).

---

### Grafana panel: "parse error: invalid nested repetition operator `*+`"

**Root cause:** PromQL arithmetic (e.g. `metric_a + metric_b`) typed into the **Builder**'s Metric field is interpreted as a metric-name regex.

**Fix:** switch the query editor from **Builder** to **Code** and type the expression there. For Stat/Gauge panels also set the query **Type** to **Instant**.

---

### Grafana shows the full metric label instead of a clean name

**Fix:** per query, set **Options → Legend** to Custom and type a plain label (`Blocked`, `Allowed`). Note `{{Blocked}}` is template syntax and resolves to nothing — use plain text. Colors are set per-series via panel **Overrides → Fields with name → Color**.

---

## SSH / dropbear

### Locked-out risk when disabling password auth

Dropbear (OpenWrt's SSH server) reads keys from `/etc/dropbear/authorized_keys`, not `~/.ssh/authorized_keys`.

Safe order of operations:

1. Add the public key, `chmod 600 /etc/dropbear/authorized_keys`.
2. **From a second terminal**, confirm key login works.
3. Only then set `PasswordAuth='off'` and `RootPasswordAuth='off'`.
4. Keep the existing session open until the new one is confirmed.
5. Tailscale remains the recovery path if everything else goes wrong.

### "It still lets me in with a password!"

Probably not — the Windows OpenSSH client automatically tries `%USERPROFILE%\.ssh\id_ed25519` even without `-i`. Prove password auth is dead with:

```
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@192.168.1.1
→ Permission denied (publickey)
```

---

## General recovery

| Situation | Way back in |
|---|---|
| Broke LAN config | Static-IP the PC onto the Pi's subnet, SSH to the LAN IP |
| Broke firewall/SSH | `ssh root@<tailscale-ip>` |
| Broke everything | Monitor + keyboard on the Pi (micro-HDMI), or reflash the SD card |

Reflashing takes ~10 minutes and this guide exists — sometimes a clean slate is faster than archaeology.
