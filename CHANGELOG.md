# Changelog

## Unreleased

- The guard wait gives up after `FT_GUARD_WAIT` seconds (default 900) and records the GUI, sound and pointer probes as Skipped instead of blocking for ever. A guard file only counts as clear with `result` pass and a `started_boot` equal to this boot.
- `diff.md` treats numbers as equal within a relative tolerance (probe key `tol`, default 0.10) and has a delta column. A run to run spread of a few percent no longer fills the diff.

## 0.1.0 (2026-10-19)

- First public version: 119 probes in 14 areas, eight compiled probes (Metal, MPS and Core Image, VideoToolbox, AVPlayer, screen and camera capture, display, audio), guided dialogs, `summary.md` and `diff.md` reports.
- Results go to `./results` or `--out` / `FT_OUT`.
- `req` on a probe makes it N/A when a tool it needs is missing (used for the nvidia-macos-driver test tools and the OpenCore log).
- Wi-Fi and Ethernet interfaces are found with `networksetup` instead of fixed names.
- `FT_GUARD_FILE` replaces a guard path that only existed on the test laptop.
