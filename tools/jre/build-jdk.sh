#!/bin/bash
# Configures and builds OpenJDK in the current directory (a jdk17u checkout)
# for the Verse: the client VM (template interpreter and C1) for ARMv7 with
# VFP and soft-float calls, against the toolchain's glibc 2.23. Configure also
# builds a native JDK of the same version to run jlink and the build tools.
set -euo pipefail
bash configure \
  --openjdk-target=arm-pocketbook-linux-gnueabi \
  --with-abi-profile=arm-vfp-sflt \
  --with-jvm-variants=client \
  --with-debug-level=release \
  --with-native-debug-symbols=none \
  --with-stdc++lib=static \
  --enable-headless-only \
  --with-freetype=bundled --with-zlib=bundled \
  --with-cups-include=/work/deps/include --with-fontconfig-include=/work/deps/include \
  --with-alsa=/work/deps/alsa \
  --with-extra-cflags=-I/work/deps/include --with-extra-cxxflags=-I/work/deps/include \
  --with-boot-jdk=/usr/lib/jvm/java-17-openjdk-arm64 \
  --with-version-build=1 --with-version-pre= --with-version-opt=pocketmanga \
  --with-vendor-name=PocketManga \
  --with-source-date=version --with-build-user=build \
  --disable-warnings-as-errors --disable-javac-server --disable-ccache
make JOBS="$(nproc)" LOG=warn images
