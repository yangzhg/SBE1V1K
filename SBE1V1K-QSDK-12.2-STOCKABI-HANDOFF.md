# SBE1V1K QSDK 12.2 stock-ABI + LuCI 交接

## 1. 交付目标

本分支的唯一目标是：

```text
SBE1V1K 原厂 NHSS.QSDK.12.2.r6 内核/驱动/无线 ABI
+ OpenWrt 19.07/QSDK 同代管理面
+ LuCI、rpcd、uhttpd、Dropbear、UCI、netifd、firewall3
= 通过受审计的首次过渡升级器从当前 192.168.1.1 刷入的私有镜像
```

目标文件名：

```text
sbe1v1k-qsdk12-stockabi-sysupgrade.bin
```

当前 macOS 阶段只完成方案、受约束构建器、首次过渡升级器和 rootfs overlay；尚未生成最终 `.bin`，也没有刷机。实际构建与真机测试在后续准备好的 WSL2 ext4 环境继续。

## 2. 为什么采用 stock-ABI 路线

dump 标识为：

```text
APPS:       NHSS.QSDK.12.2.r6-00023-P-1
Linux:      5.4.213
WLAN WBE:   WLAN.WBE.1.1.r7-00022
NSS FW:     None
```

这里口头所说的“原厂闭源 NSS 功能”，实际是原厂同版的 SSDK、主机侧 NSS-DP/PPE 数据路径、PPE-VP、PPE-DS、PPEDS、ECM、CNSS2 和 qca-wifi 协同工作；不是另一个可提取的 NSS firmware。

原厂模块来自 `gac77edb-dirty` 树。即使公开 QSDK r6 同为 5.4.213，也不能把公开树重编 kernel 与 dump 的单个 `.ko` 混用。因此首版把以下内容视为一个不可拆分的 ABI 岛：

- p25 中的原厂内层 FIT；
- p27 中完整 `/lib/modules/5.4.213`；
- p27 中原厂 QCA Wi-Fi/PPE 用户态、对应动态库、配置 glue 和加载顺序。

另有一组设备原位只读依赖，不复制进 sysupgrade：p22 LICENSE、真机现存 p23/p24 WIFIFW、真机自己的 p20 ART/MAC/caldata，以及 p43 manufacturing 数据。

只替换厂商云控/Web 管理面并加入 LuCI。详细依据见 [SBE1V1K-QSDK-12.2-CLEAN-OPENWRT.md](SBE1V1K-QSDK-12.2-CLEAN-OPENWRT.md)。

## 3. 当前状态

工作分支：

```text
sbe1v1k-qsdk12-stockabi
```

分支基线：

```text
main @ bc5ebab7baf665ddc9a6cd32736c19d649648808
```

交接时以远端 `sbe1v1k-qsdk12-stockabi` 的 HEAD 为准。进入 WSL 后先执行 `git rev-parse HEAD` 并把提交号写入构建记录，不能从未提交工作树构建。

已实现并通过 macOS 静态检查，但尚未做 WSL 端到端构建或目标机验证：

- dump p25/p27 和内层 FIT 的固定 hash gate；
- stock ABI 保护清单与管理包覆盖 allowlist；
- 去 OpenSync、厂商 Web、固定密钥和危险分区脚本的 audited overlay；
- LAN/WAN、firewall、Dropbear、uhttpd、rpcd 默认配置；
- p29 唯一性、分区号和零标记检查；
- 只写 p25/p27、只清 p29 的专用 sysupgrade 栈；
- 为当前 6.18 首刷准备的临时 bind-mount 过渡升级器；
- SquashFS `/dev/console` 重建和最终 tar/metadata 审计；
- 构建器中的 WSL-only、ext4-only、私钥扫描、ELF NEEDED 和原厂 ABI hash gate。

尚未完成：

- 在 WSL 实际同步 QSDK manifest，并确认 workspace、patch 入口、设备 profile、LuCI feed revision 和包输出路径；
- 在 QSDK r6 Linux buildroot 中生成 LuCI 管理包和完整依赖 IPK；
- 执行完整构建器并得到 `.bin/.sha256/.audit`；
- 在 p40 实际进入 HTTP recovery，并执行过渡 helper 的 `--test` 与 `--flash`；
- LuCI、三频 Wi-Fi、PPE/PPEDS/ECM、风扇温控、持久 overlay 的真机验收。

## 4. 不可改变的写入边界

首版只允许：

