#!/bin/sh
set -eu
export PATH=/opt/x-tools/arm-pocketbook-linux-gnueabi/bin:$PATH
export PKG_CONFIG_LIBDIR=/work/deps/lib/pkgconfig:/work/deps/share/pkgconfig
export CFLAGS='-O2 -fPIC' CXXFLAGS='-O2 -fPIC'
export CC=arm-pocketbook-linux-gnueabi-gcc CXX=arm-pocketbook-linux-gnueabi-g++
export LDFLAGS='-L/work/deps/lib -Wl,-rpath,$ORIGIN'
export CPPFLAGS=-I/work/deps/include
mkdir -p /work/deps /work/out/lib /work/out/licenses
cmake_build() {
 name=$1;shift
 cmake -S /src/$name -B /work/$name -G Ninja -DCMAKE_TOOLCHAIN_FILE=/build/cross.cmake -DCMAKE_INSTALL_PREFIX=/work/deps -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON "$@"
 cmake --build /work/$name -j 8
 cmake --install /work/$name
}
meson_build() {
 name=$1;shift
 meson setup /work/$name /src/$name --cross-file=/build/cross.ini --prefix=/work/deps --libdir=lib --buildtype=release --wrap-mode=nofallback "$@"
 meson compile -C /work/$name -j 8
 meson install -C /work/$name
}
case "${1:-all}" in foundations|all)
cd /src/libffi && ./configure --host=arm-pocketbook-linux-gnueabi --prefix=/work/deps --disable-static --disable-docs && make -j8 && make install
cmake_build pcre2 -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=OFF
cmake_build zlib -DZLIB_BUILD_TESTING=OFF
meson_build glib -Dtests=false -Dinstalled_tests=false -Ddocumentation=false -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled -Dnls=disabled -Dlibelf=disabled
cmake_build expat -DEXPAT_DEV_URANDOM=ON -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_TOOLS=OFF
;; esac
case "${1:-all}" in codecs|all)
cmake_build libpng -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_HARDWARE_OPTIMIZATIONS=OFF
# libjpeg otherwise embeds the wall-clock date in its version banner. Keep
# the original runtime build string so rebuilding preserves its reviewed digest.
cmake_build jpeg-turbo -DBUILD=20261021 -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF
cmake_build webp -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_asm=false
cmake_build libde265 -DENABLE_SDL=OFF -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF
cmake_build libheif -DBUILD_TESTING=OFF -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DWITH_DAV1D=ON -DWITH_DAV1D_PLUGIN=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF -DWITH_RAV1E=OFF -DWITH_SvtEnc=OFF -DWITH_FFMPEG_DECODER=OFF -DENABLE_PLUGIN_LOADING=OFF
cmake_build highway -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF
cmake_build brotli -DBROTLI_DISABLE_TESTS=ON
meson_build little-cms2 -Dutils=false -Dtests=disabled -Djpeg=disabled -Dtiff=disabled
cmake_build jpeg-xl -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON
cmake_build openjpeg -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF
;; esac
case "${1:-all}" in vips|all)
python3 /build/decoder_only.py
meson_build vips -Dauto_features=disabled -Ddeprecated=false -Dexamples=false -Dcplusplus=false -Dintrospection=disabled -Dmodules=disabled -Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dnsgif=true -Dppm=false -Danalyze=false -Dradiance=false -Dheif=enabled -Djpeg-xl=enabled -Dopenjpeg=enabled
$CC -shared -fPIC -O2 /build/vips_bridge.c $(pkg-config --cflags --libs vips) -lm -Wl,-rpath,'$ORIGIN' -o /work/out/lib/libpocketmanga-image.so
cp -a /work/deps/lib/*.so* /work/out/lib/
cp -L "$($CXX -print-file-name=libstdc++.so.6)" "$($CC -print-file-name=libgcc_s.so.1)" "$($CC -print-file-name=libatomic.so.1)" /work/out/lib/
python3 /build/prune.py
find /work/out/lib -type f -name '*.so*' -exec patchelf --set-rpath '$ORIGIN' {} +
find /work/out/lib -type f -name '*.so*' -exec arm-pocketbook-linux-gnueabi-strip --strip-unneeded {} +
for source in /src/*; do
 name=$(basename "$source");mkdir -p /work/out/licenses/$name
 find "$source" -maxdepth 1 -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*authors*' \) -exec cp {} /work/out/licenses/$name/ \;
done
$CC -O2 /build/smoke.c -L/work/out/lib -lpocketmanga-image -Wl,-rpath,'$ORIGIN/lib' -o /work/out/pocketmanga-image-smoke
cd /work/out && tar --sort=name --mtime=@1792454400 --owner=0 --group=0 --numeric-owner -cf pocketmanga-image.tar lib licenses
sha256sum pocketmanga-image.tar > pocketmanga-image.tar.sha256

;; esac
