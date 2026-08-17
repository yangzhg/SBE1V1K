#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

umask 077
export LC_ALL=C

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"

readonly expected_p25_sha256=5717e40e7a52a3876aee223ede2004886947e0803d8f967f35f1a00548aad3e5
readonly expected_p27_sha256=8488a757a29b05ef66393b25504ddc3e9dcc82041c46e217949300a68ee4818c
readonly expected_fit_sha256=852030dc9e5d0b9e56845efd3a8decbde6dd93a7d779c84230331e244bfbb1bf
readonly expected_openwrt_revision=e71632be5197770b6339ea9f88b5e7b65e87cf53
readonly fit_offset=$((0x3000))
readonly kernel_limit=$((7 * 1024 * 1024 - 4096))
readonly rootfs_limit=$((122 * 1024 * 1024 - 65536))
readonly board=askey_sbe1v1k
readonly board_dir=sysupgrade-askey_sbe1v1k

p25=
p27=
ipk_dir=
package_list="${repo_root}/configs/sbe1v1k-stockabi-packages.txt"
disabled_services="${repo_root}/configs/sbe1v1k-stockabi-disabled-services.txt"
enabled_services="${repo_root}/configs/sbe1v1k-stockabi-enabled-services.txt"
required_paths="${repo_root}/configs/sbe1v1k-stockabi-required-paths.txt"
remove_paths="${repo_root}/configs/sbe1v1k-stockabi-remove-paths.txt"
protected_paths="${repo_root}/configs/sbe1v1k-stockabi-protected-paths.txt"
allowed_overwrites="${repo_root}/configs/sbe1v1k-stockabi-allowed-overwrites.txt"
audited_overlay="${repo_root}/configs/sbe1v1k-stockabi-overlay"
openwrt_tree=
fwtool=
qsdk_manifest=
admin_public_key=
base_opkg_root=
overlay_dir=
work_dir=
output=
source_date_epoch="${SOURCE_DATE_EPOCH:-}"
allow_incomplete_opkg_db=0
keep_work=0
run_dir=

usage() {
	cat <<'EOF'
Usage:
  scripts/build-sbe1v1k-stockabi-sysupgrade.sh \
    --p25 /path/to/mmcblk0p25.img \
    --p27 /path/to/mmcblk0p27.img \
    --ipk-dir /path/to/curated-qsdk-r6-ipks \
    --qsdk-manifest /path/to/manifest.lock.xml \
    --admin-public-key /path/to/id_ed25519.pub \
    --openwrt-tree /path/to/tested-openwrt-tree \
    --work-dir "$HOME/src/sbe1v1k-stockabi-work" \
    --output "$HOME/src/sbe1v1k-stockabi-output/sysupgrade.bin" \
    [--base-opkg-root /path/to/complete/qsdk-r6/root]

Required inputs:
  --p25 FILE               Exact stock p25 HLOS dump.
  --p27 FILE               Exact matching stock p27 SquashFS dump.
  --ipk-dir DIR            Directory containing the curated management IPKs.
  --qsdk-manifest FILE     Locked QSDK r6 repo manifest used for those IPKs.
  --admin-public-key FILE  One OpenSSH public key for initial LAN-only access.
  --openwrt-tree DIR       Tested OpenWrt tree providing sysupgrade-tar.sh.
  --work-dir DIR           Disposable build area under WSL2's ext4 $HOME.
  --output FILE            New output under WSL2's ext4 $HOME.

Safety and reproducibility options:
  --fwtool FILE            Host fwtool; otherwise locate it in openwrt-tree.
	--base-opkg-root DIR     QSDK r6 root containing status and info DB for
	                         read-only reconciliation evidence. It is never copied
	                         into the candidate image as an authoritative database.
  --allow-incomplete-opkg-db
	                         Permit a candidate without base-package reconciliation
	                         evidence for offline build inspection only. Such an
	                         image is not eligible for first-flash or device testing.
  --overlay-dir DIR        Reserved and rejected. Add reviewed changes to the
                           repository-owned audited overlay instead.
                           Package and safety/service/path policies are fixed
                           to the repository-owned audited files.
  --source-date-epoch N    Reproducible tar timestamp (default: p27 mtime).
  --keep-work              Retain the private temporary build tree on success.
  -h, --help               Show this text.

The script never reads ART, WIFIFW, TLS, ASKEYMFC, GPT or another partition.
It never downloads a package and never invokes opkg with --force-depends.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

log() {
	printf '==> %s\n' "$*"
}

need_arg() {
	[ "$#" -ge 2 ] && [ -n "$2" ] || die "option $1 requires an argument"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--p25 | --p27 | --ipk-dir | --package-list | --disabled-services | \
	--enabled-services | --required-paths | --remove-paths | \
	--protected-paths | --allowed-overwrites | --openwrt-tree | \
	--fwtool | --qsdk-manifest | --admin-public-key | --base-opkg-root | --overlay-dir | \
	--work-dir | --output | --source-date-epoch)
		need_arg "$@"
		option="${1#--}"
		option="${option//-/_}"
		printf -v "$option" '%s' "$2"
		shift 2
		;;
	--allow-incomplete-opkg-db)
		allow_incomplete_opkg_db=1
		shift
		;;
	--keep-work)
		keep_work=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

for name in p25 p27 ipk_dir qsdk_manifest admin_public_key openwrt_tree work_dir output; do
	[ -n "${!name}" ] || die "--${name//_/-} is required"
done

for tool in ar awk basename chmod cmp cp cut dd dirname dumpimage find findmnt \
	grep head install jq ln mkdir mktemp mksquashfs mv nproc od readelf readlink \
	realpath rm rsync sed sh sha256sum sort ssh-keygen stat strings tar tr \
	truncate unsquashfs wc xargs; do
	command -v "$tool" >/dev/null 2>&1 || die "required host tool is missing: $tool"
done

grep -Eqi 'microsoft|wsl2' /proc/sys/kernel/osrelease 2>/dev/null || \
	die 'this builder must run inside WSL2'
[ -n "${WSL_DISTRO_NAME:-}" ] || die 'WSL_DISTRO_NAME is unset; refusing a non-WSL build'
unsquashfs_help="$(unsquashfs -help-option exclude-file 2>&1 || true)"
printf '%s\n' "$unsquashfs_help" | grep -Fq -- '-exclude-file' || \
	die 'unsquashfs lacks the required -exclude-file support'
mksquashfs_help="$(mksquashfs -help 2>&1 || true)"
printf '%s\n' "$mksquashfs_help" | grep -Eq -- '(^|[[:space:]])-p([[:space:]]|,)' || \
	die 'mksquashfs lacks pseudo-file (-p) support'
unset unsquashfs_help mksquashfs_help

resolve_file() {
	local value=$1
	[ -f "$value" ] || die "not a regular file: $value"
	realpath -e -- "$value"
}

resolve_dir() {
	local value=$1
	[ -d "$value" ] || die "not a directory: $value"
	realpath -e -- "$value"
}

p25="$(resolve_file "$p25")"
p27="$(resolve_file "$p27")"
[ "$p25" != "$p27" ] || die 'p25 and p27 resolve to the same file'
ipk_dir="$(resolve_dir "$ipk_dir")"
qsdk_manifest="$(resolve_file "$qsdk_manifest")"
admin_public_key="$(resolve_file "$admin_public_key")"
openwrt_tree="$(resolve_dir "$openwrt_tree")"
package_list="$(resolve_file "$package_list")"
disabled_services="$(resolve_file "$disabled_services")"
enabled_services="$(resolve_file "$enabled_services")"
required_paths="$(resolve_file "$required_paths")"
remove_paths="$(resolve_file "$remove_paths")"
protected_paths="$(resolve_file "$protected_paths")"
allowed_overwrites="$(resolve_file "$allowed_overwrites")"
audited_overlay="$(resolve_dir "$audited_overlay")"
[ -z "$base_opkg_root" ] || base_opkg_root="$(resolve_dir "$base_opkg_root")"
if [ -n "$overlay_dir" ]; then
	overlay_dir="$(resolve_dir "$overlay_dir")"
	die 'additional overlays are disabled; update the repository-owned audited overlay'
fi
[ "$disabled_services" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-disabled-services.txt")" ] || \
	die 'disabled-services policy must be the repository-owned audited file'
[ "$package_list" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-packages.txt")" ] || \
	die 'package-list policy must be the repository-owned audited file'
[ "$enabled_services" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-enabled-services.txt")" ] || \
	die 'enabled-services policy must be the repository-owned audited file'
[ "$required_paths" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-required-paths.txt")" ] || \
	die 'required-paths policy must be the repository-owned audited file'
[ "$remove_paths" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-remove-paths.txt")" ] || \
	die 'remove-paths policy must be the repository-owned audited file'
[ "$protected_paths" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-protected-paths.txt")" ] || \
	die 'protected-paths policy must be the repository-owned audited file'
[ "$allowed_overwrites" = "$(realpath -e -- "${repo_root}/configs/sbe1v1k-stockabi-allowed-overwrites.txt")" ] || \
	die 'allowed-overwrites policy must be the repository-owned audited file'
for required_overlay_file in \
	etc/config/network etc/config/dropbear etc/config/uhttpd etc/config/rpcd \
	etc/config/firewall etc/config/dhcp etc/passwd etc/group etc/shadow \
	etc/firewall.user etc/init.d/firewall etc/init.d/ssh-hostkey-fingerprint \
	etc/udhcpc.user etc/crontabs/root \
	etc/profile etc/sysctl.conf etc/ppp/ip-up etc/ppp/ip-down \
	etc/sysupgrade.conf sbin/sysupgrade lib/upgrade/do_stage2 \
	lib/upgrade/platform.sh lib/upgrade/emmc.sh; do
	[ -f "${audited_overlay}/${required_overlay_file}" ] || \
		die "audited overlay is incomplete: $required_overlay_file"
done
for preinit_file in 01_default_configs 42_mount_askey_partition 80_mount_root; do
	[ -f "${audited_overlay}/lib/preinit/${preinit_file}" ] || \
		die "audited overlay must replace lib/preinit/${preinit_file}"
done
if grep -Eq 'boot_hook_add|find_mmc_part|(^|[[:space:]])(mount|mkfs(\.[a-z0-9]+)?|dd)([[:space:]]|$)' \
	"${audited_overlay}/lib/preinit/01_default_configs" \
	"${audited_overlay}/lib/preinit/42_mount_askey_partition"; then
	die '01_default_configs and 42_mount_askey_partition must be inert replacement stubs'
fi
grep -Eq '(^|[[:space:]])mount_root([[:space:]]|$)' \
	"${audited_overlay}/lib/preinit/80_mount_root" || \
	die 'replacement 80_mount_root does not invoke standard mount_root'
grep -Eq 'boot_hook_add[[:space:]]+preinit_main[[:space:]]+do_mount_root' \
	"${audited_overlay}/lib/preinit/80_mount_root" || \
	die 'replacement 80_mount_root lacks the standard preinit hook'