| 分区 | 编号 | 动作 |
| --- | ---: | --- |
| `0:HLOS` | p25 | 写入原厂内层 FIT |
| `rootfs` | p27 | 写入新 SquashFS |
| `rootfs_data` | p29 | `-n` 时清除前 4 KiB，首启验证后重建 ext4 |

绝不写入：

```text
p20 ART
p22 LICENSE
p23/p24 WIFIFW
p26/p28 原厂备用槽
p30 rootfs_data_1
p36/p37 TLS/设备身份
p39 vendor bypass
p40 recovery chainloader
p43 ASKEYMFC/制造数据
GPT、BOOTCONFIG、bootloader/TZ/RPM
```

dump 的 p20 与当前真机 p20 已确认不同，禁止把 dump 的 ART、caldata、MAC 或制造数据打入镜像。

2026-08-18 对当前真机只读确认：

```text
0:HLOS      -> p25
rootfs      -> p27
rootfs_data -> p29
rsvd_2      -> p40
p40 magic   -> d00dfeed
```

只看到 FIT magic 不等于恢复功能可用。仓库中已测试 chainloader payload 的长度为 `758532` 字节、SHA-256 为 `2aad05c1ee2574874a4570367a090ebf9af66cc02d23db91365ed0b83ef5d702`；首次刷写前必须在真机重新核对该前缀，并实际进入 HTTP recovery、上传已验证的 6.18 镜像且成功回启。若 hash 不同，先识别当前 p40 内容，不能绕过检查。

## 5. WSL2 准备

建议 Ubuntu 24.04 WSL2。仓库、QSDK 源码、IPK、临时 rootfs 和输出都必须放在 WSL home 的 ext4 中，不能放在 `/mnt/c`。dump 可以从 `/mnt/c` 只读输入。

```sh
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib gettext git \
  libelf-dev libncurses-dev libssl-dev python3 python3-setuptools \
  python3-pyelftools rsync swig unzip zlib1g-dev file wget curl \
  device-tree-compiler u-boot-tools squashfs-tools jq openssh-client \
  util-linux e2fsprogs ca-certificates repo xxd
```

准备路径：

```sh
export SBE_REPO=$HOME/src/SBE1V1K
export SBE_DUMP=/mnt/c/Users/yangzhg/Downloads/SBE1V1K-1.1.3.1-eMMC-backup-20260808
export SBE_QSDK_SRC=$HOME/src/qsdk-12.2-r6
export SBE_WORK=$HOME/src/sbe1v1k-stockabi-work
export SBE_OUT=$HOME/src/sbe1v1k-stockabi-output

mkdir -p "$SBE_QSDK_SRC" "$SBE_WORK" "$SBE_OUT"
cd "$SBE_DUMP"
sha256sum -c SHA256SUMS
```

必须匹配的输入 hash：

```text
p25: 5717e40e7a52a3876aee223ede2004886947e0803d8f967f35f1a00548aad3e5
p27: 8488a757a29b05ef66393b25504ddc3e9dcc82041c46e217949300a68ee4818c
FIT: 852030dc9e5d0b9e56845efd3a8decbde6dd93a7d779c84230331e244bfbb1bf
```

hash 不符时停止，不能修改脚本中的期望值绕过。

## 6. QSDK 管理包输入

使用官方 manifest：

```text
AU_LINUX_QSDK_NHSS.QSDK.12.2.R6_TARGET_ALL.12.02.06.2230.023.xml
```

管理包必须来自同一次 QSDK r6/OpenWrt 19.07 构建，架构必须为：

```text
aarch64_cortex-a73_neon-vfpv4
```

精确包清单由以下文件维护：

```text
configs/sbe1v1k-stockabi-packages.txt
```

每个 IPK 的完整 `Depends` 闭包都必须同时满足两点：包名加入 `configs/sbe1v1k-stockabi-packages.txt`，唯一对应 IPK 放进同一 `--ipk-dir`。构建器不会仅因 IPK 位于目录中就递归选择它。至少覆盖 LuCI、Lua、rpcd、uhttpd、Dropbear、dnsmasq，以及与 QSDK qca-wifi 兼容的 `libiwinfo`、`libiwinfo-lua`、`rpcd-mod-iwinfo` 和 `rpcd-mod-file`。不得加入：

```text
kernel
kmod-*
libc/musl
busybox/procd/ubus/uci/netifd/fstools
qca-*/hostapd*/wpa-supplicant*
libnl-3/libnl-genl-3/libssl/libcrypto
```

