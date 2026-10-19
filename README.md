# hackintosh-feature-test

> **Heads up:** a good portion of this code is AI generated. I do understand how it works,
> and I'm happy to explain any of it. If something looks wrong or you have a question,
> open an issue or ping me on Discord (`watchthelight`).

A feature test for macOS on PC hardware. It runs 119 checks over graphics, display, video, audio, input, network, Bluetooth, Apple services, power, storage and system services, and writes a table of what works, what half works and what does not, with the raw output of every check saved next to it.

I wrote it to check a Hackintosh laptop after a driver or config change without clicking through System Settings for an hour. Most checks run on their own. The ones that need a human (does the keyboard backlight change, does AirDrop see the phone) open a dialog and ask.

The checks are plain commands (`system_profiler`, `ioreg`, `pmset`, `networkQuality` and so on) plus eight small Swift and Objective-C programs that use the real frameworks: Metal, Metal Performance Shaders, Core Image, VideoToolbox, AVFoundation, ScreenCaptureKit, CoreGraphics and CoreAudio. A GPU probe passes only if it drew or computed something and the result read back matches what the CPU expects, not because a property says it is supported.

## What it tests

Fourteen areas. Each line in the result table gets one status: Pass, Degraded, Fail, N/A, Skipped, Not tested (no equipment), Not tested (risky), Not tested (needs a person), Error, or Review (a screenshot waits for someone to judge it).

| Area | Automatic checks | Pass means |
|---|---|---|
| Platform | macOS version, model, SIP and AMFI, third-party kexts, boot-args, boot framebuffer address from the OpenCore log, kernel panics, crash reports and shutdown stalls since boot | no panics since boot; crash reports or stalls make it Degraded |
| GPU and Metal | `system_profiler` Metal support, GPU kexts, `metalcaps`, `mtlfeat`, `mpsci`, and the nvidia-macos-driver test tools if you have that checkout (metal_selftest, glbench, OpenGL MSAA sample positions, OpenCL oracles) | Metal 3 family reported; every render, compute, blit, mesh, tessellation, ray tracing, format and IOSurface check reads back the right pixels; MPS and Core Image on the GPU match the CPU within a small tolerance |
| Display | every CoreGraphics mode, refresh rate, a mode switch held for 10 s, gamma table round-trip, EDR headroom, brightness set and read back, hardware cursor | the change took effect and was put back |
| Desktop and UI | guided: Dock and menus, Control Center, System Settings icons, Launchpad, Mission Control, minimize, Spotlight, Quick Look, Photos, Safari | the person at the machine says so |
| Video and media | VideoToolbox hardware decode and encode per codec, AVPlayer playback of generated H.264 and HEVC clips, screenshot and ScreenCaptureKit capture, webcam frame | hardware decode for H.264 and HEVC with every frame decoded; playback delivers frames with no black ones; capture frames are not black |
| Audio | device list, output volume set and read back, 3 s microphone recording, which driver owns the codec | volume change sticks and is restored; mic RMS above silence |
| Input | guided: keyboard, backlight, trackpad scroll, pinch, gestures, tap to click, USB mouse | the person says so |
| Network | Wi-Fi association, PHY and channel, scan results, DNS, `networkQuality` speed, AWDL, Ethernet link, Wi-Fi off and on (only with `--risky`) | link active, at least one network in the scan, over 100 Mbit/s down |
| Bluetooth and Continuity | controller state, devices; guided: Handoff, Universal Clipboard, AirDrop, Instant Hotspot, Continuity Camera, iPhone Mirroring, Apple Watch unlock, Find My, Messages | controller on |
| Apple services | Software Update reachable (lists only); guided: Apple Account, iCloud Drive, FaceTime, App Store, Music, Siri | the catalog answers |
| Power and thermal | battery health and readings, whether the battery temperature changes at all, power assertions, CPU frequency and package power under load | battery condition reported; a temperature that never moves is Degraded (not a live sensor) |
| Storage and USB | NVMe SMART status, 4 GB sequential write and read, USB devices, Thunderbolt or USB4 controller, FileVault, Time Machine | SMART verified; both directions over 1000 MB/s |
| System services | Spotlight indexing, time sync, Gatekeeper, Location Services, notifications, sharing services | the service answers |
| Reliability | WindowServer PID and crash report count at the start and end of the pass | same WindowServer, no new crash reports |

Some checks are listed but never run, with the reason in the table: sleep and wake, a GPU job long enough to trigger the watchdog, and anything that needs equipment the test cannot assume (external monitor, headphones, USB-C devices).

`python3 ft.py run --pass A --dry` prints the whole list with what each probe needs.

## Requirements

