PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='/usr/bin/fwtool /usr/bin/jshn uci flock cmp head hexdump sort wc sha256sum'
RAMFS_COPY_DATA='/usr/libexec/validate_firmware_image'

SBE1V1K_IMAGE_DIR=sysupgrade-askey_sbe1v1k
SBE1V1K_KERNEL_SHA256=852030dc9e5d0b9e56845efd3a8decbde6dd93a7d779c84230331e244bfbb1bf
SBE1V1K_IMAGE_VERSION=19.07-SNAPSHOT-QSDK12-stockabi-candidate
SBE1V1K_RECOVERY_SIZE=758532
SBE1V1K_RECOVERY_SHA256=2aad05c1ee2574874a4570367a090ebf9af66cc02d23db91365ed0b83ef5d702

platform_pre_upgrade() {
	[ -n "$(rootfs_type)" ] || {
		echo 'Refusing live-root upgrade: RAMFS pivot was not prepared.' >&2
		exit 1
	}
}

sbe1v1k_supported_board() {
	case "$(board_name)" in
	askey,sbe1v1k | qcom,ipq9574-ap-al02-c4 | askey,rtq7300t-rev0)
		return 0
		;;
	esac
	return 1
}

sbe1v1k_validate_metadata() {
	local image="$1"
	local metadata_file="/tmp/sbe1v1k-fwtool-metadata.$$"
	local metadata_json image_version image_revision image_target image_board valid

	rm -f "$metadata_file"
	/usr/bin/fwtool -i "$metadata_file" "$image" >/dev/null 2>&1 || {
		rm -f "$metadata_file"
		return 1
	}
	metadata_json="$(cat "$metadata_file")"
	rm -f "$metadata_file"
	json_load "$metadata_json" || return 1
	json_select version || return 1
	json_get_var image_version version
	json_get_var image_revision revision
	json_get_var image_target target
	json_get_var image_board board
	json_select ..
	valid=0
	[ "$image_version" = "$SBE1V1K_IMAGE_VERSION" ] && \
		[ "$image_revision" = NHSS.QSDK.12.2.r6-00023-P-1 ] && \
		[ "$image_target" = qualcommbe/ipq95xx ] && \
		[ "$image_board" = askey_sbe1v1k ] && valid=1
	[ "$valid" -eq 1 ]
}

sbe1v1k_validate_payloads() {
	local image="$1"
	local prefix="/tmp/sbe1v1k-image-check.$$"
	local control_file="${prefix}.control"
	local kernel_file="${prefix}.kernel"
	local root_file="${prefix}.root"
	local control kernel_size root_size kernel_magic root_magic kernel_hash valid

	rm -f "$control_file" "$kernel_file" "$root_file"
	tar xf "$image" "${SBE1V1K_IMAGE_DIR}/CONTROL" -O > "$control_file" 2>/dev/null || {
		rm -f "$control_file" "$kernel_file" "$root_file"
		return 1
	}
	tar xf "$image" "${SBE1V1K_IMAGE_DIR}/kernel" -O > "$kernel_file" 2>/dev/null || {
		rm -f "$control_file" "$kernel_file" "$root_file"
		return 1
	}
	tar xf "$image" "${SBE1V1K_IMAGE_DIR}/root" -O > "$root_file" 2>/dev/null || {
		rm -f "$control_file" "$kernel_file" "$root_file"
		return 1
	}
	control="$(cat "$control_file")"
	kernel_size="$(wc -c < "$kernel_file")"
	root_size="$(wc -c < "$root_file")"
	kernel_magic="$(hexdump -v -n 4 -e '4/1 "%02x"' "$kernel_file")"
	root_magic="$(hexdump -v -n 4 -e '4/1 "%02x"' "$root_file")"
	kernel_hash="$(sha256sum "$kernel_file")"
	kernel_hash="${kernel_hash%% *}"
	valid=0
	[ "$control" = 'BOARD=askey_sbe1v1k' ] && \
		[ "$kernel_magic" = d00dfeed ] && \
		[ "$root_magic" = 68737173 ] && \
		[ "$kernel_hash" = "$SBE1V1K_KERNEL_SHA256" ] && \
		[ "$kernel_size" -ge 64 ] && [ "$kernel_size" -le 7335936 ] && \
		[ "$root_size" -ge 4096 ] && [ "$root_size" -le 127860736 ] && \
		[ $((root_size % 65536)) -eq 0 ] && valid=1
	rm -f "$control_file" "$kernel_file" "$root_file"
	[ "$valid" -eq 1 ]
}

