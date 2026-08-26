#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: ./build-sbe1v1k-native.sh [recovery|minimal|full]

Build SBE1V1K directly on an Ubuntu or WSL2 host without Docker.
The default profile is minimal.

Environment overrides:
  BUILD_JOBS=N       Parallel jobs (default: number of host CPUs)
  BUILD_OUTPUT_DIR=D Build log directory (default: build/native/PROFILE)
  CLEAN=1            Run "make clean" before building
  V=s                Enable verbose OpenWrt make output
  CURL_OPTIONS=...   Override download timeout options
EOF
}

if [ "$#" -gt 1 ]; then
	usage >&2
	exit 1
fi

case "${1:-minimal}" in
	recovery)
		build_profile=recovery
		build_config=configs/sbe1v1k-recovery.config
		;;
	minimal)
		build_profile=minimal
		build_config=configs/sbe1v1k.config
		;;
	full)
		build_profile=full
		build_config=configs/sbe1v1k-full.config
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown profile '$1'; expected recovery, minimal, or full"
		;;
esac

# Do not inherit Windows paths containing spaces. OpenWrt's package install
# rules use find -execdir, which rejects an unsafe PATH.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

for tool in git make rsync sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || die "required tool is missing: ${tool}"
done
[ -x "${repo_root}/scripts/feeds" ] || die "not an OpenWrt source tree: ${repo_root}"
[ -f "${repo_root}/${build_config}" ] || die "missing build config: ${build_config}"

if [ "${build_profile}" = full ]; then
	case "$(uname -m)" in
		x86_64 | amd64) ;;
		*) die "the full profile requires an x86_64 Ubuntu/WSL2 build host" ;;
	esac
fi

build_jobs="${BUILD_JOBS:-$(nproc)}"
case "${build_jobs}" in
	'' | *[!0-9]* | 0) die "BUILD_JOBS must be a positive integer" ;;
esac

case "${CLEAN:-0}" in
	0) ;;
	1)
		printf 'Cleaning previous OpenWrt build output...\n'
		make -C "${repo_root}" clean
		;;
	*) die "CLEAN must be 0 or 1" ;;
esac

output_dir="${BUILD_OUTPUT_DIR:-${repo_root}/build/native/${build_profile}}"
case "${output_dir}" in
	/*) ;;
	*) output_dir="${repo_root}/${output_dir}" ;;
esac
mkdir -p "${output_dir}"

revision="$(git -C "${repo_root}" rev-parse --short=12 HEAD)"
dirty=
if ! git -C "${repo_root}" diff-index --quiet HEAD -- ||
	[ -n "$(git -C "${repo_root}" ls-files --others --exclude-standard)" ]; then
	dirty=' (dirty working tree; firmware revision remains based on HEAD)'
fi

printf 'Building SBE1V1K %s natively with %s jobs\n' "${build_profile}" "${build_jobs}"
printf 'Git revision: %s%s\n' "${revision}" "${dirty}"
printf 'Build log: %s\n' "${output_dir}/build.log"

cd "${repo_root}"
BUILD_CONFIG_PATH="${build_config}" \
	BUILD_JOBS="${build_jobs}" \
	"${repo_root}/docker/openwrt-builder/openwrt-build.sh" \
	2>&1 | tee "${output_dir}/build.log"

artifact_dir="${repo_root}/bin/targets/qualcommbe/ipq95xx"
mapfile -t artifacts < <(find "${artifact_dir}" -maxdepth 1 -type f \
	-name '*askey_sbe1v1k*' -print | sort)
[ "${#artifacts[@]}" -gt 0 ] || die "build completed without SBE1V1K artifacts"

printf 'Build completed. Artifacts in %s:\n' "${artifact_dir}"
ls -lh "${artifacts[@]}"
printf 'SHA256:\n'
sha256sum "${artifacts[@]}"
