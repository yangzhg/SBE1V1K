#!/usr/bin/env bash

set -Eeuo pipefail

builder_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: build.sh --source DIR --config FILE --target BOARD/SUBTARGET \
                --output DIR --name NAME [options]

Build an OpenWrt configuration in a Docker volume and export the selected
bin/targets directory to the host.

Required options:
  --source DIR              OpenWrt source tree
  --config FILE             Config path relative to the source tree
  --target BOARD/SUBTARGET  Path below bin/targets to export
  --output DIR              Host output directory; relative to --source
  --name NAME               Build label and container resource prefix

Optional:
  --cache-key NAME          Shared cache-volume prefix (default: --name)
  --require-platform NAME   Require linux/amd64 or linux/arm64
  -h, --help                Show this help

Environment overrides:
  DOCKER_CONTEXT, BUILD_PLATFORM, BUILD_JOBS, BUILD_VOLUME,
  BUILDER_BASE_IMAGE, BUILDER_IMAGE, CURL_OPTIONS,
  HTTP_PROXY, HTTPS_PROXY, NO_PROXY
EOF
}

need_option_value() {
	[ "$#" -ge 2 ] || die "option '$1' requires a value"
	[ -n "$2" ] || die "option '$1' requires a non-empty value"
}

source_root=
build_config=
target_path=
output_dir=
build_name=
cache_key=
required_platform=

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source)
			need_option_value "$@"
			source_root="$2"
			shift 2
			;;
		--config)
			need_option_value "$@"
			build_config="$2"
			shift 2
			;;
		--target)
			need_option_value "$@"
			target_path="$2"
			shift 2
			;;
		--output)
			need_option_value "$@"
			output_dir="$2"
			shift 2
			;;
		--name)
			need_option_value "$@"
			build_name="$2"
			shift 2
			;;
		--cache-key)
			need_option_value "$@"
			cache_key="$2"
			shift 2
			;;
		--require-platform)
			need_option_value "$@"
			required_platform="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option '$1'; use --help for usage"
			;;
	esac
done

[ -n "${source_root}" ] || die "--source is required"
[ -n "${build_config}" ] || die "--config is required"
[ -n "${target_path}" ] || die "--target is required"
[ -n "${output_dir}" ] || die "--output is required"
[ -n "${build_name}" ] || die "--name is required"

case "${build_config}" in
	/* | ../* | */../* | */..) die "--config must stay within --source" ;;
esac
case "${target_path}" in
	/* | ../* | */../* | */..) die "--target must stay within bin/targets" ;;
esac
case "${build_name}" in
	[!a-zA-Z0-9]*) die "--name must start with a letter or digit" ;;
	*[!a-zA-Z0-9_.-]*) die "--name may contain only letters, digits, '.', '_' and '-'" ;;
esac
cache_key="${cache_key:-${build_name}}"
case "${cache_key}" in
	[!a-zA-Z0-9]*) die "--cache-key must start with a letter or digit" ;;
	*[!a-zA-Z0-9_.-]*) die "--cache-key may contain only letters, digits, '.', '_' and '-'" ;;
esac

[ -d "${source_root}" ] || die "source directory does not exist: ${source_root}"
source_root="$(CDPATH= cd -- "${source_root}" && pwd)"
[ -x "${source_root}/scripts/feeds" ] || die "not an OpenWrt source tree: ${source_root}"
[ -f "${source_root}/feeds.conf.default" ] || die "missing feeds.conf.default in ${source_root}"
[ -f "${source_root}/${build_config}" ] || die "build config does not exist: ${build_config}"

