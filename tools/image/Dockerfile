# Built first from tools/jre/Dockerfile --target toolchain. This is the same
# pinned GCC13/Linux3.10 ARM soft-float toolchain as the worker JVM.
# GLIBC_VERSION must match the selected local or published builder image.
ARG TOOLCHAIN_IMAGE=pocketmanga-cross:local
FROM ${TOOLCHAIN_IMAGE} AS image
ARG GLIBC_VERSION=2.23
RUN test "$POCKETMANGA_GLIBC_VERSION" = "$GLIBC_VERSION"
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends cmake ninja-build pkg-config python3-pip patchelf qemu-user \
 && pip3 install --break-system-packages meson==1.9.2 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY tools/image/sources.json tools/image/fetch.py /build/
RUN mkdir -p /src && python3 /build/fetch.py
COPY tools/image/build.sh tools/image/cross.ini tools/image/cross.cmake tools/image/prune.py /build/
RUN /build/build.sh foundations
RUN /build/build.sh codecs
COPY src/vips_bridge.c src/vips_bridge.h tools/image/smoke.c tools/image/decoder_only.py /build/
RUN /build/build.sh vips
COPY tools/image/smoke_fixtures.py /build/
RUN python3 /build/smoke_fixtures.py
FROM scratch AS export
COPY --from=image /work/out/ /
