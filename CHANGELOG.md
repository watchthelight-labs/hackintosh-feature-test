# Changelog

## 0.1.0 (2026-10-19)

- First public version: 119 probes in 14 areas, eight compiled probes (Metal, MPS and Core Image, VideoToolbox, AVPlayer, screen and camera capture, display, audio), guided dialogs, `summary.md` and `diff.md` reports.
- Results go to `./results` or `--out` / `FT_OUT`.
- `req` on a probe makes it N/A when a tool it needs is missing (used for the nvidia-macos-driver test tools and the OpenCore log).
- Wi-Fi and Ethernet interfaces are found with `networksetup` instead of fixed names.
- `FT_GUARD_FILE` replaces a guard path that only existed on the test laptop.