这些底层组件继续使用 p27 的原厂 ABI 版本。不要使用 `--force-depends` 或 `--force-overwrite`。

当前清单已列入已知的 iwinfo/rpcd/LuCI 模块入口，但真实 QSDK IPK 的 versioned `Depends` 闭包仍必须在 WSL 生成包后逐项核对；任何缺包或版本条件未核实都属于构建阻断，不能靠 candidate 警告继续上机。

v1 只配置和保证 IPv4：没有 `wan6`、LAN `ip6assign` 或 `odhcpd`。这不表示内核禁用了 IPv6；IPv6 管理面留到同锁依赖和配置完成后验收。

当前构建器只产出 candidate：移除 `luci-app-opkg`、禁用在线 feed，并只登记实际嵌入的管理包。即使提供 `--base-opkg-root`，它也仅作为只读的 payload 存在性证据，不能把产物升级成 release。运行时包管理要等逐包 version/architecture/type/hash reconciliation lock 和 ABI 岛 hold/feed 排除机制实现后再启用。

## 7. 构建命令

先准备一把只包含公钥的管理员 key；私钥不能进入仓库、rootfs 或构建目录。源码同步与 `manifest.lock.xml` 生成按详细设计第 7 节执行，文件固定放在 `$SBE_QSDK_SRC/manifest.lock.xml`。在 QSDK 树中完成管理包构建后，按真实目录设置：

```sh
export SBE_QSDK_BUILD=/absolute/path/to/verified-openwrt-buildroot
export SBE_QSDK_IPKS=/absolute/path/to/curated-qsdk-r6-ipks
export SBE_QSDK_ROOT=/absolute/path/to/verified-management-root
test -f "$SBE_QSDK_SRC/manifest.lock.xml"
test -d "$SBE_QSDK_IPKS"
test -f "$SBE_QSDK_ROOT/usr/lib/opkg/status"
```

全新 clone 没有 host `fwtool`。先从本仓库的 OpenWrt 树构建它，并记录所用二进制的 hash：

```sh
cd "$SBE_REPO"
make defconfig
make tools/firmware-utils/compile V=s

if test -x "$SBE_REPO/staging_dir/host/bin/fwtool"; then
  export SBE_FWTOOL=$SBE_REPO/staging_dir/host/bin/fwtool
elif test -x "$SBE_REPO/staging_dir/hostpkg/bin/fwtool"; then
  export SBE_FWTOOL=$SBE_REPO/staging_dir/hostpkg/bin/fwtool
else
  echo 'fwtool build failed' >&2
  exit 1
fi
sha256sum "$SBE_FWTOOL"
```

允许进入首次真机测试流程的 candidate 必须使用同一次 QSDK 构建的 `management-root` 对依赖做存在性核对，并让构建器在任何未满足依赖上失败：

```sh
cd "$SBE_REPO"

scripts/build-sbe1v1k-stockabi-sysupgrade.sh \
  --p25 "$SBE_DUMP/mmcblk0p25.img" \
  --p27 "$SBE_DUMP/mmcblk0p27.img" \
  --ipk-dir "$SBE_QSDK_IPKS" \
  --qsdk-manifest "$SBE_QSDK_SRC/manifest.lock.xml" \
  --admin-public-key "$HOME/.ssh/id_ed25519.pub" \
  --openwrt-tree "$SBE_REPO" \
  --fwtool "$SBE_FWTOOL" \
  --base-opkg-root "$SBE_QSDK_ROOT" \
  --work-dir "$SBE_WORK" \
  --output "$SBE_OUT/sbe1v1k-qsdk12-stockabi-sysupgrade.bin" \
  --source-date-epoch 1767633503
```

没有 `management-root` 时可做一次离线流程检查，但必须同时替换下面两个参数，不能占用 canonical candidate 文件名：

```sh
  --allow-incomplete-opkg-db \
  --output "$SBE_OUT/sbe1v1k-qsdk12-stockabi-offline-only.bin"
```

也就是从完整命令删除 `--base-opkg-root ...`，并把原来的 canonical `--output ...` 一并替换；不能保留两个 `--output`。这种输出只用于离线检查构建流程，其 metadata 会被标记为 `candidate-unreconciled-do-not-flash`，内置 writer 和首次过渡 helper 都会拒绝，即使生成了 `.bin` 也不能刷入。构建器拒绝覆盖现有输出及 sidecar，因此两种模式也不能复用同名文件。只有带 `--base-opkg-root` 的构建通过、`unresolved-package-dependencies.txt` 为空，而且 versioned dependency 已在构建记录中逐项核对后，candidate 才能进入真机测试。两种模式都不是 release，也都不能启用运行时 feed 或 `luci-app-opkg`。

