# How it works

There are three parts: the probe list (`probes.py`), the runner (`ft.py`), and eight compiled probes (`probes/`). The runner knows nothing about any one feature. Everything specific lives in the probe list.

## A probe

Each entry in `probes.PROBES` is a dictionary built by one of three helpers:

- `a(id, area, feature, cmd, check, ...)`: an automatic probe. `cmd` is a shell command, `check` a function that gets the exit code and the output and returns `(status, value, note)`. `kind="info"` marks a probe that only records something (macOS version, boot-args); it is Pass when it ran.
- `g(id, area, feature, prompt, prep, cleanup)`: a guided check. `prep` opens the thing to look at (an app, a web page, a notification), the runner takes a screenshot, then asks the question in a dialog.
- `nt(id, area, feature, status, note)`: a line that is never run, only listed, with the reason. Sleep and wake are in here, because a failed wake on a Hackintosh can mean a hard reset.

Fields every probe can have:

| Field | Meaning |
|---|---|
| `needs` | `gui`, `sound`, `pointer`: the probe changes what is on screen, plays sound or moves the mouse. The runner asks before running it and waits for `FT_GUARD_FILE`. `sudo`: the command uses `SUDO `, which the runner replaces with `sudo -S` fed from `FT_PW`. `risky`: only runs with `--risky`. |
| `req` | a path that must exist, for example a tool from another checkout. If it does not, the probe is N/A with the path in the note. |
| `passes` | `"AB"` by default. A probe that only makes sense on one side of a comparison can be limited to `"A"` or `"B"`. |
| `timeout` | seconds before the command is killed (status from its partial output). |

Commands run under `/bin/zsh -c` with three variables set: `FT_HERE` (the repo folder, so `$FT_HERE/probes/bin` finds the compiled probes), `FT_OD` (this pass's results folder, for probes that leave files) and `FT_REPO` (the results root).

## Judging

The check functions in `probes.py` are small and shared:

| Helper | Pass | Degraded | Fail |
|---|---|---|---|
| `has(rx)` | the regex matches; the first group becomes the value | when `fail="Degraded"` is given, a missing match is Degraded instead of Fail | no match |
| `num(rx, lo, hi, degraded=(lo2, hi2))` | the first number is inside `[lo, hi]` | it is inside the degraded band | outside both, or no number |
| `tally(okrx, badrx, refusedrx)` | every result line is ok | some lines are bad | no line is ok |
| `zero(rx, what)` | nothing matches (no panics, no stalls) | | anything matches |
| `lines_value(rx)` | exit code 0; every match is joined into the value | | non-zero exit |

Some probes have their own lambda instead, for example the crash report count (any report since boot is Degraded) or the battery temperature (a value that does not change over three minutes is Degraded, because it is a fixed number from a battery patch, not a sensor).

If a check function raises, the status is Error: that is a bug in the probe, not a broken feature.

## The compiled probes

Each one prints one line per check: `ok <name> <detail>`, `FAIL <name> <why>`, or for things the device says it does not support, `refused <name> <why>` (`none` in `vtprobe`). The runner counts these with `tally`, so a probe with 14 checks gives one line in the table, `13 ok, 1 bad`, and the failing names in the note.

- `metalcaps` asks the default Metal device for its GPU families, tiers, limits, sample counts and counter sets. Pass is only the Metal 3 family; the rest is in the evidence file.
- `mtlfeat` compiles Metal shaders at runtime and uses each feature: clear, triangle, 4x MSAA resolve, a million-element compute add, shared and private blits, an indirect command buffer, a mesh shader, tessellation, a visible function table, a ray tracing hit and miss, ten pixel formats, rendering into an IOSurface the CPU then reads, a GPU address inside an argument buffer, and a sparse heap. Every one reads its result back and compares it with the expected value. A driver can claim `supportsRaytracing` and still return zeros; this catches that.
- `mpsci` runs an MPS Gaussian blur, a Core Image filter chain and an MPS matrix multiply on the GPU and the same work on the CPU, and compares them within a tolerance.
- `vtprobe` checks which codecs have a hardware decoder, opens hardware-only encode sessions for H.264 and HEVC, writes 1080p and 4K clips, and decodes them through a session that reports whether the hardware decoder was used.
- `avplay` plays those clips through `AVPlayer` with a video output, the path QuickTime and Safari use, and counts frames and black frames.
- `capture` takes a `screencapture` image and a 3 s ScreenCaptureKit stream, or one webcam frame, and checks they are not black.
- `display` lists modes, switches mode for 10 s, writes and restores the gamma table, reads EDR headroom, and sets and restores brightness through `IODisplayConnect`. Everything it changes it puts back and prints before, set and restored values.
- `audio` lists CoreAudio devices, sets and restores the output volume, and records 3 s from the default input.

## Passes and the report

A pass is a name, usually A and B. Results append to `<out>/<date>/<pass>/results.jsonl`, and the newest line for a probe wins, so a probe can be run again on its own after a fix. `report A` builds `summary.md` from the newest results, one table per area, and gives probes that never ran a Not run line. `report A B` also writes `diff.md` next to the pass folders with every probe whose status or value changed.

`guided --auto` exists for unattended runs: it takes a screenshot for each guided item that can be judged from a still picture (the `SHOT` set in `probes.py`), marks it Review, and the screenshots get judged later with `ft.py set`. Items that need hands or motion (gestures, AirDrop, animation smoothness) become Not tested (needs a person).

## Adding a probe

Add an `a(...)`, `g(...)` or `nt(...)` to `PROBES` in the area it belongs to. Keep the command read-only if you can; if it changes something, put it back in the same command and mark it with `needs`. A new compiled probe goes in `probes/` as a `.swift` or `.m` file. `build.sh` builds every `.swift` file on its own; an Objective-C one needs a line with its frameworks.
