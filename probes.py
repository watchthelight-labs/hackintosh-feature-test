# <wtl> project: hackintosh-feature-test | file: probes.py | author: watchthelight </wtl>
"""The feature test's probe list (read by ft.py).

kind: auto (command + check), info (recorded, Pass means it ran), nt (not tested, with the reason), guided (a person
judges from a dialog after `prep` opened the thing). needs: gui / sound / pointer (wait for FT_GUARD_FILE, announced),
sudo (FT_PW), risky (only with --risky; none are run by default). req: a path that must exist, else the probe is N/A.
passes: "AB" (default), "A" or "B".
Commands run under zsh with FT_REPO (results root), FT_HERE, FT_OD (this pass's evidence folder) set; "SUDO "
expands to sudo -S.
"""
import re

AREAS = {
    "platform": "1. Platform", "gpu": "2. GPU and Metal", "display": "3. Display", "desktop": "4. Desktop and UI",
    "video": "5. Video and media", "audio": "6. Audio", "input": "7. Input", "network": "8. Network",
    "bt": "9. Bluetooth and Continuity", "services": "10. Apple services", "power": "11. Power and thermal",
    "storage": "12. Storage and USB", "system": "13. System services", "rel": "14. Reliability snapshot",
}
BIN = "$FT_HERE/probes/bin"
CLIPS = "$HOME/.cache/hackintosh-feature-test/clips"  # generated test video, kept out of git
HIDPI_RX = r"HiDPI|2\.0"
# guided items that can be judged from a still screenshot (ft.py guided --auto); the rest need hands or eyes on motion
SHOT = {"disp.g.color", "desk.g.settings", "desk.g.launchpad", "desk.g.terminal", "desk.g.quicklook", "desk.g.photos",
        "desk.g.safari", "vid.g.youtube", "vid.g.photobooth", "vid.g.fairplay", "svc.g.account", "sys.g.notify",
        "bt.g.mirroring"}
WT = "${FT_NVGFX_SRC:-$HOME/src/nvidia-macos-driver}"  # checkout of nullmoth/nvidia-macos-driver, for its test tools
WIFI = "$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi/{getline; print $2; exit}')"
ETH = "$(networksetup -listallhardwareports | awk '/^Hardware Port: Ethernet/{getline; print $2; exit}')"


# check helpers: each returns (status, value, note)
def has(rx, fail="Fail", value=None):
    def f(rc, out):
        m = re.search(rx, out, re.M)
        if m:
            return "Pass", (m.group(1) if (m.groups() and value is None) else (value or "")), ""
        return fail, "", f"no match for {rx}"
    return f


def num(rx, lo=None, hi=None, unit="", degraded=None):
    """First number matched by rx; Pass inside [lo, hi], Degraded inside the degraded (lo, hi) band, else Fail."""
    def f(rc, out):
        m = re.search(rx, out, re.M)
        if not m:
            return "Fail", "", f"no value ({rx})"
        v = float(m.group(1))
        ok = (lo is None or v >= lo) and (hi is None or v <= hi)
        if ok:
            return "Pass", f"{v:g}{unit}", ""
        if degraded and (degraded[0] is None or v >= degraded[0]) and (degraded[1] is None or v <= degraded[1]):
            return "Degraded", f"{v:g}{unit}", ""
        return "Fail", f"{v:g}{unit}", ""
    return f


def lines_value(rx):
    def f(rc, out):
        v = "; ".join(m.group(1).strip() for m in re.finditer(rx, out, re.M))[:200]
        return ("Pass" if rc == 0 else "Fail"), v, ""
    return f


def tally(okrx, badrx, refusedrx=None):
    """Counts result lines of a multi-check probe: all ok = Pass, some bad = Degraded, none ok = Fail."""
    def f(rc, out):
        ok, bad = len(re.findall(okrx, out, re.M)), len(re.findall(badrx, out, re.M))
        ref = len(re.findall(refusedrx, out, re.M)) if refusedrx else 0
        bad_names = [m.group(1) for m in re.finditer(badrx, out, re.M)][:8]
        v = f"{ok} ok, {bad} bad" + (f", {ref} refused" if refusedrx else "")
        st = "Fail" if (ok == 0 and rc != 0) or (ok == 0 and bad) else ("Degraded" if bad else "Pass")
        return st, v, ("bad: " + ", ".join(bad_names)) if bad_names else ""
    return f


