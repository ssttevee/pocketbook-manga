# Reader completion wake verification

The production app keeps the 100 ms pending-task fallback and task sleep
protection. This investigation does not establish that both are required.

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
sleep/USB/network state. Success in the guarded test would support removing
periodic polling for this device/firmware; it does not prove behavior across all
firmware versions or device power states.
