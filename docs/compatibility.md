# PocketBook compatibility and community testing

PocketManga has been used on a physical **PocketBook Verse PB629 running firmware 6.8**. Other combinations have different levels of evidence. An app passing in firmware emulation does not prove that its screen, controls, Wi-Fi or sleep behavior works on a physical reader.

You do not need to update your firmware to use PocketManga. Choose a release for the firmware already installed on your reader. Check **Settings → About device → Software** for the complete version, including the model prefix and final build number.

## Which release to choose

Installation bundles will be listed on [GitHub Releases](https://github.com/ssttevee/pocketbook-manga/releases). A source-code download is not an installation bundle. If there is no published release yet, prebuilt downloads are not available yet.

| Firmware range | Runtime profile | Installation bundle | Evidence |
| --- | --- | --- | --- |
| 6.8–6.9 on classic ARMv7 models | ARM EABI soft-float calls, glibc 2.23 | `pocketmanga-armv7-softfp-glibc-2.23.tar.gz` | Physical PB629 on 6.8; official PB629 6.9.862 firmware checked in emulation |
| 6.10 on classic ARMv7 models | ARM EABI soft-float calls, glibc 2.39 | `pocketmanga-armv7-softfp-glibc-2.39.tar.gz` | Official PB629 6.10.1461 firmware checked in emulation; physical check pending |
| Later firmware, including 6.11 | Not established for this app | None claimed | Requires a firmware and device-specific check |

These are separate build profiles, even though a program built for an older glibc can sometimes run on a newer one. Each shipped profile must have its own runtime checks. Do not infer support from the firmware number alone: some PocketBooks use a different ARM calling convention and loader.

“Soft-float” here describes how functions pass floating-point arguments. The build still uses the ARMv7 processor's floating-point hardware. It requires an ARMv7 CPU with the expected VFP/NEON features, a matching Linux userland and InkView libraries. A 64-bit CPU or kernel does not establish the application's userland ABI.

## Hardware matrix

**Hardware checked** means PocketManga was exercised on a physical reader. **Firmware checked** means its binaries and runtime were checked against an extracted official firmware in emulation. **Theoretical candidate** means related hardware and a Linux/InkView platform make testing worthwhile; it is not a promise that the app launches or behaves correctly.

| Reader | Hardware checked | Firmware/emulation checked | Current assessment |
| --- | --- | --- | --- |
| Verse PB629 | Yes, firmware 6.8 | PB629 6.9.862 and 6.10.1461 | Reference device; 6.10 hardware testing still needed |
| Verse Pro PB634 | No | No model-specific check | Theoretical candidate with a matching ARMv7 soft-float firmware |
| Verse Lite PB619 | No | No model-specific check | Theoretical candidate; touch-only controls need checking |
| Era PB700 / Era Lite PB710 | No | No model-specific check | Theoretical candidates; rotation and side-button behavior need checking |
| InkPad 4 PB743G | No | No model-specific check | Theoretical candidate; screen layout and memory use need checking |
| Verse Pro Color PB634K3 | No | No model-specific check | Theoretical candidate; framebuffer and refresh behavior need checking |
| Era Color PB700K3 | No | No model-specific check | Theoretical candidate; framebuffer, refresh and rotation need checking |
| InkPad Color 3 PB743K3 | No | No model-specific check | Theoretical candidate; framebuffer, refresh and screen layout need checking |
| InkPad One PB1030 / RK3566 platform | No | No | Unsupported by these bundles; requires an ARM hard-float build and matching native runtimes |
| Older models or firmware below 6.8 | No | No | Unsupported until CPU, memory and InkView requirements are established |
| InkPad Eo, InkPad Eo 2, Color Note | No | Not applicable | Android models; this Linux/InkView application bundle does not apply |

All image rendering is currently grayscale, including on color readers. A device's inclusion as a theoretical candidate does not confirm its CPU features, ABI or glibc version. Those must be checked for the exact firmware before claiming support.

## What the firmware checks establish

The preserved official PB629 firmware images let us keep testing the older userspace after a reader is upgraded. No physical downgrade or rollback is needed for those checks. The roots and proprietary firmware libraries stay outside the repository and release bundles. See [development and verification](development.md) for extraction and test commands.

The existing checks use the firmware's own loader, glibc and InkView libraries up to symbol resolution, then exercise the worker, JVM and UI/worker protocol. They also cover restricted old-kernel syscall behavior. They stop before the real InkView hardware event loop. This preserves useful regression coverage but cannot replace physical checks of display refresh, touch, buttons, networking dialogs, sleep/wake, battery use or peak memory. A saved firmware archive is not a guarantee that the reader can be downgraded.

Direct inspection of the extracted official firmware establishes:

| Official PB629 firmware | libc banner | libc and InkView ELF flags | Calling convention |
| --- | --- | --- | --- |
| U629.6.9.862 | GNU C Library, version 2.23 | `0x05000200` | ARM EABI5, soft-float |
| U629.6.10.1461 | GNU C Library, version 2.39 | `0x05000200` | ARM EABI5, soft-float |

[The extraction tool](../tools/prepare_firmware.py) verifies the official archive checksums before extracting them. The 6.8 profile is also supported by physical PB629 testing and the project's glibc 2.23 runtime investigation; the preserved 6.9 root is a stand-in for userspace checks, not an exact copy of the physical 6.8 system. The [Java runtime notes](java-runtime.md) and [reader wake investigation](reader-wake.md) describe those checks and their limits.

Public references:

- [PocketBook's official SDK 6.8 release](https://github.com/pocketbook/SDK_6.3.0/releases/tag/6.8) identifies its target firmware range. This alone does not certify PocketManga on all of those devices.
- [Official Verse 6.10.1461 release notes](https://support.pocketbook-int.com/fw/629/u/6.10.1461/rn/ww/RN_PB_Verse_EN.pdf) describe the system-framework upgrade. The exact glibc version above comes from the firmware binary, not that announcement.
- Official specifications for [Verse](https://pocketbook.ch/en-ch/catalog/e-readers/verse-brightblue-ch), [Verse Lite](https://pocketbook.ch/en-ch/catalog/e-readers/pocketbook-verse-lite-ch), [Era](https://pocketbook.ch/en-ch/catalog/e-readers/pocketbook-era-ch) and [Era Color](https://pocketbook.ch/en-ch/catalog/color-e-readers/pocketbook-era-color-ch) establish their Linux platform and hardware specifications, but do not publish a complete binary-compatibility contract.
- [Official InkPad One specifications](https://pocketbook.ch/en-ch/catalog/e-notes/pocketbook-inkpad-one-ch) identify the RK3566 platform. [KOReader's device implementation](https://github.com/koreader/koreader/blob/master/frontend/device/pocketbook/device.lua) assigns PB1030 its separate `pocketbookhf` target and documents model-specific display/control quirks. [InkShelf's hardware report](https://github.com/N-Combinator/inkshelf#which-file-do-i-need) records the different hard-float loader and a physical PB1030 check for that application, not PocketManga.
- PocketBook identifies [InkPad Eo](https://pocketbook.ch/en-ch/news/pocketbook-inkpad-eo-news-ch), [InkPad Eo 2](https://pocketbook.ch/en-ch/news/pocketbook-inkpad-eo-2-news-ch) and [Color Note](https://pocketbook.ch/en-ch/catalog/e-notes/pocketbook-color-note-ch) as Android devices.

## Help test another reader

Please keep your current firmware for an initial test. Back up your PocketManga folder if upgrading an existing installation. Install the matching bundle using the [README instructions](../README.md#download-and-install), then launch **pocketmanga-log** to collect diagnostics. Do not change system libraries or flash a different firmware just to test the app.

Check these operations and report failures as well as successes:

1. Launch, switch tabs, close, and launch again.
2. Browse an extension, search, open a series and download a chapter. Record the source name so a source-specific error can be distinguished from a device issue.
3. Pause and resume a download; read a completed chapter with Wi-Fi off.
4. Try paged and continuous vertical reading, long images, touch controls and any physical page buttons.
5. Reveal and hide the reader controls; check layout, refresh artifacts and rotation if available.
6. Sleep and wake the reader, return from another application, and close PocketManga. Note any freeze, unexpectedly slow operation or worker remaining active.
7. If applicable, test SD-card downloads and moving downloaded chapters between disks.

Copy this report into a [GitHub issue](https://github.com/ssttevee/pocketbook-manga/issues), or include it with a community-forum report:

```text
Reader name and exact model number:
Complete firmware version (for example U629.6.10.1461):
PocketManga release and bundle filename:
Fresh installation or upgrade:

Launch / close / relaunch:
Browse / search / source tested:
Download / pause / resume / offline reading:
Paged / continuous vertical / long images:
Touch / physical buttons / rotation:
Screen refresh and layout:
Sleep / wake / return from another app:
SD card, if tested:

Problem, steps to reproduce and approximate time:
Log attached (applications/pocketmanga.log):
```

Review logs before posting: they can contain source URLs, chapter names and local paths. Remove private information while preserving the error and nearby timing lines. A report with the exact model, complete firmware and bundle filename is needed before changing a matrix entry to hardware checked. When a new firmware is tested, retain the older confirmed result rather than treating all firmware on that model as equivalent.
