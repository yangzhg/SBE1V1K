#!/usr/bin/env bash

set -Eeuo pipefail

: "${BUILD_CONFIG_PATH:?BUILD_CONFIG_PATH is required}"
: "${BUILD_JOBS:?BUILD_JOBS is required}"

# OpenWrt only limits connection setup time by default. Abort transfers that
# stop making progress so the downloader can try its next configured mirror.
export CURL_OPTIONS="${CURL_OPTIONS:---speed-limit 1024 --speed-time 30}"

cp feeds.conf.default feeds.conf

repair_invalid_pinned_git_feeds() {
	local feed_type feed_name feed_source ignored
	local pinned_commit feed_dir head_commit resolved_commit

	while read -r feed_type feed_name feed_source ignored; do
		case "${feed_type}" in
			src-git | src-git-full) ;;
			*) continue ;;
		esac
		case "${feed_name}" in
			'' | *[!a-zA-Z0-9_.-]*) continue ;;
		esac
		case "${feed_source}" in
			*^*) pinned_commit="${feed_source##*^}" ;;
			*) continue ;;
		esac

		feed_dir="feeds/${feed_name}"
		[ -d "${feed_dir}/.git" ] || continue

		head_commit="$(git -C "${feed_dir}" rev-parse --verify HEAD 2>/dev/null || true)"
		resolved_commit="$(git -C "${feed_dir}" rev-parse --verify "${pinned_commit}^{commit}" 2>/dev/null || true)"
		if [ -z "${head_commit}" ] || [ "${head_commit}" != "${resolved_commit}" ] ||
			! git -C "${feed_dir}" diff-index --quiet HEAD --; then
			printf 'Discarding invalid pinned feed cache %s; it will be cloned again.\n' \
				"${feed_name}" >&2
			rm -rf -- "${feed_dir}"
		fi
	done < feeds.conf
}

repair_invalid_pinned_git_feeds

feed_update_ok=0
for feed_update_attempt in 1 2 3; do
	if ./scripts/feeds update -a; then
		feed_update_ok=1
		break
	fi
	printf 'Feed update failed (attempt %s/3); retrying...\n' \
		"${feed_update_attempt}" >&2
done
[ "${feed_update_ok}" -eq 1 ] || {
	printf 'Feed update failed after 3 attempts.\n' >&2
	exit 1
}

./scripts/feeds uninstall -a >/dev/null
./scripts/feeds install -a
cp "${BUILD_CONFIG_PATH}" .config
make defconfig
make download -j"${BUILD_JOBS}"
make -j"${BUILD_JOBS}" world