- macOS 15 or 26 on x86_64. Developed on macOS 26.7.1.
- Xcode Command Line Tools (`xcode-select --install`) for `clang` and `swiftc`. The system `python3` is enough.
- For the four sudo probes (disk speed, CPU power, Location Services, sharing services): the account password in `FT_PW`. Without it they are Skipped.
- Optional: a checkout of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) for its GPU test tools. Point `FT_NVGFX_SRC` at it (default `~/src/nvidia-macos-driver`). Without it those four probes are N/A.
- Optional: the EFI partition mounted (or `FT_OCLOG_DIR` set to the folder with `opencore-*.txt`) for the boot framebuffer probe.

## Build

```
zsh probes/build.sh              # all probes into probes/bin/
zsh probes/build.sh mtlfeat      # just one
```

Only compiler errors are printed. It ends with the list of what is in `probes/bin/`.

## Usage

```
python3 ft.py run --pass A                       # every automatic probe
python3 ft.py run --pass A --area gpu,video      # some areas
python3 ft.py run --pass A --only gpu.mtlfeat    # one probe
python3 ft.py guided --pass A                    # the human checks, one dialog each
python3 ft.py report A                           # writes summary.md
python3 ft.py report A B                         # and diff.md: every line that changed between the passes
```

A pass is just a name. I run pass A, change one thing (a kext, a driver build, a boot-arg), reboot and run pass B, then `report A B` shows what moved.

Options and environment:

| | |
|---|---|
| `--out DIR` (before the subcommand) or `FT_OUT` | results folder, default `./results` |
| `FT_DATE` | the date folder to use, so passes from two days land side by side |
| `--risky` | also run the probes marked risky (today: Wi-Fi off and on) |
| `--no-ask` | no Continue / Skip dialog before probes that change the screen or play sound |
| `guided --auto` | take a screenshot for each guided item that can be judged from a still image, mark it Review and move on; the rest become Not tested (needs a person) |
| `set --pass A <id> <status> <note>` | record a judgement afterwards, for example after looking at the `--auto` screenshots |
| `FT_PW` | password for the sudo probes; read from the environment, never written anywhere |
| `FT_GUARD_FILE` | path to a JSON file a driver rollback guard keeps while it waits for you to confirm a boot. GUI probes wait until it is gone or has a `result` key, so the test does not move windows around while you are supposed to be looking at the screen. Leave it unset if you have no such guard |

Probes that open apps, change the display mode or brightness, or play sound ask first (a dialog with Skip that times out to Continue after 20 s). The camera, microphone and screen recording probes trigger the usual macOS permission prompts for Terminal the first time.

## Results

```
results/2026-10-19/A/
  results.jsonl        one line per probe run; a later run of the same probe replaces it in the report
  <probe id>.txt       the command, its exit code and time, and everything it printed
  <probe id>.png       screenshot of a guided item
  summary.md           the table, one section per area
results/2026-10-19/diff.md
```

A `results.jsonl` line:

```
{"id": "plat.os", "area": "platform", "feature": "macOS version", "pass": "A", "kind": "info", "time": "2026-10-19T13:39:50", "status": "Pass", "value": "26.7.1", "note": "", "evidence": "2026-10-19/A/plat.os.txt", "seconds": 0.0}
```

and the matching part of `summary.md`:

```
## 2. GPU and Metal

| Feature | Status | Measured | Note |
|---|---|---|---|
| Third-party GPU kexts | Pass | as.vit9696.WhateverGreen (1.7.1); com.nullmoth.NVRMFB (2.3.7); ... |  |
| Metal device capabilities | Pass | YES | see evidence for every family and limit |
| nvidia-macos-driver metal_selftest | N/A |  | needs ${FT_NVGFX_SRC:-$HOME/src/nvidia-macos-driver}/tools/metal_selftest.sh |
```

The evidence files hold whatever the commands print, and some of that is personal: `system_profiler` lists display and device serial numbers, the Wi-Fi probes show network names and addresses, boot-args are there too. Read them before you post them anywhere. `summary.md` only has short values (model, boot-args, kext names), so it is usually fine to share.

## Status

Tested on a Lenovo Legion 5 15IAX10 (Core Ultra 9 275HX, RTX 5070 Laptop driving the panel through the nullmoth NVIDIA driver, our NvGfx fork of it) with macOS 26.7.1 (25G241), SDK 26.5 Command Line Tools. Two full passes ran there on 2026-10-18 with the version this repo was taken from (pass A: 72 Pass, 12 Degraded, 7 Fail). That version also had probes for tools that only exist on that laptop; they were removed here. This repo's copy was checked with a build of all eight probes and a run of a handful of automatic probes.

Not tested yet: any AMD or Intel only machine, a desktop, macOS 15. The interface names come from `networksetup`, so they should work anywhere, but a Wi-Fi card that macOS lists as Ethernet (itlwm) will show up under Ethernet.

## How it works

`probes.py` is a list of dictionaries: a shell command and a function that reads its output and returns a status, a measured value and a note. `ft.py` runs them, saves the output, and builds the tables. The Swift and Objective-C probes print one `ok`, `FAIL` or `refused` line per check, and the runner counts them. Details, including how each status is decided: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Licence

ISC. See [LICENSE](LICENSE).