成功时应得到以下 candidate artifacts：

```text
sbe1v1k-qsdk12-stockabi-sysupgrade.bin
sbe1v1k-qsdk12-stockabi-sysupgrade.bin.sha256
sbe1v1k-qsdk12-stockabi-sysupgrade.bin.audit
```

只要构建器报告 ABI 文件变化、私钥、未知设备节点、包覆盖冲突、缺依赖、错误分区脚本或 metadata 不一致，就停止处理错误，不能降低 gate。

## 8. 离线验收

```sh
cd "$SBE_OUT"
sha256sum -c sbe1v1k-qsdk12-stockabi-sysupgrade.bin.sha256
tar tf sbe1v1k-qsdk12-stockabi-sysupgrade.bin
```

tar 只能有：

```text
sysupgrade-askey_sbe1v1k/
sysupgrade-askey_sbe1v1k/CONTROL
sysupgrade-askey_sbe1v1k/kernel
sysupgrade-askey_sbe1v1k/root
```

还需解包 root 并确认：

- 原厂 `/lib/modules/5.4.213` hash 与 audit 基线完全一致；
- `/sbin/sysupgrade`、`platform.sh`、`emmc.sh`、`do_stage2` 是 audited 版本；
- `/dev/console` 是唯一设备节点，字符设备 5:1、0600；
- 没有固定 Dropbear host key、TLS 私钥、OpenSync client key；
- `/usr/opensync`、旧 `/www`、旧 LuCI Thread controller 不存在；
- `root` 密码锁定，只有指定公钥可首登；
- metadata 支持 `askey,sbe1v1k`、`qcom,ipq9574-ap-al02-c4` 和 `askey,rtq7300t-rev0`。

fwtool metadata 不是密码学签名。首刷必须使用第 9 节电脑端可信的整镜像 SHA-256；以后从该基线升级也必须先在电脑和路由器两端核对随构建记录发布的 `.sha256`，不能只依赖 `sysupgrade -T`。

任何升级若在 ubus 提交或 RAMFS 准备阶段失败，必须先完整重启再重试；不要手工删除或复用 `/tmp/root`。成品 writer 会要求 `/tmp` 可用空间至少为“镜像三倍”和 256 MiB 中的较大值，并拒绝非空 RAMFS staging root，防止空间不足或沿用上一次失败留下的旧脚本。

## 9. 首次刷入

首次从当前 6.18 跨到 QSDK 5.4 必须使用 `-n`，不能保留现有配置。v1 新系统自己的 sysupgrade 也强制 `-n`，不支持 `-F` 或配置保存。

当前 6.18 的 `platform_check_image` 和通用 eMMC writer 不满足本项目的唯一 label、固定 payload hash、写后回读和写入边界要求。因此第一次不能直接运行当前系统的普通 `sysupgrade -n`。电脑端先保留并校验已经验证的 6.18 恢复镜像，实际进入 p40 HTTP recovery、上传该镜像并成功回启，再从已提交仓库生成过渡包：

p40 uploader 会清空 `rootfs_data`。恢复后的 6.18 因此不再保留现在的密码、公钥或 Dropbear host key。保持 UART 连接，在串口控制台为这一次过渡设置临时 root 密码、重启 Dropbear，并记录每把新 host key 的指纹：

```sh
passwd
/etc/init.d/dropbear restart
for key in /etc/dropbear/dropbear_*_host_key; do
  test -f "$key" && dropbearkey -y -f "$key"
done
```

电脑端删除旧记录，扫描直连设备的新 key，并用 `ssh-keygen -lf` 的结果逐项比对 UART 上的指纹；完全匹配后才能写入 `known_hosts`：

```sh
ssh-keygen -R 192.168.1.1
ssh-keyscan 192.168.1.1 > /tmp/sbe1v1k-recovered-6.18.known_hosts
ssh-keygen -lf /tmp/sbe1v1k-recovered-6.18.known_hosts
# 仅在输出与 UART 指纹匹配后执行：
cat /tmp/sbe1v1k-recovered-6.18.known_hosts >> "$HOME/.ssh/known_hosts"
```

