The image runtime is built with the same pinned ARM soft-float GCC/sysroot
profile as the Java runtime: glibc 2.23 for firmware 6.8–6.9, or 2.39 for 6.10. Run `python3 tools/build_images.py`, then package
with `tools/package_device.py`. Sources and SHA-256 checksums are recorded in
`sources.json`; Docker's Debian packages use the JRE build's snapshot. Pass
`--glibc 2.39` to build the newer profile. The libjpeg build label is fixed
to the original reviewed runtime date so identical sources produce the same
archive on different days. See [release builds](../../docs/releases.md).

Enabled image families match Mihon's ImageUtil allowlist and imagedecoder 17:
JPEG, PNG/APNG, WebP, GIF, AVIF, HEIF, JPEG XL and JPEG 2000. Animated images
show the first frame, like Mihon's static/webtoon decoder. TIFF, SVG, PDF,
ImageMagick, video, RAW, FITS and OpenSlide backends are disabled. Built-in
PPM, Radiance and Analyze loaders are disabled too. The bridge independently
checks libvips' content-sniffed loader against that same allowlist; extensions
are not trusted. No encoder programs or unrelated libraries are packaged.
Some codec libraries and libvips share decoder and encoder code internally.

The C bridge normalizes orientation, composites transparency onto white before
Lanczos downsampling, and returns native-resolution gray8 rectangles. JPEG and
WebP use shrink-on-load before the final exact-size resample. The operation
cache is disabled; a page retains at most 32 256x256 grayscale tiles. Sequential
inputs over 8 MiB spill to libvips' temporary disk cache; the app provides its
private cache directory via TMPDIR. Disk failures propagate as decode errors.

JPEG/PNG sources are limited to 512 megapixels and one million pixels per side.
Codecs that may allocate complete frames (WebP/GIF/AVIF/HEIF/JXL/JP2) additionally
have a 32-megapixel decoding budget. These guards bound admitted workloads;
libvips' tile limit is not a hard upper bound on codec allocation. The device
still needs real peak-RSS/latency measurements for representative pages.

HEIF/JXL need modern C++ support. Private libstdc++/libgcc live only under
runtime/image/lib, with $ORIGIN RUNPATHs; glibc is never bundled. The worker's
existing runtime directory and launcher environment remain separate. The
firmware audit validates the private image closure against the reader's libc.

For native integration checks, install host libvips, build the bridge with
`python3 tools/build_images.py --host --output .runtime-cache/image-host`, then
run `python3 tools/test_image_regions.py --library
.runtime-cache/image-host/libpocketmanga-image.dylib --vips /opt/homebrew/bin/vips`
(use `.so` on Linux). This covers all eight families, both axes, orientation,
alpha, region seams and corrupted/unsupported inputs.
