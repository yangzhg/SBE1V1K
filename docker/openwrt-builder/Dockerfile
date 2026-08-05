ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
	bc \
	bison \
	build-essential \
	bzip2 \
	ca-certificates \
	clang \
	curl \
	file \
	flex \
	g++ \
	gawk \
	gettext \
	git \
	libelf-dev \
	liblzma-dev \
	libncurses-dev \
	libssl-dev \
	python3-dev \
	python3-setuptools \
	rsync \
	subversion \
	swig \
	time \
	unzip \
	wget \
	xxd \
	zlib1g-dev \
	zstd \
	&& if [ "$(dpkg --print-architecture)" = amd64 ]; then \
		apt-get install -y --no-install-recommends gcc-multilib g++-multilib; \
	fi \
	&& rm -rf /var/lib/apt/lists/* \
	&& groupadd --gid 10001 openwrt \
	&& useradd --uid 10001 --gid openwrt --create-home --shell /bin/bash openwrt

COPY openwrt-build.sh /usr/local/bin/openwrt-build
RUN chmod 0755 /usr/local/bin/openwrt-build

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER openwrt
WORKDIR /workspace
