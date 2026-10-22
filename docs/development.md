# Development and verification

Start with [the build instructions](../README.md#build-from-source). This page covers the slower checks used when changing the runtime, firmware compatibility or reader rendering.

## Architecture

PocketManga is the InkView interface to libtachi's managed engine. libtachi owns the library, reading progress, chapter synchronization, downloads and local source. Its worker runs Android-compatible source extensions in a separate process; the UI never loads the JVM. Reading downloaded chapters and scanning local manga need only the native app.

The bundle includes an OpenJDK 17 runtime built from source for ARM32, a decoder-only libvips runtime, and public certificate stores. HotSpot uses its client VM with C1 JIT and class-data sharing. Extension HTTP and native image downloads use Zig sockets and TLS through cancellable `std.Io` tasks. Sources that need unsupported request transformations fall back to their JVM client.

After an online task starts the worker, it stays ready until reading begins. Background downloads can keep it alive while reading; leaving or closing the app stops it. Active work prevents reader sleep until completion, failure or cancellation. A crashed worker reports an error and can be started again by the next request. See [native downloads](native-downloads.md) and [reader completion delivery](reader-wake.md).

The worker starts with a 16 MiB heap, capped at 128 MiB, with 96 MiB for class metadata and 512 KiB Java thread stacks. It uses Serial GC and two active processors. Loading many large extensions can exhaust this budget. Cold startup and extension loading remain slow on this hardware.

## Image rendering

The region reader resizes with Lanczos filtering, composites onto white and copies grayscale pixels. Paged mode fits the whole image by default; its temporary Zoom option restores long-axis panning. Continuous vertical mode fits image widths and joins their boundaries, including small footer fragments.

The visible viewport is published before speculative preparation of later views. A 1 MiB RAM tile cache and a 64 MiB disk tile cache avoid repeated decoding. Speculative work shares the decoder and can be canceled by navigation. PNG/JPEG decoding can use temporary disk space; full-frame codecs have a 32-megapixel admission limit. These cache limits do not cap total decoder memory. See [image runtime build and resource limits](../tools/image/README.md).

To exercise the production codec path in UI tests, build the host bridge described in that document, then run:

```sh
POCKETMANGA_IMAGE_TEST_LIBRARY="$PWD/.runtime-cache/image-host/libpocketmanga-image.dylib" zig build test
```

Use the corresponding `.so` path on Linux.

## Firmware verification


The firmware checks run the packaged app on official firmware root filesystems. Extract the checksum-pinned 6.10.1461 and 6.9.862 archives (6.9 is the closest available glibc 2.23 stand-in for 6.8) **outside the repo**. `prepare_firmware.py` requires `debugfs` (e2fsprogs) and `unsquashfs`, and reads images without mounting them or using root:

```
zig build runtime-probe -Doptimize=small
docker build -f tools/Dockerfile.arm-test -t pocketmanga-arm-test:local .
python3 tools/prepare_firmware.py 6.10 /tmp/inkview-firmware-6.8-device/verse-6.10.1461.zip --output /tmp/pocketmanga-prepared610
python3 tools/prepare_firmware.py 6.9 /tmp/inkview-firmware-6.8-device/verse-6.9.862.zip --output /tmp/pocketmanga-prepared69
```

The fixture checks request planning, both rate-limit layouts, null image URL resolution and JVM fallback. It downloads three ~1 MiB PNGs through native TLS and Zig DNS, requiring the extension's header, Referer, cookie-jar cookie and request-interceptor cookie. Its test CA is generated and installed only into temporary container copies, never into dist/. The repository test exercises live HTTPS using the bundle's CA roots.

```
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --log-launcher
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10

docker build -f tools/Dockerfile.kernel310-test -t pocketmanga-kernel310-test:local .
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --log-launcher
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10 --deny-new-syscalls
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --parent-exit

python3 tools/audit_runtime.py --rootfs /tmp/pocketmanga-prepared69 --process ui
python3 tools/audit_runtime.py --rootfs /tmp/pocketmanga-prepared69 --process worker
```

Additional strict scenarios exercise cancellation/resume and dynamic redirect fallback:

```
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared69 --version 6.9 --deny-new-syscalls --cancel-resume
python3 tools/test_firmware_runtime.py --rootfs /tmp/pocketmanga-prepared610 --version 6.10 --deny-new-syscalls --redirect
```

Repeat the ELF audits for the 6.10 root. The containers use the packaged UI, native firmware loader and real InkView library up to symbol resolution, stopping before `InkViewMain`. They exercise the worker's full fixture on the firmware's own glibc and the actual UI/worker protocol, including progress, crash/retry, version rejection, EOF and idle shutdown. `--parent-exit` deliberately bypasses UI cleanup and checks that its worker exits too. RSS samples include emulator overhead and stop before the hardware event loop.

The extra QEMU build makes post-3.10 **guest** ARM syscalls return `ENOSYS` (including time64 calls), rather than relying on the host's newer kernel. It is a test artifact only. Local firmware Docker images contain proprietary libraries; keep them local. Logs are in `dist/firmware-tests/`. See [the firmware implementation report](firmware-6.8.md) for the syscall audit, process/library ownership and measured results.

UI tests drive the actual fabrum InkView host through its fake framebuffer: source installation, keyboard search, adding a title, downloading and opening a chapter, source preferences, physical keys, tap zones, Back, progress after metadata replacement, and failure handling. Partial image redraws are compared against a full redraw, including padded framebuffer rows.

The separate [reader wake diagnostic](reader-wake.md) tests completion delivery on physical firmware with periodic task polling disabled, without replacing the production app.


## Packaging details

The packaging script checks Java and image runtime digests from `tools/runtime-packages.json`. It also verifies the Debian certificate package and creates Java and PEM trust stores from its public CA certificates. Packages are cached under `.runtime-cache/`; firmware files are never shipped.

`zig build` compiles the worker's libzstd JNI decoder. Set `JAVA_HOME` so it can find `jni.h`. The packaged OpenJDK licenses are under `runtime/jre/legal/`; certificate and GCC runtime licenses are under `runtime/licenses/`. The host JAR path can be overridden with `tools/package_device.py --host-jar FILE`.

Both device executables target Cortex-A7 and ARM EABI soft-float. The default glibc target is 2.23; `-Dglibc=2.39` selects the firmware 6.10 profile. Keep the native binaries, JVM and image runtime on the same profile; [release packaging](releases.md) verifies this. They use the reader's loader and C library; the bundle does not replace system libraries. The launcher retains an executable-stack setting needed by some firmware releases.

See also [Java runtime builds](java-runtime.md), [firmware compatibility](firmware-6.8.md), [Mihon UI comparison](mihon-ui.md), and [device feedback fixes](device-feedback-fixes.md).