for safety_token in \
	'find_mmc_part rootfs_data' 'PARTNAME=' '/partition' '"$partnum" = 29' \
	'/dev/mmcblk0p29' '/sys/class/block/mmcblk0p29/size' \
	'/usr/sbin/blkid' '/usr/sbin/e2fsck -p' '/usr/sbin/mkfs.ext4 -F' \
	'/overlay' 'count" -eq 1' '/tmp/rootfs_data.zero-prefix'; do
	grep -Fq "$safety_token" "${audited_overlay}/lib/preinit/80_mount_root" || \
		die "replacement 80_mount_root lacks safety check: $safety_token"
done
if grep -Eq 'rootfs_data_1|verify_rsvd|mmcblk0p(30|39)' \
	"${audited_overlay}/lib/preinit/80_mount_root"; then
	die 'replacement 80_mount_root still contains vendor partition logic'
fi
for module_target in nf-nathelper-extra ipt-nathelper-rtsp; do
	grep -Fq "/tmp/etc/modules.d/${module_target}" \
		"${audited_overlay}/lib/preinit/01_default_configs" || \
		die "01_default_configs does not create ${module_target}"
done

expected_network="${audited_overlay}/etc/config/network"
for expected_line in \
	"config interface 'lan'" \
	"option type 'bridge'" \
	"option ifname 'eth1 eth2 eth3'" \
		"option ipaddr '192.168.1.1'" \
		"config interface 'wan'" \
		"option ifname 'eth0'" \
		"option proto 'dhcp'"; do
	grep -Fq "$expected_line" "$expected_network" || \
		die "audited network config lacks: $expected_line"
done
grep -Eq "option[[:space:]]+ifname[[:space:]]+'[^']*(eth4|eth5)" "$expected_network" && \
	die 'audited network config references unsupported eth4/eth5 ports'
grep -Eq "config[[:space:]]+interface[[:space:]]+'wan6'|ip6assign|dhcpv6" \
	"$expected_network" && die 'audited v1 network config must remain IPv4-only'
grep -Eq "wan6|family[[:space:]]+'ipv6'|Allow-DHCPv6|Allow-ICMPv6" \
	"${audited_overlay}/etc/config/firewall" && \
	die 'audited v1 firewall config must remain IPv4-only'
grep -Eq "list[[:space:]]+listen_http[[:space:]]+'192\\.168\\.1\\.1:80'" \
	"${audited_overlay}/etc/config/uhttpd" || \
	die 'audited uhttpd config is not bound to the LAN address'
if grep -Eq 'listen_https|0\.0\.0\.0|\[::\]' "${audited_overlay}/etc/config/uhttpd"; then
	die 'audited uhttpd config exposes an unaudited listener'
fi
grep -Eq "option[[:space:]]+Interface[[:space:]]+'lan'" \
	"${audited_overlay}/etc/config/dropbear" || die 'Dropbear is not LAN-bound'
for auth_option in PasswordAuth RootPasswordAuth; do
	grep -Eq "option[[:space:]]+${auth_option}[[:space:]]+'off'" \
		"${audited_overlay}/etc/config/dropbear" || \
		die "Dropbear ${auth_option} is not disabled"
done
grep -Fq '/usr/bin/dropbearkey -y -f "$key"' \
	"${audited_overlay}/etc/init.d/ssh-hostkey-fingerprint" || \
	die 'SSH host-key fingerprint service does not use the public-only dropbearkey mode'
grep -Fq '>/dev/console' \
	"${audited_overlay}/etc/init.d/ssh-hostkey-fingerprint" || \
	die 'SSH host-key fingerprint service does not report to the physical console'
grep -Eq '^root:\*:' "${audited_overlay}/etc/shadow" || \
	die 'audited root account must be password-locked'
grep -Eq '^[[:space:]]*START=60[[:space:]]*$' \
	"${audited_overlay}/etc/init.d/firewall" || die 'audited firewall service must retain START=60'
grep -Eq '(^|[[:space:]])fw3([[:space:]]|$)' \
	"${audited_overlay}/etc/init.d/firewall" || die 'audited firewall service does not invoke fw3'
if grep -ERqi 'opensync|iptables_cmd\.sh|coredump_manager' \
	"${audited_overlay}/etc/init.d/firewall" \
	"${audited_overlay}/etc/udhcpc.user" \
	"${audited_overlay}/etc/profile" \
	"${audited_overlay}/etc/sysctl.conf"; then
	die 'audited management files still reference OpenSync hooks'
fi
for upgrade_script in \
	"${audited_overlay}/sbin/sysupgrade" \
	"${audited_overlay}/lib/upgrade/do_stage2" \
	"${audited_overlay}/lib/upgrade/platform.sh" \
	"${audited_overlay}/lib/upgrade/emmc.sh"; do
	sh -n "$upgrade_script" || die "invalid audited upgrade script: $upgrade_script"
done
for supported_board in \
	'askey,sbe1v1k' 'qcom,ipq9574-ap-al02-c4' 'askey,rtq7300t-rev0'; do
	grep -Fq "$supported_board" "${audited_overlay}/lib/upgrade/platform.sh" || \
		die "platform.sh lacks supported board alias: $supported_board"
done
grep -Fq 'sbe1v1k_find_unique_partition rootfs_data 29' \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not target the rootfs_data overlay partition'
for partition_gate in \
	"sbe1v1k_find_unique_partition '0:HLOS' 25" \
	'sbe1v1k_find_unique_partition rootfs 27' \
	'sbe1v1k_find_unique_partition rootfs_data 29' \
	'sbe1v1k_find_unique_partition rsvd_2 40'; do
	grep -Fq "$partition_gate" "${audited_overlay}/lib/upgrade/platform.sh" || \
		die "platform.sh lacks partition gate: $partition_gate"
done
grep -Fq '/usr/bin/jshn' "${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not copy the jshn ELF into stage2 RAMFS'
grep -Eq "RAMFS_COPY_BIN=.*(^|[[:space:]'])uci([[:space:]']|$)" \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not copy uci into stage2 RAMFS'
grep -Fq 'platform_pre_upgrade()' "${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh lacks the live-root upgrade guard'
grep -Fq '[ -n "$(rootfs_type)" ]' "${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh live-root guard does not query the rootfs_type function'
grep -Fq '"$recovery_dev" 2>/dev/null)" = d00dfeed' \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not require the current p40 FIT chainloader'
grep -Fq 'SBE1V1K_RECOVERY_SHA256=2aad05c1ee2574874a4570367a090ebf9af66cc02d23db91365ed0b83ef5d702' \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not pin the tested p40 chainloader payload'
grep -Fq 'SBE1V1K_IMAGE_VERSION=19.07-SNAPSHOT-QSDK12-stockabi-candidate' \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not pin the reconciled candidate metadata version'
grep -Fq 'sbe1v1k_validate_metadata "$image"' \
	"${audited_overlay}/lib/upgrade/platform.sh" || \
	die 'platform.sh does not reject unreconciled candidate metadata'
for runtime_partition_gate in '/sys/class/block/${block_name}/size' \
	'/sys/class/block/${block_name}/ro' '/proc/self/mountinfo'; do
	grep -Fq "$runtime_partition_gate" "${audited_overlay}/lib/upgrade/platform.sh" || \
		die "platform.sh lacks runtime partition gate: $runtime_partition_gate"
done
for stack_check in \
	'/usr/libexec/validate_firmware_image' 'platform_check_image' \
	'ubus call system sysupgrade' 'flock -n 9' "fail 'force mode is disabled" \
	"fail 'configuration preservation is unsupported" \
	"fail 'RAMFS staging root is not empty" \
	"fail \"insufficient /tmp space"; do
	grep -Fq "$stack_check" "${audited_overlay}/sbin/sysupgrade" || \
		die "audited sysupgrade lacks required gate: $stack_check"
done
for stage2_check in '/usr/libexec/validate_firmware_image' \
	'platform_check_image "$IMAGE"' 'platform_do_upgrade "$IMAGE"' \
	'reboot -f' '/proc/sysrq-trigger' 'stage2 is not running from a RAMFS root' \
	'required RAMFS utility is missing'; do
	grep -Fq "$stage2_check" "${audited_overlay}/lib/upgrade/do_stage2" || \
		die "audited do_stage2 lacks required gate: $stage2_check"
done
if grep -Eq 'identify_magic_long|emmc_upgrade_fit|emmc_copy_config|UPGRADE_BACKUP[^:]*dd' \
	"${audited_overlay}/lib/upgrade/emmc.sh"; then
	die 'audited eMMC writer still accepts FIT/config-preservation paths'
fi
if awk '
	/tar[[:space:]]/ {
		line = $0
		gsub(/\|\|/, "", line)
		if (line ~ /\|/) found = 1
	}
	END { exit(found ? 0 : 1) }
' "${audited_overlay}/lib/upgrade/platform.sh" \
	"${audited_overlay}/lib/upgrade/emmc.sh"; then
	die 'audited upgrade scripts must not mask tar extraction failures in pipelines'
fi
grep -Fq 'of="$EMMC_DATA_DEV" bs=4096 count=1' \
	"${audited_overlay}/lib/upgrade/emmc.sh" || \
	die 'audited eMMC writer does not clear only the p29 prefix'
grep -Fq 'if="$EMMC_KERN_DEV" of="$readback_file" bs=4096 count=1' \
	"${audited_overlay}/lib/upgrade/emmc.sh" || \
	die 'audited eMMC writer does not verify the p25 invalidation write'
grep -Fq 'tar xf "$image" "$member" -O > "$destination"' \
	"${audited_overlay}/lib/upgrade/emmc.sh" || \
	die 'audited eMMC writer does not extract tar members before invalidating p25'

public_key_line="$(awk 'NF && $1 !~ /^#/ { print }' "$admin_public_key")"
[ "$(printf '%s\n' "$public_key_line" | grep -c .)" -eq 1 ] || \
	die 'admin public key file must contain exactly one non-comment key'
case "$public_key_line" in
	ssh-ed25519\ * | sk-ssh-ed25519@openssh.com\ * | ecdsa-sha2-nistp256\ * | ssh-rsa\ *) ;;
	*) die 'admin public key is not a supported OpenSSH public key' ;;
esac
ssh-keygen -l -f "$admin_public_key" >/dev/null 2>&1 || die 'ssh-keygen rejected the admin public key'

