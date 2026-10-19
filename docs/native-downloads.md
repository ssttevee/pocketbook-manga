# Native chapter downloads

Implementation is on uncommitted branch `native-downloads`, based on app commit `c128c58`. The separate `../zig-tachi-native-downloads` worktree is also on `native-downloads`, based on `051f138`. Nothing was committed, pushed or stashed. The original zig-tachi checkout's README/build/Gradle/embed-tool changes were preserved; none were copied. No physical reader, zig-layout or zig-fabrum-platform-inkview was modified. Neither sibling UI repository needs changes.

## Request planning and native transfer

The UI owns chapter transfer, page persistence and final library publication in `src/downloads.zig`. The worker's `download` operation now only plans requests, through the host's `imageRequests` call. The host obtains the page list, resolves `getImageUrl` only when null, then calls the source's virtual `imageRequest(page)` through a small public bridge. The plan preserves method, URL, ordered headers, cookies matching that URL in the source client's jar, rate rules and an explicit fallback reason. Missing user agents get the same default as the host's UserAgentInterceptor. Keiyoushi's known request-only CookieInterceptor is evaluated for its first matching domain rule and dynamic cookie values, without treating it as an image transform.

For an entirely native plan, the UI immediately releases/reaps the worker before image transfer. One page at a time keeps memory and source traffic bounded. `std.http.Client` performs HTTP, Zig DNS and native TLS; HTTPS uses only the explicit `runtime/ca.pem` roots. `DeviceIo` supplies `/dev/urandom` entropy and the existing old-kernel stat bridges. Its void random entry point now fails closed if urandom cannot supply entropy, rather than using Threaded's weak fallback. Both native TLS and file publication run on the UI's glibc 2.23 target.

A plan containing known JVM fallback pages retains its worker until completion, preserving arbitrary extension interceptor/client state. Native pages in a mixed plan still transfer in the UI. If an initially native response needs fallback, the event thread starts a fresh worker on demand and restores the exported session cookies before `fetchImage`. Keeping fork on the event thread preserves the existing Linux parent-death ownership rule. Reading remains local and never starts a worker.

## Exact fallback policy

The host marks a page for JVM fetchImage if the source request has a body or is not GET; if there is an unknown application/network interceptor (including descramblers, decryptors, request signers and unrecognized limiter/cookie-interceptor layouts); if the client uses a custom proxy, DNS, authenticator, certificate pins, SSL factory or hostname verifier; or if the source explicitly requests a content encoding other than identity. HTTP(S) plain GETs with only the recognized host interceptors, recognized rate limiters and recognized cookie injection are native. Unsupported URI schemes also select JVM fallback.

Native response detection selects JVM fallback for redirects, HTTP 401/403/503, non-identity Content-Encoding, or a body whose signature is not PNG/JPEG. Redirects are deliberately handed to the source client: target URLs may require different cookie paths/domains or different host/predicate rate rules. This Zig 0.17 snapshot does not emit `privileged_headers` in sendHead, so native requests use ordinary extra_headers with redirects disabled; no source credentials can be automatically forwarded to a redirect target. Other network/TLS errors and HTTP failures are surfaced for resumable retry, instead of silently changing clients. Each fallback logs its specific plan reason or native detection error.

Fallback preserves source behavior; it does not promise to solve Cloudflare. The current headless host reports its actionable CloudflareSolver error when no solver is registered. The reader still supports PNG/JPEG; fallback cannot make an unsupported image format readable. Native pages have a 16 MiB limit and a cancellable 120-second deadline. IPC waits have a cancellable five-minute deadline between messages.

## Rate limits

