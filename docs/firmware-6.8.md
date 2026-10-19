# Verse 6.8 implementation report

Chapter downloading, cancellation, protocol version and resume behavior are superseded by [native-downloads.md](native-downloads.md). The firmware/process ABI and runtime provenance described here still apply.

The final design uses two processes. The UI's firmware libraries remain paired with their own glibc; the newer GNU runtime is private to the JVM worker. All changes are uncommitted on `firmware-6.8`, based on clean commit `1f8a214` (the checkout's starting branch was named `main`). No sibling repository or physical reader was modified.

## Processes and lifecycle

`bin/pocketmanga` is the fabrum/InkView UI, built for Cortex-A7 ARM soft-float and **glibc 2.23**. Its only NEEDED entries are `libc.so.6`, `ld-linux.so.3`, `libpthread.so.0`, `libdl.so.2`; its highest version requirement is **GLIBC_2.17**. It has no libtachi module dependency or JVM loading code. Source DTOs are a local wire schema. It reads images, library/progress JSON and local manga directly. Local scanning has a regression test with no runtime bundle present.

`bin/pocketmanga-worker` is built for the same CPU/ABI and **glibc 2.39**. It alone imports libtachi and loads OpenJDK 17 Zero via JNI. The executable's highest GLIBC requirement is 2.36; libjvm requires 2.34. Both are satisfied by the pinned 2.39 runtime. No InkView module or library is loaded in this process.

The UI forks/execs the worker on its long-lived event thread before starting request I/O on a background thread. This matters: Linux's parent-death signal follows the *thread* that forks, so spawning from a short-lived request thread incorrectly kills a persistent worker when that thread finishes. The child inherits the InkView task's process group; it does not call `setsid`, `setpgrp`, `NewTask` or `OpenTask`. The parent prepares its argv and descriptor list before `fork`; the child only performs async-safe descriptor/prctl/exec operations. Inherited UI descriptors are closed, except stdio and the private socket on fd 3.

Worker ownership has three independent exit paths: EOF on its private socket, `PR_SET_PDEATHSIG(SIGKILL)` with a parent-race check before exec, and explicit UI shutdown/kill/reap. The worker exits after **60 seconds idle**; opening a downloaded chapter shuts an idle worker down immediately. It receives cancellation while a request runs and checks it between stages/pages. A shutdown or EOF exits even if HTTP is blocked. Abrupt termination can leave an unpublished download directory or `.tmp` file; the library manifest is only replaced after successful publication, and local scanning excludes downloads.

The task reference in `../libinkview/docs/api/core-tasks.md` says task identity is its process-group id, children belong to that task, backgrounding changes foreground ownership, and `CloseTask` delivers `EVT_EXIT` with possible forced termination. The network reference confirms InkView itself fork/execs or popens helpers. There is no guarantee in those docs that ordinary backgrounding kills a child, so PocketManga explicitly stops/reaps its worker on `EVT_BACKGROUND`. `EVT_FOREGROUND` permits new requests. The app wraps `InkViewMain`'s handler and `CloseApp` to handle `EVT_EXIT` and app-initiated closes; it does not rely on Zig defers surviving InkView's `_exit`. EOF/parent-death remain effective if the UI is killed without an event.

## Protocol

A private Unix socketpair carries a little-endian **u32 length**, followed by UTF-8 JSON, bounded to **32 MiB**. Every message has protocol `version: 1` and an id. There is one active request. Commands are `request`, `cancel`, `shutdown`; a test-only crash command requires the diagnostic environment flag. Responses are `progress`, `result`, `failure`, with matching ids. Progress carries completed/total page counts; diagnostics also sample RSS. Unsupported versions are rejected. Parsing and incomplete-frame waits are bounded; EOF, malformed messages or a dead worker become a visible job error. No uncertain request is automatically replayed. Once an error clears the busy job, the next user request can start a new worker and restore installed extensions.

## Launcher commands and file discovery

The `.app` launcher clears inherited loader path/preload/audit overrides and starts the UI normally:

```sh
ROOT=/mnt/ext1/applications/pocketmanga
exec "$ROOT/bin/pocketmanga" "$ROOT"
```

The UI constructs this worker argv directly (no shell):

```sh
ROOT=/mnt/ext1/applications/pocketmanga
LIBRARIES="$ROOT/runtime/lib:$ROOT/runtime/jre/lib:$ROOT/runtime/jre/lib/server:/ebrmain/lib:/usr/lib:/ebrmain/cramfs/lib"
"$ROOT/runtime/lib/ld-linux.so.3" --inhibit-cache --library-path "$LIBRARIES" --argv0 "$ROOT/bin/pocketmanga-worker" "$ROOT/bin/pocketmanga-worker" --serve "$ROOT"
```

`--library-path` is process-local; it is not exported as `LD_LIBRARY_PATH`, so firmware helper subprocesses keep their system loader/libc. Explicit invocation avoids installing an absolute interpreter into an app that can move in staging. The worker ELF's ordinary `/lib/ld-linux.so.3` interpreter is bypassed by this command. The UI always uses that firmware interpreter.

The UI gets its root explicitly as argv[1]. The worker gets `--serve ROOT`; libtachi receives explicit Java home, host jar, CA and data paths. Its beside-executable jar discovery is therefore unused. `/proc/self/exe` in the worker names the private loader, but HotSpot locates Java home from the mapped `libjvm.so` using its `os::jvm_path`/`dladdr` path, not that executable link. JNI fixture tests verify this layout. The JRE `java`/`jspawnhelper` launch paths are not used by this app.

The log launcher remains the shipped shell wrapper:

```sh
exec /mnt/ext1/applications/pocketmanga.app >> /mnt/ext1/applications/pocketmanga.log 2>&1
```

Both UI and child diagnostics inherit that log. The executable-stack tunable is retained for firmware releases that require it; glibc 2.23 ignores unknown tunables.

## Bundle provenance and firmware dependencies

All firmware runtime files come unchanged from the official **U629.6.10.1461** archive. Its SHA256 is `b4f21e38bc9213dd3588e77258e26f72dc644fa565c98260f7334fd62eaabe8a`. `tools/runtime-packages.json` records the official download URL and a checksum for every allowed file. Packaging validates them before replacing a staging runtime and again during copying.

The worker's `runtime/lib/` contains exactly:

- From firmware `/lib/`: `ld-linux.so.3`, `libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`, `libresolv.so.2`, `libutil.so.1`, `libnsl.so.1`, `libnss_dns.so.2`, `libnss_files.so.2`, `libnss_compat.so.2`, `libnss_db.so.2`, `libnss_hesiod.so.2`, `libgcc_s.so.1`.
- From firmware `/ebrmain/cramfs/lib/`: `libstdc++.so.6.0.32` installed as `libstdc++.so.6`, and `libatomic.so.1.2.0` installed as `libatomic.so.1`. Together with libgcc_s these are the firmware's GCC 13.3.0 set. The older Debian GCC libraries are test-sysroot inputs only; none ships in runtime/lib.

The 6.9 and 6.10 root images have **no `/etc/nsswitch.conf`**. Glibc 2.39's default hosts policy is `files dns`; its files/DNS code is largely in libc, but the matching compatibility modules and resolver are included. Additional modules present in that firmware are included too. The fixture uses a local DNS server and `fixture.pocketmanga.test`, rather than an IP literal, proving JVM DNS resolution. The actual 6.8 reader's private `/etc` was not accessible from USB; a custom NSS policy is a remaining device check.

The Debian checksum-pinned ARM OpenJDK **17.0.19+10-1~deb12u2** supplies the JRE. Debian's CA package supplies the PEM and Java trust stores (142 public roots). The host jar comes from the existing zig-tachi build. GNU license texts and provenance notices ship under runtime/licenses; JRE legal files remain intact. The firmware's source-offer notice directs corresponding-source requests to PocketBook support; no such message was sent.