home_real="$(realpath -e -- "$HOME")"
case "$work_dir" in
	/*) ;;
	*) work_dir="${PWD}/${work_dir}" ;;
esac
mkdir -p -- "$work_dir"
work_dir="$(realpath -e -- "$work_dir")"
case "$work_dir" in
	"${home_real}"/*) ;;
	*) die "work directory must be below WSL home: $home_real" ;;
esac
[ "$work_dir" != "$home_real" ] || die 'work directory must not be WSL home itself'
[ "$(findmnt -n -o FSTYPE -T "$work_dir")" = ext4 ] || \
	die "work directory is not on ext4: $work_dir"

case "$output" in
	/*) ;;
	*) output="${PWD}/${output}" ;;
esac
output_parent="$(dirname -- "$output")"
mkdir -p -- "$output_parent"
output_parent="$(realpath -e -- "$output_parent")"
output="${output_parent}/$(basename -- "$output")"
case "$output" in
	"${home_real}"/*) ;;
	*) die "output must be below WSL home: $home_real" ;;
esac
[ "$(findmnt -n -o FSTYPE -T "$output_parent")" = ext4 ] || \
	die "output directory is not on ext4: $output_parent"
if [ -n "$overlay_dir" ]; then
	case "$overlay_dir" in
	/bin | /boot | /dev | /etc | /home | /lib | /lib64 | /mnt | /opt | /proc | \
	/root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
		die "additional overlay is an unsafe broad directory: $overlay_dir"
		;;
	esac
	for forbidden_overlay_root in \
		"$home_real" "$work_dir" "$output_parent" "$repo_root" \
		"$audited_overlay" "$openwrt_tree" "$ipk_dir" "$base_opkg_root"; do
		[ -z "$forbidden_overlay_root" ] && continue
		[ "$overlay_dir" != "$forbidden_overlay_root" ] || \
			die "additional overlay is an unsafe build/input root: $overlay_dir"
	done
	case "$work_dir/" in
	"$overlay_dir/"*) die 'work directory must not be inside the additional overlay' ;;
	esac
	case "$overlay_dir/" in
	"$work_dir/"*) die 'additional overlay must not be inside the disposable work directory' ;;
	esac
	case "$output_parent/" in
	"$overlay_dir/"*) die 'output directory must not be inside the additional overlay' ;;
	esac
	case "$overlay_dir/" in
	"$output_parent/"*) die 'additional overlay must not be inside the output directory' ;;
	esac
	for isolated_root in "$audited_overlay" "$repo_root" "$openwrt_tree" \
		"$ipk_dir" "$base_opkg_root"; do
		[ -z "$isolated_root" ] && continue
		case "$isolated_root/" in
		"$overlay_dir/"*) die "input/build tree must not be inside additional overlay: $isolated_root" ;;
		esac
		case "$overlay_dir/" in
		"$isolated_root/"*) die "additional overlay must not be inside input/build tree: $isolated_root" ;;
		esac
	done
	case "$p25" in "$overlay_dir/"*) die 'p25 input must not be inside additional overlay' ;; esac
	case "$p27" in "$overlay_dir/"*) die 'p27 input must not be inside additional overlay' ;; esac
fi
[ ! -e "$output" ] || die "refusing to overwrite output: $output"
[ ! -e "${output}.sha256" ] || die "refusing to overwrite: ${output}.sha256"
[ ! -e "${output}.audit" ] || die "refusing to overwrite: ${output}.audit"

sysupgrade_tar="${openwrt_tree}/scripts/sysupgrade-tar.sh"
[ -r "$sysupgrade_tar" ] || die "missing OpenWrt sysupgrade helper: $sysupgrade_tar"
[ -r "${openwrt_tree}/scripts/functions.sh" ] || die 'OpenWrt scripts/functions.sh is missing'

if [ -z "$fwtool" ]; then
	for candidate in \
		"${openwrt_tree}/staging_dir/host/bin/fwtool" \
		"${openwrt_tree}/staging_dir/hostpkg/bin/fwtool"; do
		if [ -x "$candidate" ]; then
			fwtool=$candidate
			break
		fi
	done
fi
[ -n "$fwtool" ] || die 'host fwtool was not found; build it or pass --fwtool'
fwtool="$(resolve_file "$fwtool")"
[ -x "$fwtool" ] || die "fwtool is not executable: $fwtool"

case "$source_date_epoch" in
	'') source_date_epoch="$(stat -c %Y "$p27")" ;;
	*[!0-9]* | 0) die '--source-date-epoch must be a positive integer' ;;
esac

run_dir="$(mktemp -d "${work_dir}/run.XXXXXXXX")"
cleanup() {
	local status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] || [ "$keep_work" -eq 1 ]; then
		printf 'private build tree retained at: %s\n' "$run_dir" >&2
	else
		rm -rf -- "$run_dir"
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "${run_dir}/audit" "${run_dir}/input" "${run_dir}/ipks" \
	"${run_dir}/output" "${run_dir}/verify"

read_list() {
	sed -e 's/[[:space:]]*#.*$//' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' \
		-e '/^$/d' "$1"
}

safe_relative_path() {
	local value=$1
	while [[ "$value" == ./* ]]; do
		value=${value#./}
	done
	[ -n "$value" ] || return 1
	case "$value" in
	/* | .. | ../* | */../* | */.. | *\\*) return 1 ;;
	esac
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

mapfile -t protected_patterns < <(read_list "$protected_paths")
mapfile -t overwrite_patterns < <(read_list "$allowed_overwrites")

matches_patterns() {
	local path=$1
	shift
	local pattern
	for pattern in "$@"; do
		if [[ "$path" == $pattern ]]; then
			return 0
		fi
	done
	return 1
}