sbe1v1k_partition_is() {
	local device="$1"
	local expected="$2"
	[ -b "$device" ] || return 1
	[ "$(cat "/sys/class/block/${device##*/}/partition" 2>/dev/null)" = "$expected" ]
}

sbe1v1k_find_unique_partition() {
	local label="$1"
	local expected_part="$2"
	local candidate partname found helper count expected_sectors block_name
	case "$expected_part" in
	25) expected_sectors=14336 ;;
	27) expected_sectors=249856 ;;
	29) expected_sectors=1048576 ;;
	40) expected_sectors=65536 ;;
	*) return 1 ;;
	esac
	found=
	count=0
	for candidate in /sys/block/mmcblk*/mmcblk*p*; do
		[ -r "$candidate/uevent" ] || continue
		partname="$(sed -n 's/^PARTNAME=//p' "$candidate/uevent")"
		[ "$partname" = "$label" ] || continue
		found="/dev/${candidate##*/}"
		count=$((count + 1))
	done
	[ "$count" -eq 1 ] || return 1
	sbe1v1k_partition_is "$found" "$expected_part" || return 1
	[ "$found" = "/dev/mmcblk0p${expected_part}" ] || return 1
	block_name=${found##*/}
	[ "$(cat "/sys/class/block/${block_name}/size" 2>/dev/null)" = "$expected_sectors" ] || return 1
	[ "$(cat "/sys/class/block/${block_name}/ro" 2>/dev/null)" = 0 ] || return 1
	helper="$(find_mmc_part "$label")"
	[ "$helper" = "$found" ] || return 1
	echo "$found"
}

sbe1v1k_partition_is_unmounted() {
	local device="$1"
	local block_name devno mount_status
	[ -r /proc/self/mountinfo ] || return 1
	block_name=${device##*/}
	devno="$(cat "/sys/class/block/${block_name}/dev" 2>/dev/null)" || return 1
	[ -n "$devno" ] || return 1
	grep -Eq "^[^ ]+[[:space:]]+[^ ]+[[:space:]]+${devno}[[:space:]]" \
		/proc/self/mountinfo
	mount_status=$?
	case "$mount_status" in
	0) return 1 ;;
	1) return 0 ;;
	*) return 1 ;;
	esac
}

platform_check_image() {
	local image="$1"
	local expected members actual
	local kernel_dev root_dev data_dev recovery_dev recovery_hash

	sbe1v1k_supported_board || return 1
	[ -f "$image" ] || return 1
	expected="$(printf '%s\n' \
		"${SBE1V1K_IMAGE_DIR}/" \
		"${SBE1V1K_IMAGE_DIR}/CONTROL" \
		"${SBE1V1K_IMAGE_DIR}/kernel" \
		"${SBE1V1K_IMAGE_DIR}/root" | sort)"
	members="$(tar tf "$image" 2>/dev/null)" || return 1
	actual="$(printf '%s\n' "$members" | sort)"
	[ "$(printf '%s\n' "$actual" | wc -l)" -eq 4 ] || return 1
	[ "$actual" = "$expected" ] || return 1
	sbe1v1k_validate_metadata "$image" || return 1
	sbe1v1k_validate_payloads "$image" || return 1

	kernel_dev="$(sbe1v1k_find_unique_partition '0:HLOS' 25)" || return 1
	root_dev="$(sbe1v1k_find_unique_partition rootfs 27)" || return 1
	data_dev="$(sbe1v1k_find_unique_partition rootfs_data 29)" || return 1
	recovery_dev="$(sbe1v1k_find_unique_partition rsvd_2 40)" || return 1
	[ "$(hexdump -v -n 4 -e '4/1 "%02x"' "$recovery_dev" 2>/dev/null)" = d00dfeed ] || return 1
	recovery_hash="$(head -c "$SBE1V1K_RECOVERY_SIZE" "$recovery_dev" | sha256sum)" || return 1
	recovery_hash=${recovery_hash%% *}
	[ "$recovery_hash" = "$SBE1V1K_RECOVERY_SHA256" ] || return 1
	[ "$kernel_dev" != "$root_dev" ] && [ "$kernel_dev" != "$data_dev" ] && \
		[ "$kernel_dev" != "$recovery_dev" ] && [ "$root_dev" != "$data_dev" ] && \
		[ "$root_dev" != "$recovery_dev" ] && [ "$data_dev" != "$recovery_dev" ] || return 1
	return 0
}

platform_do_upgrade() {
	local image="$1"
	platform_check_image "$image" || return 1
	EMMC_KERN_DEV="$(sbe1v1k_find_unique_partition '0:HLOS' 25)" || return 1
	EMMC_ROOT_DEV="$(sbe1v1k_find_unique_partition rootfs 27)" || return 1
	EMMC_DATA_DEV="$(sbe1v1k_find_unique_partition rootfs_data 29)" || return 1
	sbe1v1k_partition_is_unmounted "$EMMC_KERN_DEV" || return 1
	sbe1v1k_partition_is_unmounted "$EMMC_ROOT_DEV" || return 1
	sbe1v1k_partition_is_unmounted "$EMMC_DATA_DEV" || return 1
	export EMMC_KERN_DEV EMMC_ROOT_DEV EMMC_DATA_DEV
	emmc_upgrade_tar "$image"
}