[Mihon's legacy rateLimit and rateLimitHost](https://github.com/mihonapp/mihon/blob/main/core/common/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/RateLimitInterceptor.kt) install a RateLimitInterceptor with `host`, `permits`, and `rateLimitMillis`. The host now supplies those upstream-compatible helper APIs, including [SpecificHostRateLimitInterceptor.kt](https://github.com/mihonapp/mihon/blob/main/core/common/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/SpecificHostRateLimitInterceptor.kt). Their applicable limits are exported conservatively as ceil(period/permits) dispatch spacing.

[Current Keiyoushi limits](https://github.com/keiyoushi/extensions-source/blob/main/core/src/main/kotlin/keiyoushi/network/RateLimit.kt) contain ordered predicate rules, permit windows and minimum intervals. The bridge evaluates the first matching predicate per interceptor and exports max(ceil(period/permits), interval), with a key shared across all requests using that rule. Multiple interceptors apply together. Kotlin's encoded Duration fields are decoded with upward millisecond rounding. Unrecognized or out-of-range shapes fall back to the original JVM client.

Native transfer waits a complete applicable window initially, draining metadata requests made by the JVM, then spaces dispatches. Switching between native and JVM clients drains a full window on each side because the two clients do not share timestamp queues. A new chapter also drains its window, so restarting a worker or retrying cannot reset a source into a burst. This is intentionally stricter than the extension's allowed bursts. Current MangaFox declares 1 request/second and uses the recognized [cookie injector](https://github.com/keiyoushi/extensions-source/blob/main/core/src/main/kotlin/keiyoushi/network/Cookie.kt); those shapes are covered by the bridge. No live MangaFox download was attempted.

## Cancellation, resume and error display

`online.Job` is an `Io.concurrent` future. Canceling it cancels nested transfer/timeout tasks and in-flight socket reads/writes through std.Io; no native download cancellation flag is polled between pages. IPC framing also uses cancellable Io socket operations, including incomplete-frame waits. Cleanup sends a nonblocking cancel command, lets the worker stop for up to 75 ms (plus its small poll granularity), then kills/reaps it if needed. The host cancel call invokes the source client's dispatcher.cancelAll; the worker exits after acknowledging cancellation. Native-only cancellation has no worker to wait for.

Pages stream through a 64 KiB buffer into a deterministic chapter/generation directory. Each page is synced and renamed from .tmp to .png/.jpg only after the complete successful body arrives. Retry skips completed files; incomplete temps are overwritten. Failures/cancellation never delete completed pages. Stable page URLs and indices identify a generation; when no page URL exists, image origin/path is used and expiring query tokens are ignored. Changed stable page identity creates another generation, retaining earlier partial data. The library manifest is atomically replaced only after every page is present.

The store and `pagePath` resolver centralize download paths and reader resolution, providing one location for a future SD-card policy. No SD-card setting is introduced now.

The prior reader transition already worked on successful downloads, as its existing end-to-end UI test confirms. The device failure prevented publication and therefore prevented that transition. The other observed issue was error visibility: the old footer was one small ellipsized line. The new persistent, wrapped failure/cancellation banner includes n/m and resume instructions. Successful download reloads the manifest and opens the pending chapter; entering the reader clears stale notices.

## Compression and measurements

The original removal of okhttp-zstd broke extensions that link to `okhttp3.zstd.Zstd.INSTANCE`. This is corrected by a binary-compatible host object backed by pure Java Aircompressor, with strict-alignment ARM Zero memory access fixes; see [device feedback fixes](device-feedback-fixes.md). The JNI-backed okhttp-zstd dependency remains absent. okhttp-brotli remains; it uses the pure Java `org.brotli.dec.BrotliInputStream` ([OkHttp source](https://github.com/square/okhttp/blob/master/okhttp-brotli/src/main/kotlin/okhttp3/brotli/Brotli.kt)).

Per-page logs report bytes, network_ms, head_ms, body_ms and disk_ms. Head time includes DNS/connect/TLS/response headers, body time includes transfer and native TLS decoding, and disk time includes image writes, sync and rename. Incomplete transfers log bytes_written and their elapsed network/disk time. Chapter logs include completed/total pages, resumed/native counts, bytes, network/disk totals, planning_ms, transfer elapsed_ms and total_elapsed_ms. JVM fallback's UI network timing includes worker/IPC overhead; the diagnostic JVM benchmark times fetchImage directly, avoiding that overhead.

The same three deterministic 512×512 RGBA PNGs total 3,148,428 bytes. Temporary fixture CA trust, Referer, jar cookie and injected cookie are required. The native fixture and direct JVM benchmark both run under ARM soft-float emulation with the same TLS server and source configuration. Startup/metadata are excluded from the transfer comparison, and the JVM benchmark excludes disk writes, making this a transfer comparison rather than full user-visible elapsed time.

Measured runs (milliseconds):

| Firmware/emulator | Native network | Native disk | Native transfer elapsed | JVM fetchImage | Network speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| 6.9.862 | 1,125 | 20 | 1,273 | 49,041 | 43.6× |
| 6.10.1461 | 1,100 | 22 | 1,252 | 48,977 | 44.5× |
| 6.9, post-3.10 syscalls denied | 1,186 | 27 | 1,332 | 63,428 | 53.5× |
| 6.10, post-3.10 syscalls denied | 1,191 | 119 | 1,434 | 62,939 | 52.8× |

Normal-emulator network throughput is about 2.67–2.73 MiB/s native versus 0.061 MiB/s JVM. These are rough emulation results, not Wi-Fi/device predictions. Concurrent emulator runs and filesystem scheduling affect them. They support the hypothesis that JVM TLS/Zero processing is costly for this workload; they do not isolate TLS from every other JVM cost or measure fanfox.net.

## Verification

- Zig 0.17.0 `zig build test`: 21/21 Debug tests passed. ReleaseSmall tests and ARM device/runtime-probe builds passed. Tests cover resume and signed token renewal, completed versus partial files, cancellation of a real stalled native body, cancellation during an incomplete IPC frame, native/fallback decisions, shared rate spacing and persistent rendered error text. The existing UI test still downloads and enters the reader.
- Modified host `./gradlew shadowJar --offline -q`: passed. No original uncommitted build changes were needed.
- ARM `sources`, `repo`, `fixture`: passed. Live repository HTTPS returned 1,443 entries. Fixture verifies null imageUrl resolution, imageRequest Referer, source cookie jar, request-only cookie injection and both limiter layouts. Its modern limiter is a shape fixture; the legacy limiter is the actual host implementation.
- Firmware 6.9.862 and 6.10.1461, normal and `--deny-new-syscalls`: passed. Native UI TLS downloads, Zig DNS, authentication, progress, publication, worker release, crash/retry, version rejection, EOF/idle exit and isolated process mappings are exercised. The strict tests verify raw ARM statx/getrandom ENOSYS and deny all post-3.10 calls in the guest emulator.
- Strict 6.9 `--cancel-resume`: passed. Stalled-body cancellation returned Canceled in 1 ms; retry logged resumed=1 and fetched only the remaining two pages before publication.
- Strict 6.10 `--redirect`: passed. Three native redirect detections restarted workers, restored session cookies, fetched through the source JVM client and published the chapter.
- ELF audits passed for both processes on both roots: UI 27/26 objects and 1,554/2,368 imports; worker 29 objects and 1,473/1,474 imports. UI remains independent of the bundled GNU runtime/JVM.
- Python syntax checks and both repository diff whitespace checks passed. The final dist bundle is rebuilt; test certificates/private keys only exist in temporary test/container copies.

Fixture logs and timing evidence are under `dist/firmware-tests/`. The historical firmware report remains in `docs/firmware-6.8.md`.

## Files changed

App: `build.zig.zon`; new `src/downloads.zig`; `src/online.zig`, `worker_client.zig`, `worker_wire.zig`, `protocol.zig`, `worker_engine.zig`, `worker.zig`; `src/device_io.zig`, `posix_compat.c`, `inkview.zig`; `src/browser.zig`, `session.zig`, `ui.zig`; `src/tests.zig`, `online_test.zig`, `runtime_probe.zig`, `worker_probe.zig`; `tools/fixture/FixtureSource.java`, new `CookieInterceptor.java` and `RateLimitInterceptor.java`, `server.py`; `tools/test_arm_runtime.py`, `test_firmware_runtime.py`, `package_device.py`; `README.md`, `docs/firmware-6.8.md`, this report. Ignored dist/ binaries, runtime, archive/checksum and test logs were regenerated.

Isolated libtachi worktree: `host/build.gradle.kts`, `host/gradle/libs.versions.toml`; new `host/src/main/kotlin/dev/tachi/host/ImageRequests.kt`; `SourceCalls.kt`; `host/src/main/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt`; new `host/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/RateLimitInterceptor.kt` and `SpecificHostRateLimitInterceptor.kt`; `docs/API.md`. No libtachi Zig implementation or original build scripts were changed.

## Device follow-up

Deploy the rebuilt archive yourself, preserving library/progress/extensions/downloads. Use pocketmanga-log. Confirm MangaFox pages log native transfers rather than an unexpected interceptor fallback, with roughly 1-second minimum dispatch spacing. Check planning_ms versus head_ms/body_ms/disk_ms to distinguish metadata, connection/TLS/transfer and storage costs. Cancel during an image, retry, confirm n/m resumes and the reader opens on success. Verify clear persistent messages for a failed chapter and any CloudflareSolver failure. Actual firmware 6.8 networking, Wi-Fi/panel lifecycle, peak RAM and website behavior still need a device run; containers stop before InkViewMain.