is_sensitive_identity_path() {
	case "$1" in
	etc/shadow | etc/shadow.* | etc/dropbear/dropbear_*_host_key | \
	*/authorized_keys | etc/ssl/private/* | usr/tls/* | etc/uhttpd.key | \
	etc/uhttpd.crt | usr/askey/server_rsakey.pem | usr/opensync/certs/* | \
	opt/cujo/etc/*)
		return 0
		;;
	esac
	return 1
}

is_fixed_overlay_path() {
	case "$1" in
	etc/config/network | etc/config/network/* | \
	etc/config/dropbear | etc/config/dropbear/* | \
	etc/config/uhttpd | etc/config/uhttpd/* | \
	etc/config/rpcd | etc/config/rpcd/* | \
	etc/config/firewall | etc/config/firewall/* | \
	etc/config/dhcp | etc/config/dhcp/* | \
	etc/passwd | etc/passwd/* | etc/group | etc/group/* | \
	etc/shadow | etc/shadow/* | etc/firewall.user | etc/firewall.user/* | \
	etc/init.d/firewall | etc/init.d/firewall/* | \
	etc/udhcpc.user | etc/udhcpc.user/* | \
	etc/ppp/ip-up | etc/ppp/ip-up/* | etc/ppp/ip-down | etc/ppp/ip-down/* | \
		etc/sysupgrade.conf | etc/sysupgrade.conf/* | \
		etc/opkg/distfeeds.conf | etc/opkg/customfeeds.conf | etc/opkg/feeds.conf | \
		usr/lib/opkg/lists | usr/lib/opkg/lists/* | \
		etc/crontabs/root | etc/crontabs/root/* | \
	etc/profile | etc/profile/* | etc/sysctl.conf | etc/sysctl.conf/* | \
	etc/dropbear/authorized_keys | etc/dropbear/authorized_keys/* | \
	lib/preinit/* | lib/upgrade/platform.sh | lib/upgrade/platform.sh/* | \
	lib/upgrade/emmc.sh | lib/upgrade/emmc.sh/* | \
	lib/upgrade/do_stage2 | lib/upgrade/do_stage2/* | \
	sbin/sysupgrade | sbin/sysupgrade/* | sbin/reboot | sbin/reboot/* | \
	etc/uci-defaults/qca-mcsd | etc/uci-defaults/qca-mcsd/* | \
	etc/uci-defaults/99-miniupnpd | etc/uci-defaults/99-miniupnpd/*)
		return 0
		;;
	esac
	return 1
}

preflight_overlay_tree() {
	local source=$1
	local destination=$2
	local caller_supplied=$3
	local item relative
	[ "$source" != / ] || die 'refusing to inspect the filesystem root as an overlay'
	: > "$destination"
	while IFS= read -r -d '' item; do
		relative=${item#"${source}/"}
		[ "$relative" != "$item" ] || die "overlay path escaped its root: $item"
		safe_relative_path "$relative" || die "unsafe overlay path: $relative"
		[ ! -L "$item" ] || die "overlay symlinks are not accepted: $relative"
		if [ -d "$item" ]; then
			continue
		fi
		[ -f "$item" ] || die "overlay contains a special file: $relative"
		if [ "$caller_supplied" -eq 1 ]; then
			matches_patterns "$relative" "${protected_patterns[@]}" && \
				die "additional overlay touches protected stock ABI path: $relative"
			is_sensitive_identity_path "$relative" && \
				die "additional overlay attempts to embed an identity or credential: $relative"
			is_fixed_overlay_path "$relative" && \
				die "additional overlay attempts to replace an audited path: $relative"
		fi
		sha256sum "$item" | sed "s#  .*#  $relative#" >> "$destination"
	done < <(find "$source" -xdev -mindepth 1 -print0)
	sort -o "$destination" "$destination"
}

assert_no_embedded_private_keys() {
	local root=$1
	local destination=$2
	local item relative grep_status
	: > "$destination"
	while IFS= read -r -d '' item; do
		if grep -IqE -- '-----BEGIN ([A-Z0-9]+[[:space:]])*(OPENSSH[[:space:]]+)?PRIVATE KEY-----' "$item"; then
			relative=${item#"${root}/"}
			printf '%s\n' "$relative" >> "$destination"
		else
			grep_status=$?
			[ "$grep_status" -ne 2 ] || die "could not scan for private keys: $item"
		fi
	done < <(find "$root" -xdev -type f -print0)
	sort -u -o "$destination" "$destination"
	[ ! -s "$destination" ] || die "embedded private key material found; see $destination"
}

assert_stock_fstools() {
	local root=$1
	local destination=$2
	local token
	[ -x "${root}/sbin/mount_root" ] || die 'stock mount_root binary is missing'
	[ -f "${root}/lib/libfstools.so" ] || die 'stock libfstools.so is missing'
	strings "${root}/sbin/mount_root" "${root}/lib/libfstools.so" > "$destination"
	for token in rootfs_data ext4 overlayfs; do
		grep -Fq "$token" "$destination" || \
			die "stock fstools lacks required capability string: $token"
	done
	grep -Fq rootfs_data_1 "$destination" && \
		die 'stock fstools unexpectedly targets vendor rootfs_data_1'
}

assert_audited_overlay_content() {
	local root=$1
	local item relative
	while IFS= read -r -d '' item; do
		relative=${item#"${audited_overlay}/"}
		cmp -s "$item" "${root}/${relative}" || \
			die "audited overlay content changed in final rootfs: $relative"
	done < <(find "$audited_overlay" -xdev -type f -print0)
}

assert_rootfs_policy() {
	local root=$1
	local audit_prefix=$2
	local preserved forbidden_path executable upgrade_script machine
	assert_audited_overlay_content "$root"
	cmp -s "$expected_authorized_keys" "${root}/etc/dropbear/authorized_keys" || \
		die 'installed Dropbear authorized_keys differs from the required admin key'
	[ "$(stat -c %a "${root}/etc/dropbear/authorized_keys")" = 600 ] || \
		die 'Dropbear authorized_keys mode is not 0600'
	[ "$(stat -c %a "${root}/etc/shadow")" = 600 ] || \
		die '/etc/shadow mode is not 0600'
	grep -Eq '^root:\*:' "${root}/etc/shadow" || \
		die 'root account is not password-locked'
	[ -L "${root}/sbin/reboot" ] || die '/sbin/reboot is not a BusyBox symlink'
	[ "$(readlink -- "${root}/sbin/reboot")" = /bin/busybox ] || \
		die '/sbin/reboot does not point to /bin/busybox'
	[ -L "${root}/usr/bin/flock" ] && \
		[ "$(readlink -- "${root}/usr/bin/flock")" = /usr/bin/util-linux-flock ] || \
		die '/usr/bin/flock does not point to the retained util-linux implementation'
	[ ! -s "${root}/etc/crontabs/root" ] || die 'root crontab is not empty'
	! grep -Eq '^Package:[[:space:]]+luci-app-opkg$' "${root}/usr/lib/opkg/status" || \
		die 'luci-app-opkg must not be registered in a candidate image'
	if grep -ERq '^[[:space:]]*src(/gzip)?[[:space:]]' \
		"${root}/etc/opkg.conf" "${root}/etc/opkg" 2>/dev/null; then
		die 'runtime opkg feed configuration survived in a candidate image'
	fi
	for executable in \
		bin/busybox bin/ubus sbin/uci sbin/upgraded sbin/sysupgrade \
		usr/bin/fwtool usr/bin/jshn usr/bin/flock usr/bin/util-linux-flock \
		usr/bin/cmp usr/bin/head usr/bin/hexdump usr/bin/sha256sum \
		usr/bin/sort usr/bin/wc usr/libexec/validate_firmware_image; do
		[ -x "${root}/${executable}" ] || \
			die "stage2 dependency is missing or not executable: $executable"
	done
	for executable in bin/ubus sbin/uci sbin/upgraded usr/bin/fwtool usr/bin/jshn \
		usr/bin/util-linux-flock; do
		machine="$(readelf -h "${root}/${executable}" 2>/dev/null | \
			sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
		case "$machine" in
		*AArch64*) ;;
		*) die "stage2 dependency is not AArch64 ELF: $executable" ;;
		esac
	done
	for upgrade_script in \
		sbin/sysupgrade lib/upgrade/do_stage2 lib/upgrade/platform.sh \
		lib/upgrade/emmc.sh lib/preinit/01_default_configs \
		lib/preinit/42_mount_askey_partition lib/preinit/80_mount_root; do
		sh -n "${root}/${upgrade_script}" || \
			die "final rootfs contains invalid shell: $upgrade_script"
	done
	[ ! -e "${root}/etc/uci-defaults/qca-mcsd" ] || \
		die 'qca-mcsd UCI default survived management-plane cleanup'
	[ ! -e "${root}/etc/uci-defaults/99-miniupnpd" ] || \
		die 'miniupnpd UCI default survived management-plane cleanup'
	[ -f "${root}/etc/uci-defaults/99-qca-nss-ecm" ] || \
		die 'required 99-qca-nss-ecm UCI default is missing'
	if grep -ERqi 'opensync|iptables_cmd\.sh|coredump_manager' \
		"${root}/etc/init.d/firewall" "${root}/etc/udhcpc.user" \
		"${root}/etc/profile" "${root}/etc/sysctl.conf" \
		"${root}/etc/ppp/ip-up" "${root}/etc/ppp/ip-down" \
		"${root}/etc/sysupgrade.conf" "${root}/sbin/sysupgrade" \
		"${root}/lib/upgrade/do_stage2" \
		"${root}/lib/upgrade/platform.sh" "${root}/lib/upgrade/emmc.sh"; then
		die 'final management hooks still reference OpenSync'
	fi
	grep -Eq '(^|[[:space:]])fw3([[:space:]]|$)' "${root}/etc/init.d/firewall" || \
		die 'final firewall init does not invoke stock fw3'
	if grep -Eq 'mf_tool READ_SN|passwd[[:space:]]+root|dnsmasq disable|ovs_enabled=1|shadow\.orig|del_(osync|plume)_for_upgrade|/usr/tls/(certs|private)' \
		"${root}/etc/init.d/boot"; then
		die 'sanitized stock boot still contains a forbidden vendor control hook'
	fi
	for preserved in '/sbin/kmodloader' 'firmware_rdp_feature.ini' \
		'/bin/board_detect' 'READ_6G_MAC' '/sbin/reload_config'; do
		grep -Fq "$preserved" "${root}/etc/init.d/boot" || \
			die "sanitized stock boot lost required logic: $preserved"
	done
	for forbidden_path in \
		.version etc/sign/public.key etc/uhttpd.key etc/uhttpd.crt \
		etc/opkg/distfeeds.conf etc/opkg/customfeeds.conf etc/opkg/feeds.conf \
		etc/config/opensync-default etc/init.d/opensync \
		usr/askey/server_rsakey.pem usr/opensync opt/cujo/etc \
		etc/miniupnpd etc/hotplug.d/iface/50-miniupnpd \
		etc/init.d/miniupnpd usr/sbin/miniupnpd usr/share/miniupnpd \
		usr/lib/lua/luci/controller/admin/thread.lua \
		usr/lib/lua/luci/view/admin_thread; do
		[ ! -e "${root}/${forbidden_path}" ] || \
			die "embedded credential path survived cleanup: $forbidden_path"
	done
	if find "${root}/etc/dropbear" -xdev \( -type f -o -type l \) \
		-name 'dropbear_*_host_key' | grep -q .; then
		die 'final rootfs contains a pre-generated Dropbear host key'
	fi
	if find "${root}/etc/rc.d" -maxdepth 1 -type l \
		-lname '*init.d/qca-nss-ppe-ds' | grep -q .; then
		die 'qca-nss-ppe-ds gained an unaudited rc.d link'
	fi
	assert_stock_fstools "$root" "${audit_prefix}-fstools-strings.txt"
	assert_no_embedded_private_keys "$root" "${audit_prefix}-private-key-hits.txt"
}

squashfs_special_manifest() {
	local listing=$1
	local destination=$2
	awk '
		$1 ~ /^[bcps]/ {
			spec = ""
			for (i = 3; i < NF; i++) {
				if ($i ~ /^[0-9]+,[0-9]+$/) { spec = $i; break }
				if ($i ~ /^[0-9]+,$/ && $(i + 1) ~ /^[0-9]+$/) {
					spec = $i $(i + 1)
					break
				}
			}
			print $1 "\t" spec "\t" $NF
		}
	' "$listing" > "$destination"
}

squashfs_expected_structure() {
	local listing=$1
	local destination=$2
	awk '
		$1 ~ /^[-dl]/ {
			mode = $1
			if (substr(mode, 1, 1) == "l") {
				kind = "L"
				path = $(NF - 2)
				target = $NF
			} else {
				kind = (substr(mode, 1, 1) == "d") ? "D" : "F"
				path = $NF
				target = "-"
			}
			if (path == "squashfs-root") next
			sub(/^squashfs-root\//, "", path)
			print kind "\t" mode "\t" path "\t" target
		}
	' "$listing" | sort > "$destination"
}

rootfs_actual_structure() {
	local root=$1
	local destination=$2
	local item relative mode kind target
	: > "$destination"
	while IFS= read -r -d '' item; do
		relative=${item#"${root}/"}
		mode="$(stat -c %A -- "$item")"
		if [ -L "$item" ]; then
			kind=L
			target="$(readlink -- "$item")"
		elif [ -d "$item" ]; then
			kind=D
			target=-
		else
			kind=F
			target=-
		fi
		printf '%s\t%s\t%s\t%s\n' "$kind" "$mode" "$relative" "$target" \
			>> "$destination"
	done < <(find "$root" -xdev -mindepth 1 \( -type f -o -type d -o -type l \) -print0)
	sort -o "$destination" "$destination"
}

extract_squashfs_verified() {
	local image=$1
	local destination=$2
	local label=$3
	local listing="${run_dir}/audit/${label}-squashfs-list.txt"
	local special="${run_dir}/audit/${label}-device-nodes.txt"
	local expected="${run_dir}/audit/${label}-structure-expected.txt"
	local actual="${run_dir}/audit/${label}-structure-actual.txt"
	local stderr_file="${run_dir}/audit/${label}-unsquashfs.stderr"
	local exclude_file="${run_dir}/input/${label}-exclude.txt"

	[ ! -e "$destination" ] || die "SquashFS extraction destination already exists: $destination"
	unsquashfs -lln "$image" > "$listing"
	squashfs_special_manifest "$listing" "$special"
	[ "$(wc -l < "$special")" -eq 1 ] || \
		die "$label SquashFS contains an unexpected number of special nodes"
	grep -Eq '^crw-------[[:space:]]+5,1[[:space:]]+squashfs-root/dev/console$' \
		"$special" || die "$label SquashFS special node is not /dev/console c 0600 5:1"
	squashfs_expected_structure "$listing" "$expected"
	printf '%s\n' dev/console > "$exclude_file"
	unsquashfs -no-progress -d "$destination" -exclude-file "$exclude_file" "$image" \
		> "${run_dir}/audit/${label}-unsquashfs.stdout" 2> "$stderr_file" || \
		die "$label SquashFS extraction failed"
	rootfs_actual_structure "$destination" "$actual"
	cmp -s "$expected" "$actual" || \
		die "$label SquashFS ordinary file/directory/symlink structure did not round-trip"
	(
		cd "$destination"
		find . -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum
	) > "${run_dir}/audit/${label}-regular-files.sha256"
	printf 'structure_entries=%s\nregular_files=%s\n' \
		"$(wc -l < "$actual")" \
		"$(wc -l < "${run_dir}/audit/${label}-regular-files.sha256")" \
		> "${run_dir}/audit/${label}-extraction-counts.txt"
	sha256sum "$expected" "$actual" \
		"${run_dir}/audit/${label}-regular-files.sha256" \
		> "${run_dir}/audit/${label}-extraction-manifests.sha256"
}

log 'verifying immutable dump inputs'
p25_hash="$(sha256sum "$p25" | awk '{print $1}')"
p27_hash="$(sha256sum "$p27" | awk '{print $1}')"
[ "$p25_hash" = "$expected_p25_sha256" ] || \
	die "p25 SHA-256 mismatch: $p25_hash"
[ "$p27_hash" = "$expected_p27_sha256" ] || \
	die "p27 SHA-256 mismatch: $p27_hash"
printf '%s  %s\n%s  %s\n' \
	"$p25_hash" "$(basename -- "$p25")" \
	"$p27_hash" "$(basename -- "$p27")" \
	> "${run_dir}/audit/input.sha256"

grep -Eqi 'NHSS[._-]?QSDK[._-]?12\.2[._-]?[Rr]6|12\.02\.06\.2230\.023' "$qsdk_manifest" || \
	grep -Fqi "$expected_openwrt_revision" "$qsdk_manifest" || \
	die 'QSDK manifest does not identify the NHSS.QSDK.12.2.r6-00023 baseline'
sha256sum "$qsdk_manifest" | sed "s#  .*#  $(basename -- "$qsdk_manifest")#" \
	> "${run_dir}/audit/qsdk-manifest.sha256"
sha256sum "$sysupgrade_tar" "$fwtool" > "${run_dir}/audit/packaging-tools.sha256"

log 'extracting and validating the inner stock FIT'
fit_magic="$(od -An -tx1 -j "$fit_offset" -N 4 "$p25" | tr -d ' \n')"
[ "$fit_magic" = d00dfeed ] || die "no FIT magic at p25 offset 0x3000: $fit_magic"
fit_size_hex="$(od -An -tx1 -j "$((fit_offset + 4))" -N 4 "$p25" | tr -d ' \n')"
[[ "$fit_size_hex" =~ ^[0-9a-fA-F]{8}$ ]] || die 'invalid FIT totalsize field'
fit_size=$((16#$fit_size_hex))
p25_size="$(stat -c %s "$p25")"
[ "$fit_size" -ge 64 ] || die "invalid FIT size: $fit_size"
[ "$((fit_offset + fit_size))" -le "$p25_size" ] || die 'FIT extends beyond p25 input'
[ "$fit_size" -le "$kernel_limit" ] || die "FIT exceeds p25 safety limit: $fit_size"
dd if="$p25" of="${run_dir}/input/kernel.itb" \
	iflag=skip_bytes,count_bytes skip="$fit_offset" count="$fit_size" status=none
fit_hash="$(sha256sum "${run_dir}/input/kernel.itb" | awk '{print $1}')"
[ "$fit_hash" = "$expected_fit_sha256" ] || die "inner FIT SHA-256 mismatch: $fit_hash"
dumpimage -l "${run_dir}/input/kernel.itb" > "${run_dir}/audit/fit-info.txt"
grep -Fq 'Linux-5.4.213' "${run_dir}/audit/fit-info.txt" || \
	die 'inner FIT does not identify Linux-5.4.213'
grep -Eq 'rtq7300t-rev[012]' "${run_dir}/audit/fit-info.txt" || \
	die 'inner FIT does not contain an expected SBE1V1K configuration'

root_magic="$(od -An -tx1 -N 4 "$p27" | tr -d ' \n')"
[ "$root_magic" = 68737173 ] || die "p27 is not little-endian SquashFS: $root_magic"
unsquashfs -s "$p27" > "${run_dir}/audit/stock-squashfs-info.txt"
grep -Eqi 'compression[[:space:]]+xz|xz compressed' "${run_dir}/audit/stock-squashfs-info.txt" || \
	die 'p27 does not use the expected xz compression'
grep -Eqi 'block size[[:space:]]+262144|block_size[=:][[:space:]]*262144' \
	"${run_dir}/audit/stock-squashfs-info.txt" || \
	die 'p27 does not use the expected 262144-byte block size'
log 'unpacking the stock p27 rootfs'
rootfs="${run_dir}/rootfs"
extract_squashfs_verified "$p27" "$rootfs" stock-p27
[ -d "${rootfs}/lib/modules/5.4.213" ] || die 'stock rootfs lacks /lib/modules/5.4.213'

collect_qca_rc_manifest() {
	local root=$1
	local destination=$2
	local link service
	: > "$destination"
	for link in "${root}/etc/rc.d/"*; do
		[ -L "$link" ] || continue
		service="$(basename -- "$(readlink -- "$link")")"
		case "$service" in
		wifi_fw_mount | SI_eye_diagram | license-pfm | load_cnss2 | \
		askey_pwm | boot | ftm | qca-* | qca_pta_config | \
		qcawifi-* | wifi_fw_done | 01_skb_recycler | rngd | sysctl | \
		syslog | system | powerctl | thermal)
			printf '%s\t%s\n' "$(basename -- "$link")" "$(readlink -- "$link")" \
				>> "$destination"
			;;
		esac
	done
	sort -o "$destination" "$destination"
}

collect_qca_rc_manifest "$rootfs" "${run_dir}/audit/stock-qca-rc.txt"

collect_protected_manifest() {
	local root=$1
	local destination=$2
	local scratch="${destination}.unsorted"
	: > "$scratch"
	local pattern match item relative target digest mode
	local -a matches=()
	for pattern in "${protected_patterns[@]}"; do
		mapfile -t matches < <(compgen -G "${root}/${pattern}" || true)
		for match in "${matches[@]}"; do
			if [ -d "$match" ] && [ ! -L "$match" ]; then
				while IFS= read -r -d '' item; do
					relative=${item#"${root}/"}
					if [ -L "$item" ]; then
						target="$(readlink -- "$item")"
						printf 'L\t%s\t%s\n' "$target" "$relative" >> "$scratch"
					elif [ -f "$item" ]; then
						digest="$(sha256sum "$item" | awk '{print $1}')"
						printf 'F\t%s\t%s\n' "$digest" "$relative" >> "$scratch"
					else
						mode="$(stat -c '%F:%a' "$item")"
						printf 'S\t%s\t%s\n' "$mode" "$relative" >> "$scratch"
					fi
				done < <(find "$match" -xdev \( -type f -o -type l -o -type b -o -type c \) -print0)
			elif [ -L "$match" ]; then
				relative=${match#"${root}/"}
				target="$(readlink -- "$match")"
				printf 'L\t%s\t%s\n' "$target" "$relative" >> "$scratch"
			elif [ -f "$match" ]; then
				relative=${match#"${root}/"}
				digest="$(sha256sum "$match" | awk '{print $1}')"
				printf 'F\t%s\t%s\n' "$digest" "$relative" >> "$scratch"
			fi
		done
	done
	sort -u "$scratch" > "$destination"
	rm -f -- "$scratch"
}

collect_protected_manifest "$rootfs" "${run_dir}/audit/stock-abi.sha256"
[ -s "${run_dir}/audit/stock-abi.sha256" ] || die 'protected stock ABI manifest is empty'

log 'removing known vendor web and cloud entry points'
while IFS= read -r relative; do
	safe_relative_path "$relative" || die "unsafe remove path: $relative"
	case "$relative" in
	lib/modules* | etc/modules.d* | lib/firmware* | usr/local/firmware*)
		die "remove list attempts to touch firmware ABI data: $relative"
		;;
	esac
	rm -rf -- "${rootfs}/${relative}"
done < <(read_list "$remove_paths")

sanitize_vendor_boot() {
	local boot="${rootfs}/etc/init.d/boot"
	local rewritten="${run_dir}/boot.rewritten"
	[ -f "$boot" ] || die 'stock /etc/init.d/boot is missing'
	[ "$(grep -Fc '# change root password' "$boot")" -eq 1 ] || \
		die 'stock boot password block is not the audited version'
	[ "$(grep -Fc 'mf_tool READ_SN' "$boot")" -eq 1 ] || \
		die 'stock boot serial-number password logic is not the audited version'
	grep -Fq 'qca-nss-bridge-mgr ovs_enabled=1' "$boot" || \
		die 'stock boot OVS force-enable block is not the audited version'
	awk '
		/^del_(osync|plume)_for_upgrade\(\)[[:space:]]*\{/ { skip_account = 1; next }
		skip_account && /^\}/ { skip_account = 0; next }
		skip_account { next }
		/nss_num=`cat \/etc\/modules\.d\/51-qca-nss-drv-bridge-mgr/ {
			skip_ovs = 1
			print "\t# Use the standard Linux bridge; do not force OVS mode."
			next
		}
		skip_ovs && /^[[:space:]]*fi[[:space:]]*$/ { skip_ovs = 0; next }
		skip_ovs { next }
		/^[[:space:]]*# change root password[[:space:]]*$/ {
			skip = 1
			print "\t# Root credentials are managed by OpenWrt/LuCI."
			next
		}
		skip && /^[[:space:]]*#del osync user when dut upgrade/ { skip = 0 }
		!skip && $0 !~ /cp \/etc\/shadow\.orig \/tmp\/shadow/ &&
			$0 !~ /^[[:space:]]*del_(osync|plume)_for_upgrade[[:space:]]*$/ &&
			$0 !~ /\/etc\/init\.d\/dnsmasq disable/ &&
			$0 !~ /ln -sf \/usr\/tls\/(certs|private) \/tmp\/tls/ { print }
	' "$boot" > "$rewritten"
	grep -Fq 'mf_tool READ_SN' "$rewritten" && die 'failed to remove serial-number password logic'
	grep -Eq 'passwd[[:space:]]+root' "$rewritten" && die 'failed to remove root password rewrite'
	grep -Fq '/etc/init.d/dnsmasq disable' "$rewritten" && die 'failed to remove dnsmasq disable hook'
	grep -Fq 'ovs_enabled=1' "$rewritten" && die 'failed to remove forced OVS mode'
	grep -Eq '/usr/tls/(certs|private)' "$rewritten" && die 'failed to remove vendor TLS links'
	grep -Eq 'shadow\.orig|del_(osync|plume)_for_upgrade' "$rewritten" && \
		die 'failed to remove vendor account handling'
	for preserved in '/sbin/kmodloader' 'firmware_rdp_feature.ini' '/bin/board_detect' \
		'READ_6G_MAC' '/sbin/reload_config'; do
		grep -Fq "$preserved" "$rewritten" || \
			die "boot sanitization removed required stock logic: $preserved"
	done
	install -m 0755 "$rewritten" "$boot"
}

sanitize_vendor_boot
if [ -d "${rootfs}/etc/dropbear" ]; then
	find "${rootfs}/etc/dropbear" -xdev -type f -name 'dropbear_*_host_key' -delete
fi

log 'indexing curated QSDK r6 management IPKs'
mapfile -d '' -t all_ipks < <(find "$ipk_dir" -maxdepth 1 -type f -name '*.ipk' -print0 | sort -z)
[ "${#all_ipks[@]}" -gt 0 ] || die "no IPKs found in: $ipk_dir"

archive_path_is_safe() {
	local archive=$1
	local entry normalized entries
	entries="$(tar -tf "$archive")" || die "could not list package archive: $archive"
	while IFS= read -r entry; do
		normalized=$entry
		while [[ "$normalized" == ./* ]]; do
			normalized=${normalized#./}
		done
		[ -z "$normalized" ] && continue
		safe_relative_path "$normalized" || die "unsafe archive path in $archive: $entry"
	done <<< "$entries"
}

payload_symlinks_are_safe() {
	local root=$1
	local item relative target resolved normalized
	while IFS= read -r -d '' item; do
		relative=${item#"${root}/"}
		target="$(readlink -- "$item")"
		[ -n "$target" ] || die "package payload has an empty symlink: $relative"
		case "$target" in
		/*)
			normalized=${target#/}
			safe_relative_path "$normalized" || \
				die "package payload has an unsafe absolute symlink: $relative -> $target"
			;;
		*)
			resolved="$(realpath -m -- "$(dirname -- "$item")/$target")"
			case "$resolved" in
			"$root" | "$root"/*) ;;
			*) die "package payload symlink escapes its root: $relative -> $target" ;;
			esac
			;;
		esac
	done < <(find "$root" -xdev -type l -print0)
}

unpack_ipk() {
	local ipk=$1
	local destination=$2
	mkdir -p "$destination/control" "$destination/data"
	local debian_member control_member data_member member
	debian_member=
	control_member=
	data_member=
	while IFS= read -r member; do
		case "$member" in
		debian-binary) debian_member=$member ;;
		control.tar.* | control.tar) [ -z "$control_member" ] || die "multiple control archives in $ipk"; control_member=$member ;;
		data.tar.* | data.tar) [ -z "$data_member" ] || die "multiple data archives in $ipk"; data_member=$member ;;
		esac
	done < <(ar t "$ipk")
	[ -n "$debian_member" ] && [ -n "$control_member" ] && [ -n "$data_member" ] || \
		die "invalid IPK members: $ipk"
	[ "$(ar p "$ipk" "$debian_member" | tr -d '[:space:]')" = 2.0 ] || \
		die "unsupported IPK format: $ipk"
	ar p "$ipk" "$control_member" > "${destination}/${control_member}"
	ar p "$ipk" "$data_member" > "${destination}/${data_member}"
	archive_path_is_safe "${destination}/${control_member}"
	archive_path_is_safe "${destination}/${data_member}"
	tar --no-same-owner -xf "${destination}/${control_member}" -C "${destination}/control"
	tar --no-same-owner -xf "${destination}/${data_member}" -C "${destination}/data"
	payload_symlinks_are_safe "${destination}/control"
	payload_symlinks_are_safe "${destination}/data"
}

control_field() {
	local control=$1
	local field=$2
	awk -v wanted="$field" '
		BEGIN { active = 0; value = "" }
		$0 ~ ("^" wanted ":[[:space:]]*") {
			active = 1
			sub("^" wanted ":[[:space:]]*", "")
			value = $0
			next
		}
		active && /^[[:space:]]/ {
			sub(/^[[:space:]]+/, "")
			value = value " " $0
			next
		}
		active { print value; printed = 1; exit }
		END { if (active && !printed) print value }
	' "$control" | head -n 1 | tr -d '\r'
}

declare -A ipk_by_name=()
declare -A unpack_by_name=()
declare -A control_by_name=()
declare -A provides_name=()
ipk_index=0
: > "${run_dir}/audit/ipks.sha256"
for ipk in "${all_ipks[@]}"; do
	entry_dir="${run_dir}/ipks/${ipk_index}"
	unpack_ipk "$ipk" "$entry_dir"
	mapfile -t controls < <(find "${entry_dir}/control" -type f -name control -print)
	[ "${#controls[@]}" -eq 1 ] || die "IPK must contain exactly one control file: $ipk"
	control=${controls[0]}
	package="$(control_field "$control" Package)"
	architecture="$(control_field "$control" Architecture)"
	[[ "$package" =~ ^[A-Za-z0-9.+_-]+$ ]] || die "invalid package name in $ipk: $package"
	case "$architecture" in
	all | aarch64_cortex-a73_neon-vfpv4) ;;
	*) die "unexpected package architecture for $package: $architecture" ;;
	esac
	[ -z "${ipk_by_name[$package]+x}" ] || die "duplicate package in IPK directory: $package"
	case "$package" in
	kernel | kmod-* | base-files | libc | musl | busybox | procd | \
	ubus | uci | netifd | fstools | qca-* | qca_* | hostapd* | \
	wpa-supplicant* | libnl*)
		die "package is outside the management-plane boundary: $package"
		;;
	esac
	ipk_by_name[$package]=$ipk
	unpack_by_name[$package]=$entry_dir
	control_by_name[$package]=$control
	provides="$(control_field "$control" Provides)"
	provides=${provides//,/ }
	for provided in $provides; do
		provided=${provided%%(*}
		provided=${provided//[[:space:]]/}
		[ -n "$provided" ] && provides_name[$provided]=$package
	done
	sha256sum "$ipk" | sed "s#  .*#  $(basename -- "$ipk")#" >> "${run_dir}/audit/ipks.sha256"
	ipk_index=$((ipk_index + 1))
done

mapfile -t requested_packages < <(read_list "$package_list")
[ "${#requested_packages[@]}" -gt 0 ] || die 'package list is empty'
declare -A selected_name=()
filtered_packages=()
opkg_ui_requested=0
for package in "${requested_packages[@]}"; do
	[[ "$package" =~ ^[A-Za-z0-9.+_-]+$ ]] || die "invalid package-list entry: $package"
	[ -z "${selected_name[$package]+x}" ] || die "duplicate package-list entry: $package"
	if [ "$package" = luci-app-opkg ]; then
		opkg_ui_requested=1
		selected_name[$package]=filtered
		continue
	fi
	[ -n "${ipk_by_name[$package]+x}" ] || die "requested IPK is missing: $package"
	selected_name[$package]=1
	filtered_packages+=("$package")
done
requested_packages=("${filtered_packages[@]}")
unset filtered_packages 'selected_name[luci-app-opkg]'
[ "${#requested_packages[@]}" -gt 0 ] || die 'package list contains no installable management packages'
[ "$opkg_ui_requested" -eq 0 ] || \
	warn 'omitting luci-app-opkg: no candidate has a reconciled base package database'

status_file="${rootfs}/usr/lib/opkg/status"
mkdir -p "${rootfs}/usr/lib/opkg/info" "${rootfs}/usr/share/sbe1v1k-stockabi"
declare -A verified_base_package=()
declare -A base_provider_name=()
if [ -n "$base_opkg_root" ]; then
	base_opkg_status="${base_opkg_root}/usr/lib/opkg/status"
	base_opkg_info="${base_opkg_root}/usr/lib/opkg/info"
	[ -f "$base_opkg_status" ] || die 'base opkg root lacks usr/lib/opkg/status'
	[ -d "$base_opkg_info" ] || die 'base opkg root lacks usr/lib/opkg/info'
	[ "$(grep -Ec '^Package:[[:space:]]+' "$base_opkg_status")" -ge 20 ] || \
		die 'base opkg status has fewer than 20 Package records'
	grep -Eq '^Status:[[:space:]]+install[[:space:]].*installed' "$base_opkg_status" || \
		die 'base opkg status contains no installed package records'
	[ "$(find "$base_opkg_info" -maxdepth 1 -type f -name '*.control' | wc -l)" -ge 20 ] || \
		die 'base opkg info has fewer than 20 control records'
	[ "$(find "$base_opkg_info" -maxdepth 1 -type f -name '*.list' | wc -l)" -ge 20 ] || \
		die 'base opkg info has fewer than 20 file lists'
	mapfile -t base_status_packages < <(sed -n 's/^Package:[[:space:]]*//p' "$base_opkg_status")
	[ "${#base_status_packages[@]}" -eq "$(printf '%s\n' "${base_status_packages[@]}" | sort -u | wc -l)" ] || \
		die 'base opkg status contains duplicate Package records'
	: > "${run_dir}/audit/base-opkg-payload-reconciliation.txt"
	while IFS= read -r package; do
		[[ "$package" =~ ^[A-Za-z0-9.+_-]+$ ]] || \
			die "invalid package name in base opkg status: $package"
		[ -f "${base_opkg_info}/${package}.control" ] || \
			die "base opkg database lacks ${package}.control"
		[ -f "${base_opkg_info}/${package}.list" ] || \
			die "base opkg database lacks ${package}.list"
		[ "$(control_field "${base_opkg_info}/${package}.control" Package)" = "$package" ] || \
			die "base opkg control Package field does not match: $package"
		payload_entries=0
		missing_entries=0
		while IFS= read -r listed_path || [ -n "$listed_path" ]; do
			listed_path=${listed_path%$'\r'}
			while [[ "$listed_path" == /* ]]; do listed_path=${listed_path#/}; done
			while [[ "$listed_path" == ./* ]]; do listed_path=${listed_path#./}; done
			[ -n "$listed_path" ] || continue
			safe_relative_path "$listed_path" || \
				die "unsafe path in base opkg list for $package: $listed_path"
			case "$listed_path" in
			usr/lib/opkg | usr/lib/opkg/*) continue ;;
			esac
			payload_entries=$((payload_entries + 1))
			if [ ! -e "${rootfs}/${listed_path}" ] && [ ! -L "${rootfs}/${listed_path}" ]; then
				missing_entries=$((missing_entries + 1))
				printf 'missing\t%s\t%s\n' "$package" "$listed_path" \
					>> "${run_dir}/audit/base-opkg-payload-reconciliation.txt"
			fi
		done < "${base_opkg_info}/${package}.list"
		if [ "$payload_entries" -gt 0 ] && [ "$missing_entries" -eq 0 ]; then
			verified_base_package[$package]=1
			printf 'present\t%s\t%s paths\n' "$package" "$payload_entries" \
				>> "${run_dir}/audit/base-opkg-payload-reconciliation.txt"
			base_provides="$(control_field "${base_opkg_info}/${package}.control" Provides)"
			base_provides=${base_provides//,/ }
			for provided in $base_provides; do
				provided=${provided%%(*}
				provided=${provided//[[:space:]]/}
				[ -n "$provided" ] && base_provider_name[$provided]=$package
			done
		else
			printf 'unverified\t%s\t%s paths\t%s missing\n' \
				"$package" "$payload_entries" "$missing_entries" \
				>> "${run_dir}/audit/base-opkg-payload-reconciliation.txt"
		fi
	done < <(sed -n 's/^Package:[[:space:]]*//p' "$base_opkg_status")
	(
		cd "$base_opkg_root"
		find usr/lib/opkg -type f -print0 | sort -z | xargs -0 sha256sum
	) > "${run_dir}/audit/base-opkg-database.sha256"
else
	if [ "$allow_incomplete_opkg_db" -ne 1 ]; then
		die 'stock p27 has an incomplete opkg database; provide --base-opkg-root or explicitly pass --allow-incomplete-opkg-db'
	fi
	warn 'building without base-package reconciliation evidence'
fi

if [ -d "${rootfs}/usr/lib/opkg" ]; then
	(
		cd "$rootfs"
		find usr/lib/opkg -type f -print0 | sort -z | xargs -0 -r sha256sum
	) > "${run_dir}/audit/stock-opkg-database.sha256"
fi
rm -rf -- "${rootfs}/usr/lib/opkg/info"
mkdir -p "${rootfs}/usr/lib/opkg/info"
: > "$status_file"
rm -rf -- "${rootfs}/usr/lib/opkg/lists"
rm -f -- "${rootfs}/etc/opkg/distfeeds.conf" \
	"${rootfs}/etc/opkg/customfeeds.conf" "${rootfs}/etc/opkg/feeds.conf"
printf '%s\n' \
	'This candidate does not claim that the stock package database is reconciled.' \
	'Only packages embedded by this build are registered. Runtime package upgrades are unsupported.' \
	> "${rootfs}/usr/share/sbe1v1k-stockabi/OPKG_BASE_STATUS_INCOMPLETE"
if [ -z "$base_opkg_root" ]; then
	printf '%s\n' \
		'This image was built without base-package reconciliation evidence.' \
		'Do not use it for first-flash or device testing.' \
		> "${rootfs}/usr/share/sbe1v1k-stockabi/DO_NOT_FLASH_UNRECONCILED"
fi
printf '%s\n' \
	'candidate: stock package database and payload versions are not reconciled' \
	'runtime opkg feeds and luci-app-opkg are intentionally omitted' \
	> "${run_dir}/audit/BUILD-LIMITATION.txt"
[ -n "$base_opkg_root" ] || \
	printf '%s\n' 'offline inspection only: not eligible for first-flash or device testing' \
		>> "${run_dir}/audit/BUILD-LIMITATION.txt"
[ "$opkg_ui_requested" -eq 0 ] || \
	printf '%s\n' 'luci-app-opkg requested by caller but omitted' \
		>> "${run_dir}/audit/BUILD-LIMITATION.txt"
[ -z "$base_opkg_root" ] || \
	printf '%s\n' 'base opkg root used only as read-only payload-presence evidence' \
		>> "${run_dir}/audit/BUILD-LIMITATION.txt"

log 'checking package dependency declarations'
: > "${run_dir}/audit/unresolved-package-dependencies.txt"
for package in "${requested_packages[@]}"; do
	depends="$(control_field "${control_by_name[$package]}" Depends)"
	[ -n "$depends" ] || continue
	IFS=',' read -r -a dependency_groups <<< "$depends"
	for dependency_group in "${dependency_groups[@]}"; do
		dependency_group="$(printf '%s' "$dependency_group" | sed -E 's/\([^)]*\)//g')"
		IFS='|' read -r -a alternatives <<< "$dependency_group"
		satisfied=0
		for dependency in "${alternatives[@]}"; do
			dependency="$(printf '%s' "$dependency" | tr -d '[:space:]')"
			dependency=${dependency#+}
			[ -n "$dependency" ] || continue
			provider="${provides_name[$dependency]-}"
			base_provider="${base_provider_name[$dependency]-}"
			if [ -n "${selected_name[$dependency]+x}" ] || \
				[ -n "${verified_base_package[$dependency]+x}" ] || \
				{ [ -n "$provider" ] && \
					[ -n "${selected_name[$provider]+x}" ]; } || \
				{ [ -n "$base_provider" ] && \
					[ -n "${verified_base_package[$base_provider]+x}" ]; }; then
				satisfied=1
				break
			fi
		done
		if [ "$satisfied" -ne 1 ]; then
			printf '%s: %s\n' "$package" "$dependency_group" \
				>> "${run_dir}/audit/unresolved-package-dependencies.txt"
		fi
	done
done
if [ -s "${run_dir}/audit/unresolved-package-dependencies.txt" ]; then
	if [ -z "$base_opkg_root" ] && [ "$allow_incomplete_opkg_db" -eq 1 ]; then
		warn 'package metadata has unresolved stock dependencies; candidate build will still enforce its actual ELF closure'
		printf '%s\n' 'package metadata contains unresolved stock dependencies; see audit report' \
			>> "${run_dir}/audit/BUILD-LIMITATION.txt"
	else
		die "unresolved dependencies are not proven present in stock payload; see ${run_dir}/audit/unresolved-package-dependencies.txt"
	fi
fi

log 'preflighting package payload collisions and ABI boundaries'
declare -A payload_owner=()
declare -A payload_kind=()
: > "${run_dir}/audit/package-overwrites.txt"
: > "${run_dir}/audit/package-payload-paths.txt"
for package in "${requested_packages[@]}"; do
	data_dir="${unpack_by_name[$package]}/data"
	while IFS= read -r relative; do
		[ -n "$relative" ] || continue
		safe_relative_path "$relative" || die "unsafe extracted path in $package: $relative"
		printf '%s\n' "$relative" >> "${run_dir}/audit/package-payload-paths.txt"
		if matches_patterns "$relative" "${protected_patterns[@]}"; then
			die "package $package touches protected stock ABI path: $relative"
		fi
			is_sensitive_identity_path "$relative" && \
				die "package $package attempts to embed an identity or credential path: $relative"
			case "$relative" in
			etc/opkg/distfeeds.conf | etc/opkg/customfeeds.conf | etc/opkg/feeds.conf | \
			usr/lib/opkg/lists | usr/lib/opkg/lists/* | \
			usr/lib/lua/luci/controller/admin/thread.lua | usr/lib/lua/luci/view/admin_thread | \
			usr/lib/lua/luci/view/admin_thread/*)
				die "package $package attempts to reintroduce a disabled management path: $relative"
				;;
			esac
		current_kind=file
		[ -d "${data_dir}/${relative}" ] && [ ! -L "${data_dir}/${relative}" ] && \
			current_kind=directory
		if [ -n "${payload_owner[$relative]+x}" ] && \
			{ [ "${payload_kind[$relative]}" != directory ] || [ "$current_kind" != directory ]; }; then
			die "package payload collision at $relative: ${payload_owner[$relative]} and $package"
		fi
		payload_owner[$relative]=$package
		payload_kind[$relative]=$current_kind
		if [ -e "${rootfs}/${relative}" ] || [ -L "${rootfs}/${relative}" ]; then
			if [ -d "${data_dir}/${relative}" ] && [ -d "${rootfs}/${relative}" ] && \
				[ ! -L "${rootfs}/${relative}" ]; then
				continue
			fi
			matches_patterns "$relative" "${overwrite_patterns[@]}" || \
				die "package $package would overwrite an unaudited stock path: $relative"
			printf '%s\t%s\n' "$package" "$relative" >> "${run_dir}/audit/package-overwrites.txt"
		fi
	done < <(cd "$data_dir" && find . -mindepth 1 -printf '%P\n' | sort)
done
sort -u -o "${run_dir}/audit/package-payload-paths.txt" \
	"${run_dir}/audit/package-payload-paths.txt"

log 'merging selected package payloads without executing maintainer scripts'
for package in "${requested_packages[@]}"; do
	entry_dir=${unpack_by_name[$package]}
	data_dir="${entry_dir}/data"
	control=${control_by_name[$package]}
	rsync -a -- "$data_dir/" "$rootfs/"
	install -m 0644 "$control" "${rootfs}/usr/lib/opkg/info/${package}.control"
	for control_script in conffiles preinst postinst prerm postrm; do
		mapfile -t script_matches < <(find "${entry_dir}/control" -maxdepth 2 -type f \
			-name "$control_script" -print)
		if [ "${#script_matches[@]}" -eq 1 ]; then
			script_mode=0755
			[ "$control_script" = conffiles ] && script_mode=0644
			install -m "$script_mode" "${script_matches[0]}" \
				"${rootfs}/usr/lib/opkg/info/${package}.${control_script}"
		elif [ "${#script_matches[@]}" -gt 1 ]; then
			die "multiple $control_script files in package: $package"
		fi
	done
	(cd "$data_dir" && find . -mindepth 1 -printf '/%P\n' | sort) \
		> "${rootfs}/usr/lib/opkg/info/${package}.list"
	awk '!/^Status:[[:space:]]/' "$control" >> "$status_file"
	printf 'Status: install user installed\n\n' >> "$status_file"
done
cp "${run_dir}/audit/ipks.sha256" \
	"${rootfs}/usr/share/sbe1v1k-stockabi/installed-ipks.sha256"

log 'preflighting and applying the repository-owned audited overlay'
preflight_overlay_tree "$audited_overlay" \
	"${run_dir}/audit/audited-overlay.sha256" 0
rsync -a -- "$audited_overlay/" "$rootfs/"

if [ -n "$overlay_dir" ]; then
	log 'preflighting and applying the optional noncritical overlay'
	preflight_overlay_tree "$overlay_dir" \
		"${run_dir}/audit/additional-overlay.sha256" 1
	rsync -a -- "$overlay_dir/" "$rootfs/"
else
	: > "${run_dir}/audit/additional-overlay.sha256"
fi

log 'installing generated-at-first-boot credentials and fixed management policy'
[ -d "${rootfs}/etc/dropbear" ] && [ ! -L "${rootfs}/etc/dropbear" ] || \
	die '/etc/dropbear is missing or is a symlink'
find "$rootfs" -xdev -name authorized_keys \( -type f -o -type l \) -delete
find "${rootfs}/etc/dropbear" -xdev \( -type f -o -type l \) \
	-name 'dropbear_*_host_key' -delete
expected_authorized_keys="${run_dir}/input/authorized_keys"
printf '%s\n' "$public_key_line" > "$expected_authorized_keys"
install -m 0600 "$expected_authorized_keys" \
	"${rootfs}/etc/dropbear/authorized_keys"
ssh-keygen -lf "$admin_public_key" > "${run_dir}/audit/admin-public-key.fingerprint"

rm -f -- "${rootfs}/sbin/reboot"
ln -s /bin/busybox "${rootfs}/sbin/reboot"
chmod 0600 "${rootfs}/etc/shadow" "${rootfs}/etc/crontabs/root" \
	"${rootfs}/etc/dropbear/authorized_keys"
chmod 0644 "${rootfs}/etc/passwd" "${rootfs}/etc/group" \
	"${rootfs}/etc/sysctl.conf" "${rootfs}/etc/sysupgrade.conf" \
	"${rootfs}/etc/config/"*
chmod 0700 "${rootfs}/etc/dropbear"
chmod 0755 \
	"${rootfs}/etc/firewall.user" \
	"${rootfs}/etc/init.d/firewall" \
	"${rootfs}/etc/init.d/ssh-hostkey-fingerprint" \
	"${rootfs}/etc/udhcpc.user" \
	"${rootfs}/etc/ppp/ip-up" \
	"${rootfs}/etc/ppp/ip-down" \
	"${rootfs}/sbin/sysupgrade" \
	"${rootfs}/lib/upgrade/do_stage2" \
	"${rootfs}/lib/upgrade/platform.sh" \
	"${rootfs}/lib/upgrade/emmc.sh" \
	"${rootfs}/lib/preinit/01_default_configs" \
	"${rootfs}/lib/preinit/42_mount_askey_partition" \
	"${rootfs}/lib/preinit/80_mount_root"

assert_rootfs_policy "$rootfs" "${run_dir}/audit/rootfs-policy-before-rc"

service_value() {
	local init_script=$1
	local variable=$2
	sed -n -E "s/^[[:space:]]*${variable}[[:space:]]*=[[:space:]]*['\"]?([0-9]+)['\"]?.*/\\1/p" \
		"$init_script" | head -n 1
}

enable_service() {
	local service=$1
	local init_script="${rootfs}/etc/init.d/${service}"
	[ -f "$init_script" ] || die "required init service is missing: $service"
	local start stop
	start="$(service_value "$init_script" START)"
	stop="$(service_value "$init_script" STOP)"
	[[ "$start" =~ ^[0-9]+$ ]] || die "service $service has no numeric START value"
	mkdir -p "${rootfs}/etc/rc.d"
	while IFS= read -r -d '' old_link; do
		rm -f -- "$old_link"
	done < <(find "${rootfs}/etc/rc.d" -maxdepth 1 -type l \
		-lname "*init.d/${service}" -print0)
	ln -sfn "../init.d/${service}" "${rootfs}/etc/rc.d/S${start}${service}"
	if [[ "$stop" =~ ^[0-9]+$ ]]; then
		ln -sfn "../init.d/${service}" "${rootfs}/etc/rc.d/K${stop}${service}"
	fi
}

mapfile -t allowed_services < <(read_list "$enabled_services")
mapfile -t disabled_names < <(read_list "$disabled_services")
declare -A allowed_service_name=()
for service in "${allowed_services[@]}"; do
	[[ "$service" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid allowed service: $service"
	[ -z "${allowed_service_name[$service]+x}" ] || die "duplicate allowed service: $service"
	[ "$service" != qca-nss-ppe-ds ] || die 'qca-nss-ppe-ds must retain its stock no-rc-link behavior'
	allowed_service_name[$service]=1
done
for service in "${disabled_names[@]}"; do
	[[ "$service" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid disabled service: $service"
	[ -z "${allowed_service_name[$service]+x}" ] || \
		die "service appears in both allow and disable lists: $service"
done

log 'rebuilding rc.d exclusively from the audited service allowlist'
rm -rf -- "${rootfs}/etc/rc.d"
mkdir -p "${rootfs}/etc/rc.d"
for service in "${allowed_services[@]}"; do
	enable_service "$service"
	if grep -Eqi '/usr/opensync|(^|[^[:alnum:]_])opensync([^[:alnum:]_]|$)' \
		"${rootfs}/etc/init.d/${service}"; then
		die "enabled service still depends on removed OpenSync control plane: $service"
	fi
done
collect_qca_rc_manifest "$rootfs" "${run_dir}/audit/final-qca-rc.txt"
cmp -s "${run_dir}/audit/stock-qca-rc.txt" \
	"${run_dir}/audit/final-qca-rc.txt" || \
	die 'QCA/Wi-Fi/hardware rc.d ordering changed from stock'

log 'checking newly merged ELF dependency closure'
: > "${run_dir}/audit/elf-needed.txt"
while IFS= read -r relative; do
	file="${rootfs}/${relative}"
	[ -f "$file" ] && [ ! -L "$file" ] || continue
	readelf -h "$file" >/dev/null 2>&1 || continue
	machine="$(readelf -h "$file" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
	case "$machine" in
	*AArch64*) ;;
	*) die "non-AArch64 ELF in management payload: $relative ($machine)" ;;
	esac
	interpreter="$(readelf -l "$file" 2>/dev/null | \
		sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p' | head -n 1)"
	if [ -n "$interpreter" ] && [ ! -e "${rootfs}${interpreter}" ]; then
		die "missing ELF interpreter for $relative: $interpreter"
	fi
	while IFS= read -r needed; do
		[ -n "$needed" ] || continue
		printf '%s\t%s\n' "$relative" "$needed" >> "${run_dir}/audit/elf-needed.txt"
		found=0
		for libdir in lib usr/lib usr/local/lib; do
			if [ -e "${rootfs}/${libdir}/${needed}" ]; then
				found=1
				break
			fi
		done
		[ "$found" -eq 1 ] || die "missing shared library for $relative: $needed"
	done < <(readelf -d "$file" 2>/dev/null | \
		sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
done < "${run_dir}/audit/package-payload-paths.txt"

while IFS= read -r relative; do
	safe_relative_path "$relative" || die "unsafe required path: $relative"
	[ -e "${rootfs}/${relative}" ] || [ -L "${rootfs}/${relative}" ] || \
		die "required final rootfs path is missing: $relative"
done < <(read_list "$required_paths")

for service in "${disabled_names[@]}"; do
	if find "${rootfs}/etc/rc.d" -maxdepth 1 -type l -lname "*init.d/${service}" | grep -q .; then
		die "disabled service still has an rc.d link: $service"
	fi
done

if find "${rootfs}/etc/dropbear" -xdev -type f -name 'dropbear_*_host_key' -size +0c \
	2>/dev/null | grep -q .; then
	die 'final rootfs contains a pre-generated Dropbear host key'
fi

assert_rootfs_policy "$rootfs" "${run_dir}/audit/rootfs-policy-before-pack"

collect_protected_manifest "$rootfs" "${run_dir}/audit/final-abi-before-pack.sha256"
cmp -s "${run_dir}/audit/stock-abi.sha256" \
	"${run_dir}/audit/final-abi-before-pack.sha256" || \
	die 'a protected stock ABI file changed during rootfs construction'

log 'repacking xz SquashFS with stock-compatible parameters'
jobs="${MKSQUASHFS_JOBS:-$(nproc)}"
case "$jobs" in
	'' | *[!0-9]* | 0) die 'MKSQUASHFS_JOBS must be a positive integer' ;;
esac
rm -f -- "${rootfs}/dev/console"
mksquashfs "$rootfs" "${run_dir}/output/root.squashfs" \
	-comp xz -b 262144 -noappend -no-xattrs -no-tailends -all-root \
	-p 'dev/console c 0600 0 0 5 1' \
	-processors "$jobs" >/dev/null
cp "${run_dir}/output/root.squashfs" "${run_dir}/output/root.padded"
truncate -s %65536 "${run_dir}/output/root.padded"
rootfs_size="$(stat -c %s "${run_dir}/output/root.padded")"
[ "$rootfs_size" -le "$rootfs_limit" ] || \
	die "rootfs exceeds p27 safety limit: $rootfs_size > $rootfs_limit"
[ "$((rootfs_size % 65536))" -eq 0 ] || die 'rootfs is not aligned to 64 KiB'
unsquashfs -s "${run_dir}/output/root.padded" > "${run_dir}/audit/final-squashfs-info.txt"

metadata="${run_dir}/output/metadata.json"
if [ -n "$base_opkg_root" ]; then
	image_version=19.07-SNAPSHOT-QSDK12-stockabi-candidate
else
	image_version=19.07-SNAPSHOT-QSDK12-stockabi-candidate-unreconciled-do-not-flash
fi
jq -n \
	--arg image_version "$image_version" \
	'{
		metadata_version: "1.1",
		compat_version: "1.0",
		supported_devices: [
			"askey,sbe1v1k",
			"qcom,ipq9574-ap-al02-c4",
			"askey,rtq7300t-rev0"
		],
		version: {
			dist: "OpenWrt",
			version: $image_version,
			revision: "NHSS.QSDK.12.2.r6-00023-P-1",
			target: "qualcommbe/ipq95xx",
			board: "askey_sbe1v1k"
		}
	}' > "$metadata"

candidate="${run_dir}/output/sbe1v1k-stockabi-sysupgrade.bin"
log 'creating standard sysupgrade tar and appending fwtool metadata'
TOPDIR="$openwrt_tree" SOURCE_DATE_EPOCH="$source_date_epoch" \
	sh "$sysupgrade_tar" \
	--board "$board" \
	--kernel "${run_dir}/input/kernel.itb" \
	--rootfs "${run_dir}/output/root.padded" \
	"$candidate" >/dev/null
"$fwtool" -I "$metadata" "$candidate"

log 'performing strict offline verification of the finished image'
tar -tf "$candidate" > "${run_dir}/audit/sysupgrade-members.txt"
[ "$(wc -l < "${run_dir}/audit/sysupgrade-members.txt")" -eq 4 ] || \
	die 'sysupgrade tar must contain exactly four members without duplicates'
actual_members="$(sort "${run_dir}/audit/sysupgrade-members.txt")"
expected_members="$(printf '%s\n' \
	"${board_dir}/" \
	"${board_dir}/CONTROL" \
	"${board_dir}/kernel" \
	"${board_dir}/root" | sort)"
[ "$actual_members" = "$expected_members" ] || die 'unexpected sysupgrade tar members'

tar -xf "$candidate" -C "${run_dir}/verify" \
	"${board_dir}/CONTROL" "${board_dir}/kernel" "${board_dir}/root"
control_value="$(tr -d '\r\n' < "${run_dir}/verify/${board_dir}/CONTROL")"
[ "$control_value" = "BOARD=${board}" ] || die "unexpected CONTROL value: $control_value"
[ "$(sha256sum "${run_dir}/verify/${board_dir}/kernel" | awk '{print $1}')" = \
	"$expected_fit_sha256" ] || die 'final sysupgrade kernel differs from the audited stock FIT'
[ "$(sha256sum "${run_dir}/verify/${board_dir}/root" | awk '{print $1}')" = \
	"$(sha256sum "${run_dir}/output/root.padded" | awk '{print $1}')" ] || \
	die 'final sysupgrade root member differs from the verified padded rootfs'
[ "$(od -An -tx1 -N 4 "${run_dir}/verify/${board_dir}/root" | tr -d ' \n')" = 68737173 ] || \
	die 'final sysupgrade root member is not SquashFS'

"$fwtool" -i "${run_dir}/audit/extracted-metadata.json" "$candidate"
jq -e --arg image_version "$image_version" '
	.metadata_version == "1.1" and
	.compat_version == "1.0" and
	(.supported_devices == [
		"askey,sbe1v1k",
		"qcom,ipq9574-ap-al02-c4",
		"askey,rtq7300t-rev0"
	]) and
	.version.version == $image_version and
	.version.target == "qualcommbe/ipq95xx" and
	.version.board == "askey_sbe1v1k"
' "${run_dir}/audit/extracted-metadata.json" >/dev/null || die 'fwtool metadata verification failed'

final_root="${run_dir}/verify/final-root"
extract_squashfs_verified "${run_dir}/verify/${board_dir}/root" \
	"$final_root" roundtrip-rootfs
collect_protected_manifest "$final_root" "${run_dir}/audit/final-abi.sha256"
cmp -s "${run_dir}/audit/stock-abi.sha256" "${run_dir}/audit/final-abi.sha256" || \
	die 'protected stock ABI changed after SquashFS round trip'
assert_rootfs_policy "$final_root" "${run_dir}/audit/rootfs-policy-roundtrip"
collect_qca_rc_manifest "$final_root" "${run_dir}/audit/roundtrip-qca-rc.txt"
cmp -s "${run_dir}/audit/stock-qca-rc.txt" \
	"${run_dir}/audit/roundtrip-qca-rc.txt" || \
	die 'QCA/Wi-Fi/hardware rc.d ordering changed after SquashFS round trip'
while IFS= read -r relative; do
	[ -e "${final_root}/${relative}" ] || [ -L "${final_root}/${relative}" ] || \
		die "required path missing after SquashFS round trip: $relative"
done < <(read_list "$required_paths")

for forbidden in \
	'mmcblk0p20.img' 'mmcblk0p21.img' 'mmcblk0p23.img' 'mmcblk0p24.img' \
	'mmcblk0p36.img' 'mmcblk0p37.img' 'mmcblk0p40.img' 'mmcblk0p43.img'; do
	if find "$final_root" -xdev -type f -name "$forbidden" | grep -q .; then
		die "identity or non-root partition image leaked into rootfs: $forbidden"
	fi
done

sha256sum "$candidate" | sed "s#  .*#  $(basename -- "$output")#" \
	> "${run_dir}/audit/output.sha256"
printf '%s\n' \
	"kernel_bytes=$fit_size" \
	"root_bytes=$rootfs_size" \
	"source_date_epoch=$source_date_epoch" \
	"board=$board" \
	"qsdk_release=NHSS.QSDK.12.2.r6-00023-P-1" \
	> "${run_dir}/audit/build-summary.txt"

output_tmp="${output}.tmp.$$"
audit_tmp="${output}.audit.tmp.$$"
install -m 0644 "$candidate" "$output_tmp"
mkdir -p "$audit_tmp"
rsync -a -- "${run_dir}/audit/" "$audit_tmp/"
mv -- "$output_tmp" "$output"
mv -- "$audit_tmp" "${output}.audit"
(
	cd "$output_parent"
	sha256sum "$(basename -- "$output")" > "$(basename -- "$output").sha256"
)

log "completed: $output"
printf 'SHA-256: %s\n' "$(sha256sum "$output" | awk '{print $1}')"
printf 'Audit: %s\n' "${output}.audit"
warn 'this output is marked candidate until stock package payload/version reconciliation is locked'