**UI libraries all come from the device**, including its glibc, loader and GCC runtime. On 6.9 the non-GNU InkView closure is: InkView/hwconfig, OpenSSL 1.0, freetype, JPEG 8, TIFF 5, PNG 12, zlib, curl, c-ares, ICU 58 (uc/i18n/io/data), jsoncpp 11 and bzip2. On 6.10 it is the corresponding OpenSSL 3, TIFF 6, PNG 16, ICU 73, jsoncpp 25 and newer versions of those libraries. Their `NEEDED` and symbol/version imports are audited transitively. On the old firmware, libinkview requires at most GLIBC_2.7; on 6.10 it requires 2.38. They each stay with their own firmware libc.

The worker's only device library in its audited closure is **zlib** (`libz.so.1.2.11` on 6.9; `libz.so.1.3.1` on 6.10), requiring GLIBC_2.4. Its GNU libraries all resolve from the private bundle, and no InkView is present. Mapping checks verify this after JNI/extension operations. Proprietary libraries, images, extracted roots and test emulators are not in the distributable archive.

## Linux 3.10 syscall audit

Both executables use the app-owned `DeviceIo`. Zig 0.17's raw statx calls would break file stat/length and repeated recursive mkdir on 3.10. The adapter redirects file/dir stat, length and mkdir checks to a small C ABI bridge compiled separately for each process's libc. It uses `fstat`/`fstatat` with large-file support, and reads/validates `/dev/urandom` directly for secure entropy. UI local scan/read/write/atomic-manifest paths need no newer syscall. The low UI target also keeps std's linked entropy selection below the getrandom/arc4random thresholds. The untouched std vtable still contains other generic operations; their presence in disassembly does not mean the app calls them.

The exact firmware glibc has a Linux **3.2 minimum ABI note**. Binary disassembly confirms its exported getrandom wrapper opens/reads `/dev/urandom`; getentropy and arc4random retain ENOSYS fallbacks. `statx` falls back to fstatat; ARM's time64 stat/clock/futex wrappers fall back to the older calls. `clone3` falls back to clone. `rseq` failure is tolerated. These paths are exercised with missing syscalls in the guest, including JNI thread creation/detachment and worker exit.

Zig file-copy code can try `copy_file_range` but catches `ENOSYS` and disables that optimization. Positional I/O uses preadv64/pwritev64; glibc's preadv2/pwritev2 wrappers also have fallback for zero flags. No required pidfd, close_range, membarrier, memfd_create, openat2, faccessat2, io_uring or futex_waitv operation was found in the app's used paths. Tests deny all of them, plus renameat2, sched_setattr, time64 and future ARM calls.

The shipped JVM's used native libraries (`libjvm`, `libjava`, `libnio`, `libnet`) have no direct ARM `svc` instructions or modern-syscall imports. Static relocation/PLT inspection found libjvm's 14 generic syscall sites: gettid (224), futex (240), and optional get_mempolicy (320; failure handled). libnio's generic syscall wrapper is fstatat64. Its optional statx support resolves libc's wrapper with dlsym and falls back to older stat calls. Java NativePRNG uses `/dev/random`/`/dev/urandom`. JNI, extension restore/install, image HTTP, file publication and worker restarts all pass with post-3.10 calls absent.

Ordinary emulation uses the host kernel, so an extra test QEMU build returns `-ENOSYS` directly from ARM guest dispatch for syscall numbers **380 through 0xeffff**, preserving ARM private calls such as set_tls/cacheflush. ARM syscall 379 is finit_module (3.8); 380 is sched_setattr (3.14). This covers the listed calls and 32-bit time64 calls; the worker explicitly verifies raw statx/getrandom return ENOSYS. Host seccomp was not reliable here (OrbStack runtime/QEMU translation issues), so it is not used as evidence. This is still syscall-availability simulation, not the B288 kernel or hardware.