不要关闭 `StrictHostKeyChecking`，也不要在未比对指纹时接受 SSH 提示。确认新的 SSH 登录可用后，再生成过渡包：

```sh
export SBE_IMAGE=sbe1v1k-qsdk12-stockabi-sysupgrade.bin
export SBE_TRANSITION=sbe1v1k-stockabi-transition

cd "$SBE_OUT"
test -f "$SBE_IMAGE"
test ! -e "$SBE_TRANSITION"
install -d -m 0700 "$SBE_TRANSITION"
install -m 0755 \
  "$SBE_REPO/configs/sbe1v1k-stockabi-overlay/lib/upgrade/platform.sh" \
  "$SBE_TRANSITION/platform.sh"
install -m 0755 \
  "$SBE_REPO/configs/sbe1v1k-stockabi-overlay/lib/upgrade/emmc.sh" \
  "$SBE_TRANSITION/emmc.sh"
install -m 0755 \
  "$SBE_REPO/configs/sbe1v1k-stockabi-overlay/lib/upgrade/do_stage2" \
  "$SBE_TRANSITION/do_stage2"
(cd "$SBE_TRANSITION" && \
  sha256sum platform.sh emmc.sh do_stage2 > SHA256SUMS)
install -m 0755 \
  "$SBE_REPO/scripts/sbe1v1k-stockabi-firstflash-transition.sh" .

sha256sum \
  "$SBE_IMAGE" \
  sbe1v1k-stockabi-firstflash-transition.sh \
  "$SBE_TRANSITION/platform.sh" \
  "$SBE_TRANSITION/emmc.sh" \
  "$SBE_TRANSITION/do_stage2" \
  "$SBE_TRANSITION/SHA256SUMS" \
  > FIRSTFLASH-SHA256SUMS
sha256sum -c FIRSTFLASH-SHA256SUMS
```

记录仓库提交号和 `FIRSTFLASH-SHA256SUMS`。外层清单用于确认 helper 与 bundle 来自受信任提交；bundle 内的 `SHA256SUMS` 还会由路由器端 helper 再检查一次。当前 6.18 Dropbear 没有 SFTP server，Ubuntu 24.04 的 OpenSSH 客户端必须加 `-O` 使用 legacy SCP。然后传输并在路由器端复核：

```sh
scp -O \
  "$SBE_IMAGE" \
  sbe1v1k-stockabi-firstflash-transition.sh \
  FIRSTFLASH-SHA256SUMS \
  root@192.168.1.1:/tmp/
scp -O -r "$SBE_TRANSITION" root@192.168.1.1:/tmp/

ssh root@192.168.1.1
cd /tmp
SBE_IMAGE=sbe1v1k-qsdk12-stockabi-sysupgrade.bin
sha256sum -c FIRSTFLASH-SHA256SUMS
df -h /tmp

test "$(head -c 758532 /dev/mmcblk0p40 | sha256sum | awk '{print $1}')" = \
  2aad05c1ee2574874a4570367a090ebf9af66cc02d23db91365ed0b83ef5d702

# 从电脑端 FIRSTFLASH-SHA256SUMS 第一行复制，不能在路由器上临时生成期望值。
IMAGE_SHA='<64 位可信镜像 SHA-256>'
./sbe1v1k-stockabi-firstflash-transition.sh \
  --test "/tmp/$SBE_IMAGE" "$IMAGE_SHA"
./sbe1v1k-stockabi-firstflash-transition.sh \
  --flash "/tmp/$SBE_IMAGE" "$IMAGE_SHA"
```

执行 `--flash` 前，`/tmp` 可用空间应至少为“镜像大小的三倍”和 256 MiB 两者中的较大值，`--test` 必须明确报告未写分区。若测试被中断且留下 bind mount，可执行 `./sbe1v1k-stockabi-firstflash-transition.sh --cleanup`。第一次不要通过 LuCI 上传，也不要使用 `-F`。执行前再次确认设备接在 LAN，电脑有手动设置 192.168.1.x 地址的办法。

当前唯一已经记录的主动 recovery 入口，是通过 1.8 V UART 进入 chainloader 命令行执行 `http_recovery`，步骤见 [SBE1V1K-UBOOT.md](SBE1V1K-UBOOT.md)。因此 UART 对日常运行不是必需的，但对完成本次刷写前的 recovery 硬门是必需的；不能用“p40 有 FIT magic”代替上传恢复镜像并成功回启的实测。

