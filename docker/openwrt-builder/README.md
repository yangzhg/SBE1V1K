# Reusable OpenWrt Docker builder

This directory owns the Docker-specific OpenWrt build pipeline. Device wrappers
select a config and target; this component owns the Linux tool image, persistent
work volume, source synchronization, build execution and artifact export.

Example from an OpenWrt source tree:

```sh
./docker/openwrt-builder/build.sh \
  --source . \
  --config configs/sbe1v1k.config \
  --target qualcommbe/ipq95xx \
  --output build/minimal \
  --name sbe1v1k-minimal \
  --cache-key sbe1v1k
```

`--cache-key` lets several profiles share the same toolchain and download cache.
Pass `--require-platform linux/amd64` when a selected package cannot bootstrap on
an arm64 build host. The stable environment overrides are `DOCKER_CONTEXT`,
`BUILD_PLATFORM`, `BUILD_JOBS`, `BUILD_VOLUME`, `BUILDER_BASE_IMAGE` and
`BUILDER_IMAGE`. `CURL_OPTIONS` can override the default low-speed timeout used
for source downloads.
