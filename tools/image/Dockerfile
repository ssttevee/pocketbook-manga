# Built first from tools/jre/Dockerfile --target toolchain. This is the same
# pinned GCC13/glibc2.23/Linux3.10 ARM soft-float toolchain as the worker JVM.
FROM pocketmanga-cross:local AS image
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
FROM scratch AS export
COPY --from=image /work/out/ /
