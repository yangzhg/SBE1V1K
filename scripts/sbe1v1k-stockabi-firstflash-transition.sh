#!/bin/sh

# Run this only on the currently installed SBE1V1K OpenWrt 6.18 system.
# It temporarily bind-mounts the audited stock-ABI writer over the generic
# upgrade helpers.  Nothing is persisted; successful flash mode leaves the
# binds in place until sysupgrade pivots to RAM and reboots.

default_bundle=/tmp/sbe1v1k-stockabi-transition
recovery_size=758532
recovery_sha256=2aad05c1ee2574874a4570367a090ebf9af66cc02d23db91365ed0b83ef5d702
mode=${1:-}
image=${2:-}
expected_image_sha256=${3:-}
bundle=${4:-$default_bundle}

fail() {
	echo "firstflash: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage:
  sbe1v1k-stockabi-firstflash-transition.sh --test  IMAGE SHA256 [BUNDLE]
  sbe1v1k-stockabi-firstflash-transition.sh --flash IMAGE SHA256 [BUNDLE]
  sbe1v1k-stockabi-firstflash-transition.sh --cleanup

BUNDLE defaults to /tmp/sbe1v1k-stockabi-transition and must contain:
  platform.sh emmc.sh do_stage2 SHA256SUMS

--test installs temporary bind mounts, runs the current system's sysupgrade
validation with the audited writer, and then removes the binds.

--flash repeats the same validation and then executes sysupgrade -n.  The
temporary files and bind mounts deliberately remain until reboot so stage2
cannot race back to the generic writer.
EOF
}

targets='/lib/upgrade/platform.sh /lib/upgrade/emmc.sh /lib/upgrade/do_stage2'

is_mounted() {
	local target=$1
	awk -v target="$target" '$5 == target { found = 1 } END { exit(found ? 0 : 1) }' \
		/proc/self/mountinfo
}

cleanup_binds() {
	local target name
	for target in /lib/upgrade/do_stage2 /lib/upgrade/platform.sh /lib/upgrade/emmc.sh; do
		if is_mounted "$target"; then
			name=${target##*/}
			[ -f "$bundle/$name" ] && cmp -s "$bundle/$name" "$target" || return 1
			umount "$target" >/dev/null 2>&1 || return 1
		fi
	done
}

if [ "$mode" = --cleanup ]; then
	[ "$(id -u)" = 0 ] || fail 'must run as root'
	cleanup_binds || fail 'could not remove all transition bind mounts'
	echo 'firstflash: transition bind mounts removed'
	exit 0
fi

case "$mode" in
--test | --flash) ;;
-h | --help)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 1
	;;
esac

