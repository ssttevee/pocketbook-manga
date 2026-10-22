# Reader completion wake verification

PocketManga disables periodic task polling on the PB629 and keeps task sleep
protection until results are delivered and task cleanup completes. Physical
testing on this reader supports completion-driven delivery while protected.
The platform library retains its conservative 100 ms default for other hosts.
PocketManga also retains fallback ticks on firmware without paired sleep
preventors, because its alternative `BanSleep(10)` protection expires and must
be renewed during long decodes. The tested PB629 reports both preventor symbols.

The firmware's named preventor maintains its own three-second timer while a
token is active. That keeps the normal event loop awake; it is retained. The
removed timer is PocketManga's additional 100 ms task-completion poll.

## Verified firmware behavior

Against the actual ARM InkView libraries from firmware 6.9 and 6.10:

- `SendEvent` appends to a process-local queue. The optional event notifier is
  invoked on the producer thread; it is not a UI-thread callback or a suspend
  interrupt.
- `SendEventTo(GetCurrentTask(), ...)` sends monitor request `0x50d` with a
  16-byte event payload. Concurrent callers have separate thread-local buffers.
- The monitor IPC path holds a process-wide mutex while waiting for its reply.
  `hw_sleep` uses the same path for request `0x10a`.

An ARM/QEMU transport test ran the firmware's IPC threads, mutexes and condition
waits unchanged, intercepting only `msgget`, `msgsnd` and `msgrcv` at the absent
monitor boundary. With the sleep reply withheld, a worker's completion event
could not reach `msgsnd`. It advanced only after that reply was released. The
result was identical on both firmware versions. A separate 256-call/eight-thread
check found no payload corruption.

This rules out treating self-directed monitor IPC as a guaranteed wake from an
outstanding sleep request. It does not measure physical suspend or demonstrate
that the existing local queue is insufficient while sleep protection is held.
The transport harness and logs are temporary development artifacts under
`/tmp/pocketmanga-ipc-wake/`; proprietary firmware is not part of the repository.

## Physical PB629 results, 2026-10-21

The valid run reported `GetSleepmode=1`, `IsUSBconnected=0`, and
`QueryNetwork=2`: Wi-Fi hardware was present, with `NET_CONNECTED` clear.
The first Wi-Fi-on attempt was replaced by this disconnected run.

| Sleep protection | Trial | Worker elapsed | Completion delivery | Total | Host hard timers | Input |
|---|---:|---:|---:|---:|---:|---|
| Enabled | 1 | 3000 ms | 1 ms | 3001 ms | 0 | None |
| Enabled | 2 | 3000 ms | 4 ms | 3005 ms | 0 | None |
| Enabled | 3 | 3000 ms | 7 ms | 3007 ms | 0 | None |
| Disabled | 1 | 27547 ms | 8 ms | 27556 ms | 1 | Yes |

The protected run passed all three trials with ordinary `SendEvent` and no
host periodic or safety hard timer. The unprotected control failed after user input;
its three-second awake-clock wait consumed 27.5 seconds of boot-clock time,
consistent with CPU suspension during the work. The immediate frame timer
recorded after that intervention does not constitute an untouched completion.

These results justify disabling PocketManga's periodic fallback while retaining
the sleep guard. They do not establish that every firmware version or power
state behaves the same way. Keep the guard active through result processing and
cleanup: completion notifications cannot help while the worker itself is
suspended.

## Physical test with polling disabled

Build the standalone diagnostic, using Zig 0.17:

```
Z=/Users/steve/Programs/Zig/v0.17.0/zig
"$Z" build wake-probe -Doptimize=small
```

Copy `zig-out/bin/pocketmanga-wake-probe` to the reader's
`applications/pocketmanga/bin/`, and copy `tools/pocketmanga-wake-test.app` and
`tools/pocketmanga-wake-control.app` to `applications/`. These launchers do not
replace the production app or load its library/settings.

Disconnect USB and turn Wi-Fi off before testing: either can inhibit suspend
and hide the behavior under investigation. Launch **pocketmanga-wake-test** and
do not touch the reader. Three tasks each wait three seconds, then post their
completion through ordinary `SendEvent`. The host's periodic fallback is
explicitly disabled. The app should close itself after about nine seconds.
If it remains open after fifteen seconds, press Back or Close; this is recorded
as an abort. There is no safety hard timer to accidentally rescue the test.

Reconnect USB and inspect `applications/pocketmanga/wake-test.log`. Each trial
must report `PASS`, no user input, `host_hard_timers=0`, delivery below 250 ms,
and total task duration below four seconds. The boot clock includes suspend,
so a worker resuming late cannot produce a misleading fast-delivery pass.
A prompt run with USB/network activity or missing state queries is marked
`INCONCLUSIVE`, and every key/page/pointer event invalidates an untouched run.
The timer counter covers the host's timer API calls, not any firmware-internal
timers that the sleep preventor itself may use.

The optional **pocketmanga-wake-control** launcher repeats the test with the
sleep guard disabled, logging to `wake-control.log`. It may require Back after
fifteen seconds. Compare the guard-on and guard-off results with the logged
sleep/USB/network state. The guarded/control comparison should be repeated after changes to firmware
or power handling; the recorded result applies to the tested device/firmware.

## Reader latency diagnostics

The application log distinguishes reader input, cache lookup, task startup,
visible-frame rendering, speculative preparation, delivery and application.
`input_to_applied_ms` ends after copying pixels and saving progress/preferences;
it does not include drawing or the physical e-ink panel update.

`Reader render` includes both paged and continuous vertical views. Tile counts
separate RAM hits, disk hits and actual decoding. Microsecond totals isolate
image opening, disk reads, decoding and tile writes; these are components of
render time, not additional delays. UI cache lookups report elapsed time
separately because they use immutable disk tiles without entering the decoder.
`progress_ms` and `preferences_ms` identify synchronous persistence costs.

Tile-directory maintenance runs on the serialized reader task after publication
and speculative preparation, never from a visible tile read/write. Its separate
`maintenance_ms` entry includes scanning, sorting and eviction. Initial cleanup
and cleanup due after 1 MiB of writes remain pending if canceled or unsuccessful.
The 64 MiB disk target can temporarily be exceeded until maintenance completes.

The reader task is keyed by navigation generation and external inputs rather
than its accepted anchor. Accepting a continuous frame normalizes the page,
position and pending delta without restarting its still-running prefetch.
Effective navigation advances the generation and cancels obsolete preparation.
When the UI has already installed a cached view, the task prepares subsequent
views without publishing that same frame a second time.

Slow decoder calls log their source dimensions, tile coordinates and elapsed
milliseconds before the cancellation checkpoint. A completed tile discarded by
cancellation is logged separately, even if no visible frame timing is emitted.
A retained old view shows a static “Preparing view…” badge after 300 ms while
its replacement is pending. This is a single UI presentation timer, canceled
when no longer needed; it does not poll tasks or wake decoder completion.