case "${output_dir}" in
	/*) ;;
	*) output_dir="${source_root}/${output_dir}" ;;
esac
mkdir -p "${output_dir}"
output_dir="$(CDPATH= cd -- "${output_dir}" && pwd)"

docker_context="${DOCKER_CONTEXT:-}"
docker_cmd=(docker)
if [ -n "${docker_context}" ]; then
	docker_cmd+=(--context "${docker_context}")
fi

proxy_build_args=()
run_env_args=()
for proxy_var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
	proxy_value="${!proxy_var:-}"
	if [ -n "${proxy_value}" ]; then
		proxy_build_args+=(--build-arg "${proxy_var}=${proxy_value}")
		run_env_args+=(--env "${proxy_var}=${proxy_value}")
	fi
done
if [ -n "${CURL_OPTIONS:-}" ]; then
	run_env_args+=(--env "CURL_OPTIONS=${CURL_OPTIONS}")
fi

command -v docker >/dev/null 2>&1 || die "Docker CLI is required"

docker_endpoint="${docker_context:-current Docker CLI endpoint}"
"${docker_cmd[@]}" info >/dev/null 2>&1 ||
	die "Docker Engine is unavailable through ${docker_endpoint}; start a Linux-capable Docker provider or set DOCKER_CONTEXT"
[ "$("${docker_cmd[@]}" info --format '{{.OSType}}')" = linux ] ||
	die "the selected Docker Engine must be running Linux containers"

case "$("${docker_cmd[@]}" info --format '{{.Architecture}}')" in
	aarch64 | arm64)
		native_platform="linux/arm64"
		;;
	x86_64 | amd64)
		native_platform="linux/amd64"
		;;
	*)
		die "unsupported Docker Engine architecture"
		;;
esac

case "${required_platform}" in
	'' | linux/amd64 | linux/arm64) ;;
	*) die "unsupported required platform '${required_platform}'" ;;
esac

default_build_platform="${required_platform:-${native_platform}}"
build_platform="${BUILD_PLATFORM:-${default_build_platform}}"
case "${build_platform}" in
	linux/amd64)
		default_base_image="amd64/ubuntu:24.04"
		;;
	linux/arm64)
		default_base_image="arm64v8/ubuntu:24.04"
		;;
	*)
		die "unsupported build platform '${build_platform}'"
		;;
esac
if [ -n "${required_platform}" ] && [ "${build_platform}" != "${required_platform}" ]; then
	die "${build_name} requires BUILD_PLATFORM=${required_platform}"
fi

if [ -n "${BUILD_JOBS:-}" ]; then
	build_jobs="${BUILD_JOBS}"
elif [ "${native_platform}" = linux/arm64 ] && [ "${build_platform}" = linux/amd64 ]; then
	# Translated parallel package builds have produced truncated objects.
	build_jobs=1
else
	build_jobs="$("${docker_cmd[@]}" info --format '{{.NCPU}}')"
fi
case "${build_jobs}" in
	'' | *[!0-9]* | 0)
		die "BUILD_JOBS must be a positive integer"
		;;
esac

build_arch="${build_platform#linux/}"
builder_base_image="${BUILDER_BASE_IMAGE:-${default_base_image}}"
builder_image="${BUILDER_IMAGE:-openwrt-builder:ubuntu-24.04-${build_arch}}"
default_work_volume="${cache_key}-openwrt-work"
if [ "${build_platform}" != "${native_platform}" ]; then
	default_work_volume="${default_work_volume}-${build_arch}"
fi
work_volume="${BUILD_VOLUME:-${default_work_volume}}"

"${docker_cmd[@]}" volume create "${work_volume}" >/dev/null

printf 'Using %s; building reusable Ubuntu 24.04 tool image for %s...\n' \
	"${docker_endpoint}" "${build_platform}"
"${docker_cmd[@]}" build \
	--platform "${build_platform}" \
	"${proxy_build_args[@]}" \
	--build-arg "BASE_IMAGE=${builder_base_image}" \
	--tag "${builder_image}" \
	--file "${builder_dir}/Dockerfile" \
	"${builder_dir}"

"${docker_cmd[@]}" run --rm \
	--platform "${build_platform}" \
	--user root \
	--mount "type=volume,src=${work_volume},dst=/work" \
	"${builder_image}" \
	bash -c 'mkdir -p /work/source && chown -R openwrt:openwrt /work/source'

printf 'Synchronizing %s into Linux volume %s...\n' "${source_root}" "${work_volume}"
"${docker_cmd[@]}" run --rm \
	--platform "${build_platform}" \
	--mount "type=bind,src=${source_root},dst=/host-src,readonly" \
	--mount "type=volume,src=${work_volume},dst=/work" \
	"${builder_image}" \
	rsync -rlpt --delete \
		--exclude=/.ccache/ \
		--exclude=/.config \
		--exclude=/.config.old \
		--exclude=/bin/ \
		--exclude=/build/ \
		--exclude=/build_dir/ \
		--exclude=/dl/ \
		--exclude=/feeds/ \
		--exclude=/feeds.conf \
		--exclude=/logs/ \
		--exclude=/package/feeds/ \
		--exclude=/package/openwrt-packages/ \
		--exclude=/staging_dir/ \
		--exclude=/target/linux/feeds/ \
		--exclude=/tmp/ \
		/host-src/ /work/source/

printf 'Building %s with %s jobs; log: %s\n' \
	"${build_name}" "${build_jobs}" "${output_dir}/build.log"
build_container_name="${build_name}-build-${build_arch}"
"${docker_cmd[@]}" inspect "${build_container_name}" >/dev/null 2>&1 &&
	die "build container ${build_container_name} already exists; another build may be running"
cleanup_build_container() {
	"${docker_cmd[@]}" rm -f "${build_container_name}" >/dev/null 2>&1 || true
}
trap cleanup_build_container EXIT INT TERM
"${docker_cmd[@]}" run --rm \
	--name "${build_container_name}" \
	--platform "${build_platform}" \
	--env "BUILD_JOBS=${build_jobs}" \
	--env "BUILD_CONFIG_PATH=${build_config}" \
	"${run_env_args[@]}" \
	--mount "type=volume,src=${work_volume},dst=/work" \
	--workdir /work/source \
	"${builder_image}" \
	openwrt-build 2>&1 | tee "${output_dir}/build.log"
trap - EXIT INT TERM

export_container="$("${docker_cmd[@]}" create \
	--platform "${build_platform}" \
	--mount "type=volume,src=${work_volume},dst=/work,readonly" \
	"${builder_image}" true)"
cleanup_export_container() {
	"${docker_cmd[@]}" rm -f "${export_container}" >/dev/null 2>&1 || true
}
trap cleanup_export_container EXIT

"${docker_cmd[@]}" cp \
	"${export_container}:/work/source/bin/targets/${target_path}/." \
	"${output_dir}/"
"${docker_cmd[@]}" rm "${export_container}" >/dev/null
trap - EXIT

printf 'Build completed for %s. Artifacts exported to %s:\n' \
	"${build_name}" "${output_dir}"
find "${output_dir}" -maxdepth 1 -type f -print