## 10. 首次启动与验收

镜像内 root 密码为锁定状态，不继承当前设备密码；p29 再次初始化后也会生成另一组 Dropbear host key。成品中的 `ssh-hostkey-fingerprint` 服务会在 Dropbear 启动后把新指纹打印到 UART 控制台。电脑端再次删除刚才 6.18 的记录、扫描并逐项比对 UART 输出，匹配后才写入 `known_hosts`：

```sh
ssh-keygen -R 192.168.1.1
ssh-keyscan 192.168.1.1 > /tmp/sbe1v1k-qsdk12.known_hosts
ssh-keygen -lf /tmp/sbe1v1k-qsdk12.known_hosts
# 仅在输出与 UART 上的 SBE1V1K SSH host key 指纹匹配后执行：
cat /tmp/sbe1v1k-qsdk12.known_hosts >> "$HOME/.ssh/known_hosts"
```

然后使用构建时公钥所对应的 SSH 私钥从 LAN 登录：

```sh
ssh root@192.168.1.1
passwd
```

设置密码后再访问：

```text
http://192.168.1.1/
```

按顺序保存日志并验收：

```sh
uname -a
cat /etc/openwrt_release
mount
df -h
ip -br link
ip -br addr
lsmod | grep -Ei 'qca|ppe|ecm|nss|cnss|wifi'
dmesg | grep -Ei 'firmware|bdf|cal|cnss|qca|ppe|ppeds|ecm|edma|error|fail'
```

必须通过：

1. `/overlay` 来自唯一 p29 ext4；修改 UCI、密码后冷重启仍保留。
2. eth0 为 WAN，eth1/eth2/eth3 为 LAN bridge，WAN 不能访问 LuCI/SSH。
3. WIFIFW 从真机 p23/p24 加载，三张 QCN9224 使用本机 p20 校准数据。
4. 三频无线能创建、关联、传输；BDF revision/filter 与原厂选择一致。
5. SSDK、NSS-DP、PPE、PPE-VP/PPE-DS、ECM 和 PPEDS 无 unknown symbol/firmware error。
6. 有线及无线 NAT 压测时 PPE/ECM counter 增长，记录吞吐、CPU 和 IRQ。
7. 风扇、thermal、LED 工作，无过温或 radio chainmask 异常。
8. OpenSync、Open vSwitch、CUJO、SamKnows、Ookla、厂商 Web/升级/遥测不启动。
9. 新系统中的 `sysupgrade -T` 无 qseecom、binding、BOOTCONFIG 或分区写入副作用。

## 11. 停止条件与恢复

出现以下任一情况立即停止继续配置或压测：

- p25/p27/p29/p40 label 或编号不符；
- p40 不再是可启动的 recovery chainloader；
- boot 后没有 LAN、SSH 和 LuCI；
- WIFIFW/BDF/caldata 加载失败；
- 模块出现 unknown symbol、vermagic 或崩溃；
- 风扇未运行或温度失控；
- PPE/ECM 建流造成丢包、重启或内存错误。

候选恢复路径是当前 p40 HTTP chainloader；只有刷写前实际进入、上传已验证的 6.18 SBE1V1K sysupgrade并成功回启后，才能批准它作为本次恢复手段。发生故障时进入 `http_recovery`，重新上传同一份已验证镜像。不要把 p26/p28 描述成已经验证的自动回滚槽，也不要在恢复时写 ART、WIFIFW、TLS 或 GPT。

## 12. WSL 接手时的第一条消息

在 WSL 打开仓库后，可直接继续：

```text
继续 SBE1V1K QSDK 12.2 stock-ABI + LuCI 交接任务。
先阅读 SBE1V1K-QSDK-12.2-STOCKABI-HANDOFF.md 和
SBE1V1K-QSDK-12.2-CLEAN-OPENWRT.md，确认分支为
sbe1v1k-qsdk12-stockabi，记录 git HEAD，核对 QSDK manifest、IPK 依赖闭包和
dump hash；然后运行构建器。不要重编或替换原厂
kernel/kmod，不写 p20/p22/p23/p24/p26/p28/p30/p36/p37/p39/p40/p43。
构建成功后先做离线审计，再按第 9 节生成并校验首次过渡包；不能直接调用
当前 6.18 的普通 sysupgrade。过渡 helper 的 --test 通过后才能执行 --flash，
并按交接文档完成真机验收。
```