def zero(rx, what):
    def f(rc, out):
        n = len(re.findall(rx, out, re.M))
        return ("Pass" if n == 0 else "Fail"), f"{n} {what}", ""
    return f


def nt(id_, area, feature, status, note, passes="AB"):
    return dict(id=id_, area=area, feature=feature, kind="nt", status=status, note=note, passes=passes)


def g(id_, area, feature, prompt, prep="", cleanup="", settle=3, needs=("gui",), passes="AB"):
    return dict(id=id_, area=area, feature=feature, kind="guided", prompt=prompt, prep=prep, cleanup=cleanup,
                settle=settle, needs=list(needs), passes=passes)


def a(id_, area, feature, cmd, check=None, kind="auto", needs=(), timeout=120, note="", passes="AB", info_na=False,
      req=""):
    d = dict(id=id_, area=area, feature=feature, kind=kind, cmd=cmd, needs=list(needs), timeout=timeout, note=note,
             passes=passes, info_na=info_na, req=req)
    if check:
        d["check"] = check
    return d


NOEQ = "Not tested (no equipment)"
RISKY = "Not tested (risky)"
BOOT = "$(sysctl -n kern.boottime | sed -E 's/^\\{ sec = ([0-9]+),.*/\\1/')"
REPORTS = "/Library/Logs/DiagnosticReports $HOME/Library/Logs/DiagnosticReports"

