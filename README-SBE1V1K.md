# SBE1V1K OpenWrt 源码分支

本仓库的 `main` 本身就是完整 OpenWrt 源码树，基于 OpenWrt 官方
`main` 提交 `ee6ef8d27e`，并在其上维护 SBE1V1K 设备支持。克隆后不需要运行
源码生成脚本，也不需要再克隆另一个 OpenWrt 仓库。

## 源码来源与提交边界

- 设备定义来源于 Andrew LaMarche 的
  [SBE1V1K 设备提交](https://github.com/andrewjlamarche/openwrt/commit/525e6238f484876a0551323f9be4599e2945bc84)。
- 每 radio MAC 修复来源于 OpenWrt PR #23786，对应上游提交
  `e811bcdf07a8db43d0b6a33171afe4468a34ba02`。
- 多候选 PCI 路径支持已经作为 OpenWrt 官方提交 `2c64257627` 合入，仓库不再
  携带早期本地版本。
- QCN9274 BDF 固定自 firmware_qca-wireless PR #123 的提交
  `74b0985b1d836eb4df868c031f8b8eecbd607772`，对应 2026 年 2 月厂商
  固件中的新版三频校准数据。
- CV upload 和空 regulatory event 两个 ath12k 修复保持为独立提交，方便单独
  测试、回退和后续上游化。

完整外部输入和校验值记录在 `sources.lock` 中。

## 固件配置

仓库提供三套配置：

| 配置 | 适用场景 | 预装内容 |
| --- | --- | --- |
| `configs/sbe1v1k-recovery.config` | 驱动调试、救援 | SSH/UART 和硬件必需包，不含 LuCI |
| `configs/sbe1v1k.config` | 日常使用 | HTTPS LuCI、简体中文 |
| `configs/sbe1v1k-full.config` | 功能完整的日常系统 | LuCI、DDNS、PassWall、完整 curl/Wget、诊断工具、WireGuard |

`full` 中预装了 HAProxy 和 PassWall，但默认不会启动代理服务或开放 WAN
端口。需要使用时再到 LuCI 中配置并启用。

SBE1V1K 尚未进入 OpenWrt 官方构建系统，因此官方服务器没有
`qualcommbe/ipq95xx` 的目标软件包仓库。三套配置均省略这个无效地址，也不会把
用于源码构建的 PassWall feeds 误写成 `downloads.openwrt.org` 二进制仓库。

`full` 镜像按照 PassWall 项目当前推荐的方式，预置
`openwrt-passwall-build` 的独立签名公钥以及 `passwall_luci`、
`passwall_packages` 两个 snapshot APK 仓库。PassWall 源码仍由锁定的 Git feeds
参与固件构建，APK 仓库仅供设备后续安装和更新相关软件包。官方 snapshot 和
PassWall snapshot 都是滚动仓库；可以使用 `apk update` 和有选择的 `apk add`，
但不要把无审查的全量 `apk upgrade` 当作固件升级方式。基础系统升级应使用由同一
源码提交重新构建的 sysupgrade 镜像。

## Ubuntu / WSL2 原生编译

先安装依赖：

```bash
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses-dev libssl-dev python3-setuptools rsync swig \
  unzip zlib1g-dev file wget bc bzip2 libelf-dev liblzma-dev \
  python3-dev time xxd zstd
```

推荐使用原生构建入口。它与 Docker 构建使用相同的 feeds 更新、配置加载、
下载和 `world` 编译流程，并在完成后输出产物大小与 SHA256：

```bash
./build-sbe1v1k-native.sh recovery
./build-sbe1v1k-native.sh minimal   # 不带参数时的默认值
./build-sbe1v1k-native.sh full
```

默认使用全部 CPU 线程；可以限制并行度、启用详细日志或在构建前清理：

```bash
BUILD_JOBS=8 ./build-sbe1v1k-native.sh full
V=s BUILD_JOBS=1 ./build-sbe1v1k-native.sh full
CLEAN=1 ./build-sbe1v1k-native.sh full
```

构建日志位于 `build/native/<配置名>/build.log`，固件仍输出到
`bin/targets/qualcommbe/ipq95xx/`。脚本会显示当前 Git `HEAD`；工作区未提交的
修改不会产生新的 Git ID，因此发布或刷机前应先提交需要验证的改动。

也可以手动执行以下命令编译 `minimal` 镜像：

```bash
git clone https://github.com/yangzhg/SBE1V1K.git
cd SBE1V1K

# WSL 用户应避免继承包含 Windows “Program Files”的 PATH，
# 否则 find -execdir 会在 package/install 阶段拒绝执行。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

./scripts/feeds update -a
./scripts/feeds install -a
cp configs/sbe1v1k.config .config
make defconfig
make download -j"$(nproc)"
make -j"$(nproc)" world
```

编译其他版本时，把 `cp` 命令中的配置文件换成上表对应的文件。所有 feeds
都锁定到了 `feeds.conf.default` 和 `sources.lock` 中记录的版本。

若并行构建失败：

```bash
make -j1 V=s
```

## Docker 编译（macOS / WSL2 / Linux）

Docker 是可选的。在 Ubuntu 或 WSL2 中可以按上一节直接编译。本节脚本只要求
Docker CLI 能够连接一个运行 Linux 容器的 Docker Engine。

确认 `docker info` 可以正常连接后运行：

```bash
docker info
./build-sbe1v1k.sh recovery
./build-sbe1v1k.sh minimal   # 不带参数时的默认值
./build-sbe1v1k.sh full
```

中间文件保存在 Docker volume，不会写入宿主源码树的 `build_dir`、
`staging_dir` 或 `bin`。固件和构建日志输出到 `build/<配置名>/`。

Apple Silicon 上的 `recovery` 和 `minimal` 使用 arm64 容器。`full` 包含需要
x86_64 构建宿主的 Go 软件包，因此使用 amd64 容器，默认单线程编译。可以用
`BUILD_JOBS=4 ./build-sbe1v1k.sh full` 调整并行度。这里的 amd64 只指编译容器，
生成的路由器固件仍然是 AArch64。

通用 Docker 构建器的参数说明见 `docker/openwrt-builder/README.md`。

## 构建产物

原生编译的产物位于 `bin/targets/qualcommbe/ipq95xx/`，Docker 构建的产物位于
`build/<配置名>/`。主要固件文件为：

```text
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-initramfs-uImage.itb
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-factory.bin
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
```

详细支持状态、拆机与刷机步骤见 `SBE1V1K-OpenWrt-Guide.md`。可选的 HTTP U-Boot chainloader 用法见 `SBE1V1K-UBOOT.md`。原厂固件免拆机 root 教程见 `SBE1V1K-ROOT.md`（英文版 `SBE1V1K-ROOT.en.md`）。