[ "$(id -u)" = 0 ] || fail 'must run as root'
[ -n "$image" ] && [ -f "$image" ] && [ -r "$image" ] || fail 'image is not readable'
image="$(readlink -f "$image")" || fail 'could not resolve image path'
case "$image" in
/tmp/*) ;;
*) fail 'image must be stored below /tmp on the router' ;;
esac

[ "${#expected_image_sha256}" -eq 64 ] || fail 'expected image SHA256 must contain 64 characters'
case "$expected_image_sha256" in
'' | *[!0-9a-f]*) fail 'expected image SHA256 must be lowercase hexadecimal' ;;
esac

[ -d "$bundle" ] || fail "bundle directory is missing: $bundle"
bundle="$(readlink -f "$bundle")" || fail 'could not resolve bundle path'
case "$bundle" in
/tmp/*) ;;
*) fail 'bundle must be stored below /tmp on the router' ;;
esac

for command in awk cat cmp df find grep head id mount readlink sha256sum sh umount uname wc; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
[ -x /usr/bin/fwtool ] || fail 'current system lacks /usr/bin/fwtool'
[ -x /usr/bin/jshn ] || fail 'current system lacks /usr/bin/jshn'
[ -r /usr/share/libubox/jshn.sh ] || fail 'current system lacks jshn.sh'

[ -r /etc/openwrt_release ] || fail 'OpenWrt release information is missing'
. /etc/openwrt_release
[ "${DISTRIB_TARGET:-}" = qualcommbe/ipq95xx ] || \
	fail "unexpected current target: ${DISTRIB_TARGET:-unknown}"
case "$(uname -r)" in
6.18.*) ;;
*) fail "transition helper only accepts the current Linux 6.18 system: $(uname -r)" ;;
esac

. /lib/functions.sh
. /lib/functions/system.sh
. /lib/upgrade/common.sh
case "$(board_name)" in
askey,sbe1v1k) ;;
*) fail "unexpected current board: $(board_name)" ;;
esac
[ -n "$(rootfs_type)" ] || fail 'current system is not running from a mounted rootfs'
[ -n "${RAM_ROOT:-}" ] || fail 'current upgrade stack did not define RAM_ROOT'
case "$RAM_ROOT" in
/tmp/*) ;;
*) fail "unexpected RAM_ROOT outside /tmp: $RAM_ROOT" ;;
esac
if [ -e "$RAM_ROOT" ] || [ -L "$RAM_ROOT" ]; then
	[ -d "$RAM_ROOT" ] && [ ! -L "$RAM_ROOT" ] || fail 'RAM_ROOT is not a regular directory'
	ram_root_entry="$(find "$RAM_ROOT" -mindepth 1 -print -quit 2>/dev/null)" || \
		fail "could not inspect RAM_ROOT: $RAM_ROOT"
	[ -z "$ram_root_entry" ] || \
		fail "RAM_ROOT is not empty; reboot before retrying: $RAM_ROOT"
fi

[ -r /lib/upgrade/stage2 ] || fail 'current stage2 script is missing'
for token in 'RAMFS_COPY_BIN' 'RAMFS_COPY_DATA' '/lib/upgrade/*.sh' \
	'/lib/upgrade/do_stage2'; do
	grep -Fq "$token" /lib/upgrade/stage2 || \
		fail "current stage2 lacks the required RAMFS copy contract: $token"
done
for token in 'COMMAND=/lib/upgrade/do_stage2' 'install_bin /sbin/upgraded' \
	'ubus call system sysupgrade'; do
	grep -Fq "$token" /sbin/sysupgrade || \
		fail "current sysupgrade lacks the required stage2 contract: $token"
done

[ -b /dev/mmcblk0p40 ] || fail 'expected p40 recovery partition is missing'
[ "$(cat /sys/class/block/mmcblk0p40/partition 2>/dev/null)" = 40 ] || \
	fail 'recovery device is not partition 40'
[ "$(cat /sys/class/block/mmcblk0p40/size 2>/dev/null)" = 65536 ] || \
	fail 'recovery partition has an unexpected capacity'
actual_recovery_sha256="$(head -c "$recovery_size" /dev/mmcblk0p40 | sha256sum)" || \
	fail 'could not hash the recovery chainloader'
actual_recovery_sha256=${actual_recovery_sha256%% *}
[ "$actual_recovery_sha256" = "$recovery_sha256" ] || \
	fail 'p40 does not contain the tested recovery chainloader payload'

manifest="$bundle/SHA256SUMS"
[ -f "$manifest" ] || fail 'transition SHA256SUMS is missing'
[ "$(wc -l < "$manifest")" -eq 3 ] || fail 'transition SHA256SUMS must contain exactly three records'
for name in platform.sh emmc.sh do_stage2; do
	[ -f "$bundle/$name" ] && [ ! -L "$bundle/$name" ] || fail "bundle file is invalid: $name"
	[ "$(awk -v name="$name" '$2 == name { count++ } END { print count + 0 }' "$manifest")" -eq 1 ] || \
		fail "manifest lacks one exact $name record"
	sh -n "$bundle/$name" || fail "bundle shell syntax is invalid: $name"
done
(cd "$bundle" && sha256sum -c SHA256SUMS) || fail 'transition bundle hash check failed'

actual_image_sha256="$(sha256sum "$image")"
actual_image_sha256=${actual_image_sha256%% *}
[ "$actual_image_sha256" = "$expected_image_sha256" ] || fail 'router image hash differs from the computer hash'

image_bytes="$(wc -c < "$image")"
case "$image_bytes" in
'' | *[!0-9]*) fail 'could not determine image size' ;;
esac
[ "$image_bytes" -ge 1048576 ] && [ "$image_bytes" -le 146800640 ] || \
	fail 'image size is outside the expected sysupgrade range'
required_tmp_kib=$(((image_bytes * 3 + 1023) / 1024))
[ "$required_tmp_kib" -ge 262144 ] || required_tmp_kib=262144
available_tmp_kib="$(df -kP /tmp | awk 'NR > 1 { value = $4 } END { print value }')"
case "$available_tmp_kib" in
'' | *[!0-9]*) fail 'could not determine available /tmp space' ;;
esac
[ "$available_tmp_kib" -ge "$required_tmp_kib" ] || \
	fail "insufficient /tmp space: need ${required_tmp_kib} KiB, have ${available_tmp_kib} KiB"

for target in $targets; do
	[ -f "$target" ] || fail "current upgrade target is missing: $target"
	is_mounted "$target" && fail "transition target is already a mount point: $target"
done

chmod 0755 "$bundle/platform.sh" "$bundle/emmc.sh" "$bundle/do_stage2" || \
	fail 'could not make transition helpers executable'

activated=0
transition_cleanup() {
	if [ "$activated" -eq 1 ]; then
		cleanup_binds
	fi
}
transition_signal() {
	trap - EXIT HUP INT TERM
	transition_cleanup
	exit 130
}
trap transition_cleanup EXIT
trap transition_signal HUP INT TERM

mount -o bind "$bundle/emmc.sh" /lib/upgrade/emmc.sh || fail 'could not bind emmc.sh'
activated=1
mount -o bind "$bundle/platform.sh" /lib/upgrade/platform.sh || fail 'could not bind platform.sh'
mount -o bind "$bundle/do_stage2" /lib/upgrade/do_stage2 || fail 'could not bind do_stage2'

for target in $targets; do
	name=${target##*/}
	is_mounted "$target" || fail "bind mount is not visible: $target"
	cmp -s "$bundle/$name" "$target" || fail "bound file differs from bundle: $target"
done
[ -x /lib/upgrade/do_stage2 ] || fail 'bound do_stage2 is not executable'

/sbin/sysupgrade -T -n "$image" || fail 'strict transition validation failed'

actual_image_sha256="$(sha256sum "$image")"
actual_image_sha256=${actual_image_sha256%% *}
[ "$actual_image_sha256" = "$expected_image_sha256" ] || fail 'image changed after validation'

if [ "$mode" = --test ]; then
	cleanup_binds || fail 'validation passed but bind cleanup failed'
	activated=0
	trap - EXIT HUP INT TERM
	echo 'firstflash: strict validation passed; no partition was written'
	exit 0
fi

# Do not install an EXIT cleanup in flash mode.  The current sysupgrade process
# may return from ubus before stage2 has copied the bound files into RAM.
activated=0
trap - EXIT HUP INT TERM
echo 'firstflash: strict validation passed; starting mandatory no-config upgrade'
exec /sbin/sysupgrade -n -v "$image"
