# syntax=docker/dockerfile:1.7
# The worker's Java runtime, cross-built from source for the Verse: OpenJDK's
# ARM32 port (template interpreter, C1, CDS) against the selected glibc, so the reader's
# own C library runs it. tools/build_jre.py drives this build.
#
# Every input is pinned: the base image by digest, Debian packages by snapshot
# date, and each downloaded source by checksum or commit.

ARG BUILDER_IMAGE=deps
FROM debian:bookworm-20261005-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS base
ARG SNAPSHOT=20261005T000000Z
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm-updates main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bookworm-security main\n' \
      $SNAPSHOT $SNAPSHOT $SNAPSHOT > /etc/apt/sources.list \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      autoconf automake bison bzip2 ca-certificates file flex g++ gawk gcc git \
      help2man libncurses-dev libtool-bin make patch python3 rsync texinfo unzip wget xz-utils zip \
      openjdk-17-jdk-headless libcups2-dev libfontconfig-dev \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1000 build \
 && install -d -o build /opt/x-tools /src /work

# A GCC 13 cross compiler for arm-pocketbook-linux-gnueabi with a selected glibc
# sysroot. crosstool-ng checks every source tarball's digest.
FROM base AS toolchain
ADD --checksum=sha256:1e0c5efcf2af674993b74a1783fe78727c8d34b500ebab07eb1bb0a45c8fcc87 \
    https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-1.29.0/crosstool-ng-1.29.0.tar.xz /src/
RUN cd /src && tar xf crosstool-ng-1.29.0.tar.xz && cd crosstool-ng-1.29.0 \
 && ./configure --prefix=/opt/ct-ng -q && make -s -j"$(nproc)" && make -s install \
 && cd / && rm -rf /src/crosstool-ng-1.29.0*
USER build
WORKDIR /work/toolchain
COPY --chown=build crosstool.config defconfig
ARG GLIBC_VERSION=2.23
RUN case "$GLIBC_VERSION" in 2.23|2.39) ;; *) echo "Unsupported glibc: $GLIBC_VERSION" >&2; exit 1;; esac \
 && sed -i "s/CT_GLIBC_V_2_23=y/CT_GLIBC_V_$(printf '%s' "$GLIBC_VERSION" | tr . _)=y/" defconfig \
 && /opt/ct-ng/bin/ct-ng defconfig \
 && /opt/ct-ng/bin/ct-ng build.$(nproc) \
 && cd / && rm -rf /work/toolchain/.build /home/build/src
ENV POCKETMANGA_GLIBC_VERSION=$GLIBC_VERSION
ENV PATH=/opt/x-tools/arm-pocketbook-linux-gnueabi/bin:$PATH

# Headless OpenJDK still compiles java.desktop, which needs CUPS, fontconfig
# and X11 headers and an ALSA library to link against. None of it is shipped.
FROM toolchain AS deps
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libx11-dev libxext-dev libxi-dev libxrandr-dev libxrender-dev libxt-dev libxtst-dev \
 && rm -rf /var/lib/apt/lists/*
USER build
ADD --chown=build --checksum=sha256:f740db7f488255944ffd4428416ee3390a96742856916433df468c281436480e \
    https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.16.1.tar.bz2 /src/
RUN mkdir -p /work/deps/include && cp -r /usr/include/cups /usr/include/fontconfig /usr/include/X11 /work/deps/include/ \
 && cd /src && tar xf alsa-lib-1.2.16.1.tar.bz2 && cd alsa-lib-1.2.16.1 \
 && ./configure -q --host=arm-pocketbook-linux-gnueabi --prefix=/work/deps/alsa \
      --disable-static --disable-python --disable-alisp --disable-topology --disable-ucm \
 && make -s -j"$(nproc)" && make -s install \
 && cd / && rm -rf /src/alsa-lib-1.2.16.1*

# OpenJDK 17.0.20.1+1 from its GA tag; build-jdk.sh has the configuration.
FROM ${BUILDER_IMAGE} AS jdk
ARG GLIBC_VERSION=2.23
RUN test "$POCKETMANGA_GLIBC_VERSION" = "$GLIBC_VERSION"
ARG JDK_COMMIT=c35a8d5a87559ad2734f1023bb321176c13c7ba0
RUN git init -q /work/jdk17u && cd /work/jdk17u \
 && git fetch -q --depth 1 https://github.com/openjdk/jdk17u.git $JDK_COMMIT \
 && git -c advice.detachedHead=false checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = $JDK_COMMIT && rm -rf .git
WORKDIR /work/jdk17u
COPY build-jdk.sh /work/
RUN /work/build-jdk.sh \
 && rm -rf build/*/hotspot build/*/support/native build/*/support/*_objs build/*/jdk/objs

# The worker's runtime: only the modules the host and extensions use. Class
# loading on the reader is CPU bound, so the module image stays uncompressed.
FROM jdk AS runtime
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends qemu-user \
 && rm -rf /var/lib/apt/lists/*
USER build
ARG MODULES=java.base,java.instrument,java.logging,java.net.http,java.sql,java.xml,jdk.charsets,jdk.crypto.ec,jdk.localedata,jdk.unsupported
RUN build/*/buildjdk/jdk/bin/jlink \
      --module-path build/linux-arm-client-release/images/jmods \
      --add-modules $MODULES \
      --strip-debug --no-man-pages --no-header-files --compress=0 \
      --output /work/out/jre \
 && find /work/out/jre -name '*.so' -exec arm-pocketbook-linux-gnueabi-strip --strip-unneeded {} + \
 && cd /work/out && tar --sort=name --mtime=@$(date -d 2026-08-18 +%s) --owner=0 --group=0 --numeric-owner \
      -cf pocketmanga-jre.tar jre && sha256sum pocketmanga-jre.tar | tee pocketmanga-jre.tar.sha256
# The base class-data-sharing archive, dumped by the ARM JVM itself under qemu
# against the toolchain's glibc. HotSpot's dump differs slightly from run to
# run, so it stays out of the pinned tar; the VM checks it against the exact
# libjvm and module image it loads with.
RUN qemu-arm -L "$(arm-pocketbook-linux-gnueabi-gcc -print-sysroot)" /work/out/jre/bin/java \
      -Xshare:dump -XX:SharedArchiveFile=/work/out/classes.jsa -Xlog:cds=off

# Published runtime images use this target. It keeps a shell for docker run/cp
# and exposes exactly the artifacts consumed by the packaging scripts.
FROM debian:bookworm-20261005-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS artifacts
COPY --from=runtime /work/out/pocketmanga-jre.tar /work/out/pocketmanga-jre.tar.sha256 /work/out/classes.jsa /artifacts/

FROM scratch AS export
COPY --from=runtime /work/out/pocketmanga-jre.tar /work/out/pocketmanga-jre.tar.sha256 /work/out/classes.jsa /