Primary source references: [glibc statx fallback](https://github.com/bminor/glibc/blob/glibc-2.39/sysdeps/unix/sysv/linux/statx.c), [ARM/time64 stat fallback](https://github.com/bminor/glibc/blob/glibc-2.39/sysdeps/unix/sysv/linux/fstatat64.c), [clone fallback](https://github.com/bminor/glibc/blob/glibc-2.39/sysdeps/unix/sysv/linux/clone-internal.c), [NSS defaults](https://github.com/bminor/glibc/blob/glibc-2.39/nss/nss_database.c), [HotSpot Linux code](https://github.com/openjdk/jdk17u/blob/jdk-17.0.19%2B10/src/hotspot/os/linux/os_linux.cpp), [Java NIO stat selection](https://github.com/openjdk/jdk17u/blob/jdk-17.0.19%2B10/src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c), [NativePRNG](https://github.com/openjdk/jdk17u/blob/jdk-17.0.19%2B10/src/java.base/unix/classes/sun/security/provider/NativePRNG.java). PocketBook's modified behavior was checked in the pinned binaries, not inferred solely from upstream sources.

## Verification and memory

All final checks passed:

- `/Users/steve/Programs/Zig/v0.17.0/zig build test` (default Debug), plus `build test device runtime-probe -Doptimize=ReleaseSmall`. Existing framebuffer/UI/persistence/background tests and the new no-JVM local scan test pass.
- `python3 tools/package_device.py --firmware-root /tmp/pocketmanga-prepared610 --test-sysroot`. The extractor was also run successfully on the existing 6.10 firmware ZIP; no firmware was re-downloaded.
- Existing `test_arm_runtime.py sources`, `repo`, `fixture`: pass. Live repository HTTPS returned **1,443 extensions**; the fixture downloaded its authenticated **68-byte PNG**. Direct-worker VM destruction also passes.
- `test_firmware_runtime.py` on **6.9.862 and 6.10.1461**, both normally and with `--deny-new-syscalls`: all four pass as uid 1000, cwd `/`. The old-root runs use `--log-launcher`; its actual native wrapper is tested in the normal run. Each test uses the packaged UI, resolves real InkView with `RTLD_NOW`, starts the worker through the private loader, installs/searches/fetches chapters/downloads, verifies **1/1 progress across IPC**, deliberately crashes the worker and retries, rejects an unsupported protocol version, verifies EOF and idle exit/restart, and checks process mappings. Strict runs print proof that raw ARM statx/getrandom return `ENOSYS`.
- Additional `--parent-exit --deny-new-syscalls` runs on **both roots** bypass UI cleanup with `_exit` after JVM startup. Both confirm the worker exits; it does not survive its UI.
- Separate final ELF audits: 6.9 UI **27 objects / 1,555 versioned imports**; 6.10 UI **26 / 2,369**; worker on either root **29 objects**, with **1,473 / 1,474 imports** respectively. All required versioned imports resolve. UI and worker use their intended GNU runtime sets independently.
- Additional **live HTTPS with strict guest syscall denial** passes too: the custom `/qemu-arm -L /work/dist/test-sysroot` ran the private loader and packaged worker in `repo` mode with `QEMU_POCKETMANGA_KERNEL310=1`, `QEMU_UNAME=3.10.65`, `POCKETMANGA_EXPECT_ENOSYS=1`. It returned the same 1,443 extensions, covering native libtachi/Zig DNS/TLS as well as the fixture's Java DNS/HTTP.
- Python syntax checks and `git diff --check`: pass. Archive inspection verifies all **17 runtime/lib files** match their individual pinned hashes; no InkView, firmware image, Debian archive or emulator is shipped. All fixture containers were stopped.

Final RSS samples during the four firmware fixture runs:

- 6.9 native firmware run: UI alone **12,828 KiB**; worker at download completion **81,664 KiB**.
- 6.9 with missing post-3.10 syscalls: UI **13,480 KiB**; worker **79,812 KiB**.
- 6.10 native firmware run: UI **13,776 KiB**; worker **81,728 KiB**.
- 6.10 with missing post-3.10 syscalls: UI **14,472 KiB**; worker **79,792 KiB**.

The initial archive was **90,439,744 bytes**, with **186,811,574 bytes** of regular bundle files (198 files). The final archive is **92,891,455 bytes**, with **195,103,581 bytes** (215 files): increases of **2,451,711 bytes compressed** and **8,292,007 bytes unpacked**. The archive's SHA256 is `1f756e66f0d9e7cd18d44e0d119cbfcec603cb71a63ce7b3a8f5b711e1233155`, also written to `dist/pocketmanga-verse.tar.gz.sha256`.


RSS is sampled from each process's `/proc/self/status`, so it includes QEMU and its translation overhead. UI samples are after real InkView relocation and before `InkViewMain`/framebuffer allocation; worker samples are at the fixture download's completion/progress response. They are not device peaks. JVM settings remain **Xms16m, Xmx128m, Xss512k, MaxMetaspaceSize=96m, SerialGC, ActiveProcessorCount=2**. They were not tuned based on emulation.

## Files changed

- `build.zig`: independent 2.23 UI and 2.39 worker builds; C compatibility bridge.
- `src/online.zig`, `browser.zig`, `session.zig`, `ui.zig`, `library.zig`: UI-only data flow and process client; local scans/reading stay local.
- `src/worker_engine.zig`, `worker.zig`, `worker_client.zig`, `worker_wire.zig`, `protocol.zig`, `source_models.zig`: JNI executor, worker lifetime, IPC and wire DTOs.
- `src/device_io.zig`, `posix_compat.c`, `inkview.zig`: old-kernel I/O, fork/exec ownership and InkView task lifecycle.
- `src/runtime_probe.zig`, `worker_probe.zig`, `tests.zig`, `online_test.zig`: split diagnostics, progress, crash/retry, version/EOF/idle/parent-exit and offline tests.
- `tools/pocketmanga.app`, `package_device.py`, `runtime-packages.json`, `FIRMWARE-RUNTIME-NOTICE`, `runtime-licenses/`: native UI launcher, pinned private worker runtime, licenses and archive checksum.
- `tools/prepare_firmware.py`, `audit_runtime.py`, `test_firmware_runtime.py`, `Dockerfile.firmware-test`, `Dockerfile.kernel310-test`, `patch_qemu_kernel310.py`, `kernel310-launch.sh`, fixture files and `test_arm_runtime.py`: reproducible extraction and ARM/firmware verification. `pocketmanga-log.app` and `Dockerfile.arm-test` keep their existing behavior.
- `README.md` and this report: installation, build, architecture and evidence.

No sibling dependency change is required.

## Device checks and installation

Hardware still needs to settle actual UI refresh/decoding, Wi-Fi dialogs and their modal lifecycle, foreground/background/suspend behavior, real peak RAM/startup time, and the exact 6.8 firmware's library/NSS differences from 6.9. The container deliberately stops before `InkViewMain`; it cannot exercise the monitor, panel or drivers. The event wrapper and parent-death/EOF ownership reduce orphan risk even if a modal handler receives exit differently. Later Verse firmware is expected to preserve this ABI, but the concrete images tested are 6.9.862 and 6.10.1461.

1. Build/package as documented in README, or use `dist/pocketmanga-verse.tar.gz` and its `.sha256` file.
2. Connect the reader by USB in PC link mode. Extract the archive at the **storage root**, merging its `applications/` folder. Equivalently copy the contents of `dist/applications/` into the reader's `applications/`.
3. The resulting layout must include `applications/pocketmanga.app`, `applications/pocketmanga-log.app`, `applications/pocketmanga/bin/pocketmanga`, `applications/pocketmanga/bin/pocketmanga-worker`, and the entire `applications/pocketmanga/runtime/` (lib, jre, host jar, CA stores, provenance/licenses). Preserve existing `library.json`, `progress.json`, `extensions/`, `downloads/` and local title folders. The worker is not an Applications-menu entry.
4. On macOS remove AppleDouble files with `dot_clean` on the reader's applications folder, then eject. Start **pocketmanga-log** first; read `applications/pocketmanga.log` after a launch/browse/download/read/background/close cycle. No system libraries or firmware files are replaced.

No deployment, push, commit, stash, sudo, physical-device or disk write was performed by this implementation.
