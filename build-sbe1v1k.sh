#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -gt 1 ]; then
	die "usage: $0 [recovery|minimal|full]"
fi

build_profile="${1:-${BUILD_PROFILE:-minimal}}"
required_platform=
case "${build_profile}" in
	recovery)
		build_config="configs/sbe1v1k-recovery.config"
		;;
	minimal)
		build_config="configs/sbe1v1k.config"
		;;
	full)
		build_config="configs/sbe1v1k-full.config"
		required_platform=linux/amd64
		;;
	*)
		die "unknown profile '${build_profile}'; expected recovery, minimal, or full"
		;;
esac

if [ -n "${required_platform}" ]; then
	exec "${repo_root}/docker/openwrt-builder/build.sh" \
		--source "${repo_root}" \
		--config "${build_config}" \
		--target qualcommbe/ipq95xx \
		--output "build/${build_profile}" \
		--name "sbe1v1k-${build_profile}" \
		--cache-key sbe1v1k \
		--require-platform "${required_platform}"
fi

exec "${repo_root}/docker/openwrt-builder/build.sh" \
	--source "${repo_root}" \
	--config "${build_config}" \
	--target qualcommbe/ipq95xx \
	--output "build/${build_profile}" \
	--name "sbe1v1k-${build_profile}" \
	--cache-key sbe1v1k
