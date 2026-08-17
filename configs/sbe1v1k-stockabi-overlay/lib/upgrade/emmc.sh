# Copyright (C) 2021 OpenWrt.org

SBE1V1K_IMAGE_DIR=sysupgrade-askey_sbe1v1k
SBE1V1K_KERNEL_SHA256=852030dc9e5d0b9e56845efd3a8decbde6dd93a7d779c84230331e244bfbb1bf

emmc_file_sha256() {
	local result
	result="$(sha256sum "$1")"
	echo "${result%% *}"
}

emmc_extract_member() {
	local image="$1"
	local member="$2"
	local destination="$3"
	rm -f "$destination"
	tar xf "$image" "$member" -O > "$destination" 2>/dev/null || return 1
	[ -f "$destination" ] && [ ! -L "$destination" ]
}

emmc_write_file() {
	local source="$1"
	local device="$2"
	local size expected actual
	size="$(wc -c < "$source")"
	[ "$size" -gt 0 ] || return 1
	expected="$(emmc_file_sha256 "$source")"
	[ "${#expected}" -eq 64 ] || return 1
	dd if="$source" of="$device" bs=1048576 2>/dev/null || return 1
	sync || return 1
	actual="$(head -c "$size" "$device" | sha256sum)"
	actual="${actual%% *}"
	[ "$actual" = "$expected" ]
}

emmc_upgrade_tar() {
	local image="$1"
	local kernel_file=/tmp/sbe1v1k-kernel.new
	local root_file=/tmp/sbe1v1k-root.new
	local zero_file=/tmp/sbe1v1k-p29-zero
	local readback_file=/tmp/sbe1v1k-zero-readback
	local kernel_size root_size kernel_magic root_magic
	[ -z "${UPGRADE_BACKUP:-}" ] || return 1
	[ -b "$EMMC_KERN_DEV" ] && [ -b "$EMMC_ROOT_DEV" ] && \
		[ -b "$EMMC_DATA_DEV" ] || return 1
	emmc_extract_member "$image" "${SBE1V1K_IMAGE_DIR}/kernel" "$kernel_file" || return 1
	emmc_extract_member "$image" "${SBE1V1K_IMAGE_DIR}/root" "$root_file" || return 1
	kernel_size="$(wc -c < "$kernel_file")"
	root_size="$(wc -c < "$root_file")"
	kernel_magic="$(hexdump -v -n 4 -e '4/1 "%02x"' "$kernel_file")"
	root_magic="$(hexdump -v -n 4 -e '4/1 "%02x"' "$root_file")"
	[ "$kernel_magic" = d00dfeed ] && [ "$kernel_size" -ge 64 ] && \
		[ "$kernel_size" -le 7335936 ] || return 1
	[ "$(emmc_file_sha256 "$kernel_file")" = "$SBE1V1K_KERNEL_SHA256" ] || return 1
	[ "$root_magic" = 68737173 ] && [ "$root_size" -ge 4096 ] && \
		[ "$root_size" -le 127860736 ] || return 1
	[ $((root_size % 65536)) -eq 0 ] || return 1
	rm -f "$zero_file" "$readback_file"
	dd if=/dev/zero of="$zero_file" bs=4096 count=1 2>/dev/null || return 1

	# Invalidate p25 first so an interrupted write uses the retained alternate boot path.
	dd if=/dev/zero of="$EMMC_KERN_DEV" bs=4096 count=1 2>/dev/null || return 1
	sync || return 1
	dd if="$EMMC_KERN_DEV" of="$readback_file" bs=4096 count=1 2>/dev/null || return 1
	cmp -s "$zero_file" "$readback_file" || return 1
	emmc_write_file "$root_file" "$EMMC_ROOT_DEV" || return 1
	# The v1 upgrade contract never preserves config. A zero prefix is the only
	# state in which audited preinit is allowed to create a fresh p29 ext4.
	dd if="$zero_file" of="$EMMC_DATA_DEV" bs=4096 count=1 2>/dev/null || return 1
	sync || return 1
	rm -f "$readback_file"
	dd if="$EMMC_DATA_DEV" of="$readback_file" bs=4096 count=1 2>/dev/null || return 1
	cmp -s "$zero_file" "$readback_file" || return 1
	emmc_write_file "$kernel_file" "$EMMC_KERN_DEV"
}