PROBES = [
    # 14 first half: the baseline the end of the pass is compared with
    a("rel.start", "rel", "Pass start: WindowServer PID and report count",
      f"pgrep -x WindowServer | head -1 > $FT_OD/.ws_pid; date +%s > $FT_OD/.t0; "
      f"find {REPORTS} -name '*.ips' 2>/dev/null | wc -l | tr -d ' ' > $FT_OD/.n0; "
      "echo ws $(cat $FT_OD/.ws_pid) reports $(cat $FT_OD/.n0)", has(r"ws (\d+)"), kind="info"),

    # 1 platform
    a("plat.os", "platform", "macOS version", "sw_vers", has(r"ProductVersion:\s+(\S+)"), kind="info"),
    a("plat.model", "platform", "SMBIOS model", "sysctl -n hw.model", has(r"^(\S+)"), kind="info"),
    a("plat.sip", "platform", "SIP and AMFI state", "csrutil status; nvram boot-args 2>/dev/null | grep -o 'amfi[^ ]*'",
      has(r"System Integrity Protection status: (.*)"), kind="info"),
    a("plat.kexts", "platform", "Third-party kexts loaded", "kextstat 2>/dev/null | grep -v com.apple | awk 'NR>1{print $6, $7}'",
      lines_value(r"^(\S+ \(\S+\))"), kind="info"),
    a("plat.bootargs", "platform", "Boot-args", "nvram boot-args", has(r"boot-args\s+(.*)"), kind="info"),
    a("plat.fbgpu", "platform", "Boot framebuffer address (OpenCore log)",
      "L=$(ls -t ${FT_OCLOG_DIR:-/Volumes/EFI}/opencore-*.txt | head -1); "
      "tr -d '\\0' < $L | grep -o 'Current FB at 0x[0-9A-Fa-f]*' | head -1",
      has(r"Current FB at (0x[0-9A-Fa-f]+)"), kind="info", req="${FT_OCLOG_DIR:-/Volumes/EFI}",
      note="mount the EFI partition first or set FT_OCLOG_DIR; the address is in the BAR of the GPU driving the panel"),
    a("plat.panics", "platform", "Kernel panics since boot",
      f"find /Library/Logs/DiagnosticReports -name 'panic*' -newermt @{BOOT} 2>/dev/null", zero(r"\S", "panic reports")),
    a("plat.crashes", "platform", "Crash reports since boot",
      f"find {REPORTS} -name '*.ips' -newermt @{BOOT} 2>/dev/null | xargs -n1 basename 2>/dev/null",
      lambda rc, out: (("Pass" if not out.strip() else "Degraded"), f"{len(out.split())} reports",
                       ", ".join(sorted({re.sub(r'[-_]\d{4}-.*', '', x) for x in out.split()}))[:200])),
    a("plat.stalls", "platform", "Shutdown stalls today",
      "find /Library/Logs/DiagnosticReports -name 'shutdown_stall*' -newermt \"$(date +%Y-%m-%d)\" 2>/dev/null",
      lambda rc, out: (("Pass" if not out.strip() else "Degraded"), f"{len(out.split())} today", "")),
    a("plat.corecapture", "platform", "corecapture panics (Wi-Fi capture path), this boot",
      f"find /Library/Logs/DiagnosticReports -name 'panic*' -newermt @{BOOT} -exec grep -l corecapture {{}} + 2>/dev/null",
      zero(r"\S", "this boot"), note="Wi-Fi drivers that crash in the capture path show up here"),

    # 2 GPU and Metal
    a("gpu.profile", "gpu", "GPU seen by macOS, Metal support", "system_profiler SPDisplaysDataType",
      has(r"Metal Support: (Metal \d)")),
    a("gpu.kexts", "gpu", "Third-party GPU kexts",
      "kextstat 2>/dev/null | grep -iE 'nullmoth|nvidia|nvda|whatevergreen' | grep -v com.apple | awk '{print $6, $7}'",
      lines_value(r"^(\S+ \(\S+\))"), kind="info"),
    a("gpu.metalcaps", "gpu", "Metal device capabilities", f"{BIN}/metalcaps",
      has(r"^family Metal3 (YES)"), note="see evidence for every family and limit"),
    a("gpu.mtlfeat", "gpu", "Metal features rendered and read back", f"{BIN}/mtlfeat", tally(r"^ok ", r"^FAIL (\S+)", r"^refused "),
      timeout=300),
    a("gpu.mpsci", "gpu", "MPS blur and Core Image against a CPU reference", f"{BIN}/mpsci", tally(r"^ok ", r"^FAIL (\S+)"),
      timeout=180),
    a("gpu.selftest", "gpu", "nvidia-macos-driver metal_selftest", f"cd {WT} && bash tools/metal_selftest.sh",
      tally(r"\|\s*(?:PASS|pass|ok)\s*\|", r"\|\s*(\S+)\s*\|\s*(?:FAIL|fail)"), timeout=900,
      req=f"{WT}/tools/metal_selftest.sh"),
    a("gpu.gl", "gpu", "OpenGL draw cost (glbench)",
      f"cd $FT_OD && cc -O2 -w {WT}/tools/glbench/glbench.c -framework OpenGL -o glbench && ./glbench",
      has(r"(\d[\d.,]*\s*(?:draws|us|ms)[^\n]*)"), timeout=300, req=f"{WT}/tools/glbench/glbench.c"),
    a("gpu.glsample", "gpu", "OpenGL MSAA sample positions",
      f"cd $FT_OD && ls {WT}/tools/sample-location-repro/ && clang -fobjc-arc -w {WT}/tools/sample-location-repro/opengl.m "
      "-framework OpenGL -framework Foundation -framework AppKit -framework Metal -framework QuartzCore -o glsample && ./glsample",
      lambda rc, out: (lambda v: (("Pass" if v and all(x == "0" for x in v) else "Fail"), f"{len(v)} MSAA sizes, mismatched {','.join(v)}", ""))(re.findall(r'"mismatched_pixels" : (\d+)', out)),
      req=f"{WT}/tools/sample-location-repro/opengl.m"),
    a("gpu.opencl", "gpu", "OpenCL programs (upstream oracles)",
      f"cd $FT_OD && for s in {WT}/tools/oracles/opencl_*.c; do n=$(basename $s .c); "
      "cc -O2 -w $s -framework OpenCL -o $n 2>/dev/null && (./$n >/dev/null 2>&1 && echo \"ok $n\" || echo \"FAIL $n\") "
      "|| echo \"FAIL $n (build)\"; done", tally(r"^ok ", r"^FAIL (\S+)"), timeout=300, req=f"{WT}/tools/oracles"),
    nt("gpu.spin", "gpu", "GPU watchdog recovery (long GPU job)", RISKY, "a stuck GPU job can freeze the panel; left out"),
    nt("gpu.geekbench", "gpu", "Geekbench Metal", "N/A", "not automated: run Geekbench by hand"),

    # 3 Display
    a("disp.modes", "display", "Display modes (CoreGraphics list)", f"{BIN}/display modes",
      has(r"^summary (.*)$")),
    a("disp.refresh", "display", "Panel refresh rate", "system_profiler SPDisplaysDataType",
      has(r"@ (\d+(?:\.\d+)?Hz)")),
    a("disp.setmode", "display", "Mode switch holds 10 s, then restored", f"{BIN}/display setmode", has(r"^ok (.*)$"),
      needs=["gui"], timeout=90),
    a("disp.gamma", "display", "Gamma table round-trip (Night Shift path)", f"{BIN}/display gamma", has(r"^ok (.*)$"),
      needs=["gui"]),
    a("disp.edr", "display", "EDR / HDR headroom", f"{BIN}/display edr", num(r"edr ([\d.]+)", lo=1.01, degraded=(1.0, 1.0)),
      note="1.0 = no HDR headroom (8 bpc framebuffer, or a panel without HDR)"),
    a("disp.brightness", "display", "Brightness set and read back, restored", f"{BIN}/display brightness",
      has(r"^ok (.*)$"), needs=["gui"]),
    a("disp.cursor", "display", "Hardware cursor", "ioreg -l -w0 -r -c IOFramebuffer | grep -o 'IOFBCursorInfo' | head -1",
      has(r"(IOFBCursorInfo)", fail="Degraded")),
    g("disp.g.keys", "display", "Brightness keys change the panel",
      "Press the brightness down and up keys a few times. Does the panel dim and brighten and the OSD show?"),
    g("disp.g.nightshift", "display", "Night Shift visibly warms the panel",
      "Control Center > Display > Night Shift on. Does the panel turn warmer? (turn it off again after)"),
    g("disp.g.flicker", "display", "No flicker or tearing at full refresh rate",
      "Move a window around and scroll a long page for a few seconds. Any flicker, tearing or black frames?"),
    g("disp.g.color", "display", "Colours and text look right",
      "Look at this screenshot's apps and the desktop: colours, gradients, text sharpness look normal?"),
    nt("disp.external", "display", "External monitor, hot-plug, modes", NOEQ, "needs an external monitor"),
    nt("disp.hdmiaudio", "display", "HDMI / DP audio", NOEQ, "needs an external monitor with speakers"),
    nt("disp.sleep", "display", "Display sleep and wake", RISKY, "sleep and wake can hang the machine; test it by hand"),

    # 4 Desktop and UI
    g("desk.g.dockglass", "desktop", "Liquid Glass: Dock and its context menu",
      "Right-click a Dock icon. Is the menu glassy (blurred background), with all items readable?"),
    g("desk.g.cc", "desktop", "Control Center and Notification Center",
      "Open Control Center, then Notification Center (click the clock). Glass, icons and text all right?"),
    g("desk.g.settings", "desktop", "System Settings icons (sidebar sweep)",
      "Scroll the whole System Settings sidebar and open 4-5 panes. Every icon complete (no empty squares, no missing parts)?",
      prep="open -a 'System Settings'", cleanup="pkill -x 'System Settings'"),
    g("desk.g.launchpad", "desktop", "Launchpad / Apps icons",
      "Open Launchpad (or the Apps view) and page through. All icons complete and sharp?",
      prep="open -a Apps 2>/dev/null || open -a Launchpad", cleanup="osascript -e 'tell application \"System Events\" to key code 53'", settle=4),
    g("desk.g.badges", "desktop", "Dock badges show their numbers", "Any Dock badge (Mail, Messages, Settings) shows its digit?"),
    g("desk.g.terminal", "desktop", "Terminal text draws cleanly",
      "In the Terminal window that opened, scroll and resize it. Any overdrawn or stale text?",
      prep="osascript -e 'tell application \"Terminal\" to do script \"ls -la /System/Library; man ls | head -200\"'"),
    g("desk.g.mission", "desktop", "Mission Control and Spaces animation",
      "Open Mission Control (F3 or 3-finger swipe up) and back, switch Spaces. Smooth, no black frames?"),
    g("desk.g.minimize", "desktop", "Minimize to Dock and its tile",
      "Minimize a window (yellow button). Does the genie animation play and the Dock tile show the window image?"),
    g("desk.g.spotlight", "desktop", "Spotlight search", "Press Cmd+Space, type 'calc', press Return. Calculator opens?"),
    g("desk.g.quicklook", "desktop", "Quick Look and Preview",
      "In the Finder window, select a picture or PDF and press Space, then open it in Preview and zoom. Sharp, no blocks?",
      prep="(qlmanage -p \"$(ls /System/Library/Desktop\\ Pictures/*.heic 2>/dev/null | head -1)\" >/dev/null 2>&1 &)",
      cleanup="pkill -x qlmanage", settle=4),
    g("desk.g.photos", "desktop", "Photos grid and viewer", "Open Photos, scroll the grid, open a photo. Any green or blocky tiles?",
      prep="open -a Photos"),
    g("desk.g.safari", "desktop", "Safari page scroll and text",
      "Scroll this page up and down. Smooth, all text and images drawn?", prep="open -a Safari 'https://en.wikipedia.org/wiki/Macintosh'"),

    # 5 Video and media
    a("vid.vt", "video", "VideoToolbox hardware decode and encode per codec", f"mkdir -p {CLIPS} && cd {CLIPS} && {BIN}/vtprobe",
      tally(r"^ok ", r"^FAIL (\S+)", r"^none "), timeout=300),
    a("vid.play", "video", "AVPlayer playback of H.264 / HEVC clips (offscreen)", f"cd {CLIPS} && {BIN}/avplay",
      tally(r"^ok ", r"^FAIL (\S+)"), timeout=300),
    a("vid.screencap", "video", "Screenshot and ScreenCaptureKit capture", f"cd $FT_OD && {BIN}/capture screen",
      tally(r"^ok ", r"^FAIL (\S+)"), needs=["gui"], timeout=60),
    a("vid.webcam", "video", "Webcam frame capture", f"cd $FT_OD && {BIN}/capture camera",
      has(r"^ok (.*)$"), needs=["gui"], timeout=60, note="allow the camera permission prompt"),
    g("vid.g.youtube", "video", "Safari YouTube 1080p60 / 4K",
      "Play this video at 1080p60 then 2160p (gear menu). Smooth, no green frames or stutter? (Stats: right-click > Stats for nerds)",
      prep="open -a Safari 'https://www.youtube.com/watch?v=LXb3EKWsInQ'", settle=6),
    g("vid.g.recording", "video", "QuickTime / Screenshot app screen recording",
      "Press Cmd+Shift+5, record 5 s of the screen, stop, open the recording. Plays back right?"),
    g("vid.g.fairplay", "video", "Apple TV app trailer (FairPlay DRM)",
      "In the TV app, play any trailer or free episode. Does it play (picture, not black)?", prep="open -a TV"),
    g("vid.g.photobooth", "video", "Photo Booth live webcam image", "Live picture, right colours, smooth?", prep="open -a 'Photo Booth'",
      cleanup="pkill -x 'Photo Booth'"),

    # 6 Audio
    a("aud.devices", "audio", "Audio devices (outputs, inputs)", f"{BIN}/audio list", has(r"^summary (.*)$")),
    a("aud.volume", "audio", "Output volume set and read back, restored", f"{BIN}/audio volume", has(r"^ok (.*)$")),
    a("aud.mic", "audio", "Microphone records sound (RMS above silence)", f"cd $FT_OD && {BIN}/audio record",
      num(r"rms ([\d.]+)", lo=0.0005, degraded=(0.00001, 0.0005)), needs=["gui"], timeout=60,
      note="allow the microphone permission prompt; speak during the 3 s"),
    g("aud.g.speakers", "audio", "Speakers play sound",
      "A chime played three times. Did you hear it from the laptop speakers, clean, both sides?",
      prep="for i in 1 2 3; do afplay /System/Library/Sounds/Glass.aiff; done", needs=("gui", "sound")),
    g("aud.g.keys", "audio", "Volume and mute keys", "Press volume up, down and mute. The OSD shows and the level changes?"),
    a("aud.driver", "audio", "Audio driver owning the codec",
      "ioreg -l -w0 | grep -E -o 'VoodooHDA[A-Za-z]*|AppleHDAController|AppleHDADriver' | sort | uniq -c",
      lines_value(r"^\s*(\d+ \S+)"), kind="info", note="VoodooHDA, or AppleHDA with AppleALC"),
    nt("aud.jack", "audio", "Headphone jack and headset mic", NOEQ, "needs headphones"),

    # 7 Input
    g("in.g.keyboard", "input", "Keyboard typing",
      "Type a sentence in the TextEdit window that opened. Every key you pressed came through once?",
      prep="open -a TextEdit"),
    g("in.g.kbdlight", "input", "Keyboard backlight", "Fn+Space (or the backlight key): does the keyboard backlight change?"),
    g("in.g.scroll", "input", "Trackpad two-finger scroll", "Two-finger scroll in any window. Smooth, right direction?"),
    g("in.g.pinch", "input", "Trackpad pinch zoom", "Pinch in Safari or Preview. Zooms?"),
    g("in.g.swipe", "input", "Trackpad three/four-finger gestures", "Three-finger swipe between Spaces, four-finger up for Mission Control. Work?"),
    g("in.g.click", "input", "Tap to click and right click", "Tap to click, two-finger tap for right click. Work?"),
    g("in.g.mouse", "input", "USB mouse", "Move and click with the USB mouse, scroll its wheel. All fine?"),

    # 8 Network
    a("net.wifi", "network", "Wi-Fi association", f"ifconfig {WIFI}",
      has(r"status: (active)")),
    a("net.phy", "network", "Wi-Fi PHY mode, channel, width, country", "system_profiler SPAirPortDataType",
      lines_value(r"(PHY Mode: .*|Channel: .*|Country Code: .*|Supported PHY Modes: .*)"), kind="info"),
    a("net.service", "network", "Wi-Fi network service state as macOS reports it",
      "system_profiler SPAirPortDataType | grep -iE 'Network Service|Status' ; networksetup -getinfo Wi-Fi",
      lambda rc, out: (("Degraded" if "Inactive" in out else "Pass"), "", "System Information may say 'Network Service Inactive' while Wi-Fi works")),
    a("net.scan", "network", "Wi-Fi scan results", "system_profiler SPAirPortDataType | grep -cE '^\\s{12}\\S.*:$'",
      num(r"(\d+)", lo=1)),
    a("net.dns", "network", "DNS and IPv4/IPv6", f"dscacheutil -q host -a name apple.com | head -4; ifconfig {WIFI} | grep -E 'inet6? '",
      has(r"((?:ip|ipv6)_address: \S+)")),
    a("net.speed", "network", "Internet speed (networkQuality)", "networkQuality -s", num(r"Downlink capacity: ([\d.]+) Mbps", lo=100,
      unit=" Mbit/s down", degraded=(20, 100)), timeout=120, note="depends on the network more than on the machine"),
    a("net.awdl", "network", "AWDL interface (AirDrop, Sidecar, Continuity Camera)", "ifconfig awdl0",
      has(r"(awdl0:.*)", fail="Fail")),
    a("net.eth", "network", "Ethernet driver and link", f"E={ETH}; [ -n \"$E\" ] && ifconfig $E",
      has(r"status: (active)", fail="Degraded"), note="Degraded = no active link (no cable, or no driver)"),
    a("net.toggle", "network", "Wi-Fi off/on and re-join", f"W={WIFI}; networksetup -setairportpower $W off; sleep 3; "
      "networksetup -setairportpower $W on; for i in $(seq 1 60); do ipconfig getifaddr $W && break; sleep 1; done",
      has(r"^(\d+\.\d+\.\d+\.\d+)"), needs=["risky"], timeout=90),

    # 9 Bluetooth and Continuity
    a("bt.state", "bt", "Bluetooth controller", "system_profiler SPBluetoothDataType", has(r"State: (On)")),
    a("bt.devices", "bt", "Bluetooth devices seen / paired", "system_profiler SPBluetoothDataType",
      lambda rc, out: ("Pass", f"{len(re.findall(r'Address:', out))} devices listed", "")),
    g("bt.g.handoff", "bt", "Handoff (Safari iPhone <-> Mac)",
      "Open a page in Safari on the iPhone: does a Safari Handoff icon appear in the Mac Dock? And Mac to iPhone (app switcher)?"),
    g("bt.g.clipboard", "bt", "Universal Clipboard", "Copy text on the iPhone, paste on the Mac (Cmd+V), and the other way. Works?"),
    g("bt.g.airdrop", "bt", "AirDrop both ways", "Share a photo from the iPhone via AirDrop: is this Mac listed and does it arrive?",
      prep="open /System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"),
    g("bt.g.hotspot", "bt", "Instant Hotspot", "Wi-Fi menu: is the iPhone listed under Personal Hotspot and does joining it work? (switch back after)"),
    g("bt.g.contcam", "bt", "Continuity Camera (iPhone as webcam)",
      "In Photo Booth > Camera menu, is the iPhone offered as a camera and does it show video?", prep="open -a 'Photo Booth'",
      cleanup="pkill -x 'Photo Booth'"),
    g("bt.g.mirroring", "bt", "iPhone Mirroring", "Open iPhone Mirroring. Does it connect? (expected to fail: needs T2 / Apple silicon)",
      prep="open -a 'iPhone Mirroring'"),
    g("bt.g.watch", "bt", "Apple Watch unlock", "System Settings > Touch ID & Password / Login: is 'Use Apple Watch to unlock' offered and does it work? (expected fail: no Secure Enclave)"),
    g("bt.g.findmy", "bt", "Find My lists this Mac", "In Find My on the iPhone (Devices), is this Mac listed with a location?"),
    g("bt.g.sms", "bt", "Messages SMS relay / iMessage from the Mac",
      "Send an iMessage (or SMS via relay) from Messages on the Mac. Delivered?", prep="open -a Messages"),

    # 10 Apple services
    g("svc.g.account", "services", "Apple Account signed in", "Is an Apple Account signed in (top of the sidebar) without errors?",
      prep="open 'x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings'"),
    g("svc.g.icloud", "services", "iCloud Drive sync", "Does iCloud Drive show in Finder and a file saved there appear on the iPhone?"),
    g("svc.g.facetime", "services", "FaceTime audio call", "Start a FaceTime audio call to the iPhone. Connects with audio both ways?",
      prep="open -a FaceTime"),
    g("svc.g.appstore", "services", "App Store download", "Download any small free app. Does it install?", prep="open -a 'App Store'"),
    g("svc.g.music", "services", "Apple Music / Music app playback", "Play a song in Music. Plays with sound?", prep="open -a Music"),
    g("svc.g.siri", "services", "Siri", "Ask Siri 'what time is it' (menu bar or keyboard shortcut). Answers?"),
    a("svc.update", "services", "Software Update reachable (list only, no install)", "softwareupdate -l", has(r"(Label: .*|No new software)"),
      timeout=180, note="lists updates only, installs nothing"),

    # 11 Power and thermal
    a("pwr.batt", "power", "Battery: charge, health, cycles", "pmset -g batt; system_profiler SPPowerDataType",
      has(r"Condition: (\w+)")),
    a("pwr.readings", "power", "Battery readings sanity (adapter W, voltage, temperature)",
      "ioreg -r -c AppleSmartBattery -w0 | grep -E '\"(Voltage|Temperature|AdapterDetails|ChargingVoltage|Amperage|CycleCount)\"'",
      lambda rc, out: (("Degraded" if re.search(r'"Watts"=60\b', out) or '"ChargingVoltage"=8000' in out else "Pass"),
                       "; ".join(re.findall(r'"(Voltage|Temperature|CycleCount)" = (\d+)', out) and
                                 [f"{k}={v}" for k, v in re.findall(r'"(Voltage|Temperature|CycleCount)" = (\d+)', out)]),
                       "adapter 60 W / charging voltage 8000 look like placeholders")),
    a("pwr.tempdrift", "power", "Battery temperature changes over 3 min",
      "for i in 1 2 3 4; do ioreg -r -c AppleSmartBattery -w0 | grep -E '^\\s+\"Temperature\"' ; sleep 60; done",
      lambda rc, out: (lambda v: (("Pass" if len(set(v)) > 1 else "Degraded"), ",".join(v), "static value = not a live sensor"))(
          re.findall(r'"Temperature" = (\d+)', out)), timeout=300),
    a("pwr.assert", "power", "Power assertions (what holds the machine awake)", "pmset -g assertions",
      lines_value(r"pid \d+\((\w+)\): \[\S+\] \d+:\d+:\d+ (\w+)"), kind="info"),
    a("pwr.cpu", "power", "CPU frequency and package power under load",
      "for i in $(seq 1 $(sysctl -n hw.ncpu)); do (yes > /dev/null &); done; sleep 2; "
      "SUDO powermetrics -n 2 -i 2000 --samplers cpu_power,thermal 2>&1 | grep -E 'frequency|Package Power|CPU Power|pressure' | head -20; pkill yes",
      has(r"((?:Package|CPU) Power: .*)", fail="Degraded"), needs=["sudo"], timeout=60),
    nt("pwr.fans", "power", "Fan speeds", "N/A", "not automated: fan readings depend on the machine's SMC plugin"),
    nt("pwr.sleep", "power", "System sleep and wake", RISKY, "sleep and wake can hang the machine; test it by hand"),
    g("pwr.g.battery", "power", "On battery (optional, 10 min)",
      "Optional: unplug for 10 min. Does the menu bar switch to battery and the % fall sensibly? Plug back in after."),

    # 12 Storage and USB
    a("sto.nvme", "storage", "NVMe health and TRIM", "system_profiler SPNVMeDataType", has(r"S\.M\.A\.R\.T\. status: (\w+)")),
    a("sto.speed", "storage", "NVMe sequential write / read (4 GB)",
      "F=$HOME/.ft-speed.bin; dd if=/dev/zero of=$F bs=8m count=512 2>&1 | tail -1; SUDO purge; "
      "dd if=$F of=/dev/null bs=8m 2>&1 | tail -1; rm -f $F",
      lambda rc, out: (lambda v: (("Pass" if len(v) == 2 and min(v) > 1000 else "Degraded"),
                                  " / ".join(f"{x:.0f} MB/s" for x in v), "write / read"))(
          [int(x) / 1e6 for x in re.findall(r"\((\d+) bytes/sec\)", out)]), needs=["sudo"], timeout=300),
    a("sto.usb", "storage", "USB controllers and devices", "system_profiler SPUSBHostDataType",
      lambda rc, out: ("Pass", f"{len(re.findall(r'Product ID', out))} devices", "")),
    a("sto.tb", "storage", "Thunderbolt / USB4 controller", "system_profiler SPThunderboltDataType",
      has(r"(Thunderbolt Bus|USB4 Bus.*)", fail="Fail"), note="'No hardware was found' = no controller driver"),
    a("sto.fv", "storage", "FileVault", "fdesetup status", has(r"(FileVault is \w+)"), kind="info", info_na=True),
    a("sto.tm", "storage", "Time Machine", "tmutil destinationinfo 2>&1 | head -3", has(r"(.+)"), kind="info", info_na=True),
    nt("sto.usbc", "storage", "USB-C data, charging and DP alt mode", NOEQ, "needs USB-C devices"),

    # 13 System services
    a("sys.spotlight", "system", "Spotlight indexing", "mdutil -s /", has(r"(Indexing enabled)")),
    a("sys.time", "system", "Time sync", "sntp -t 3 time.apple.com 2>&1 | tail -1", has(r"([+-]\d+\.\d+)")),
    a("sys.gatekeeper", "system", "Gatekeeper", "spctl --status", has(r"(assessments \w+)"), kind="info"),
    a("sys.location", "system", "Location Services",
      "SUDO defaults read /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled 2>&1",
      has(r"^(1)$", fail="Degraded"), needs=["sudo"]),
    g("sys.g.notify", "system", "Notifications appear", "A notification 'Feature test' just appeared top right?",
      prep="osascript -e 'display notification \"Feature test notification\" with title \"Feature test\"'"),
    a("sys.sharing", "system", "Sharing services (read only)", "SUDO systemsetup -getremotelogin 2>&1; launchctl print-disabled system 2>/dev/null | grep -E 'screensharing|smbd'",
      has(r"(Remote Login: \w+)"), kind="info", needs=["sudo"]),

    # 14 Reliability snapshot (end)
    a("rel.end", "rel", "Pass end: WindowServer PID unchanged, no new crash reports",
      f"echo start $(cat $FT_OD/.ws_pid) now $(pgrep -x WindowServer | head -1); "
      f"find {REPORTS} -name '*.ips' -newermt @$(cat $FT_OD/.t0) 2>/dev/null | xargs -n1 basename 2>/dev/null",
      lambda rc, out: (lambda m, new: (("Pass" if m and m.group(1) == m.group(2) and not new else "Fail"),
                                       f"WS {'same' if m and m.group(1) == m.group(2) else 'RESTARTED'}, {len(new)} new reports",
                                       ", ".join(new)[:200]))(
          re.search(r"start (\d+) now (\d+)", out), [x for x in out.split("\n")[1:] if x.strip() and not x.startswith("[")])),
]
