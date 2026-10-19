// <wtl> project: hackintosh-feature-test | file: probes/display.swift | author: watchthelight </wtl>
// display modes | setmode | gamma | edr | brightness. Every probe that changes something puts it back and prints
// before / after / restored. ok <detail> | FAIL <detail>
import Foundation
import CoreGraphics
import AppKit
import IOKit
import IOKit.graphics

let did = CGMainDisplayID()
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "modes"
func modes() -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(did, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]) ?? []
}
func desc(_ m: CGDisplayMode) -> String { "\(m.width)x\(m.height)@\(Int(m.refreshRate))\(m.pixelWidth > m.width ? " HiDPI" : "")" }

switch arg {
case "modes":
    let ms = modes(); let cur = CGDisplayCopyDisplayMode(did)!
    for m in ms { print("mode \(desc(m)) pixels \(m.pixelWidth)x\(m.pixelHeight) usable \(m.isUsableForDesktopGUI())") }
    let rates = Set(ms.map { Int($0.refreshRate) }).sorted()
    print("current \(desc(cur)) pixels \(cur.pixelWidth)x\(cur.pixelHeight)")
    print("summary \(ms.count) modes, \(ms.filter { $0.pixelWidth > $0.width }.count) HiDPI, refresh \(rates), current \(desc(cur))")
case "setmode":
    let cur = CGDisplayCopyDisplayMode(did)!
    guard let alt = modes().first(where: { $0.isUsableForDesktopGUI() && ($0.width != cur.width || $0.pixelWidth != cur.pixelWidth) && $0.refreshRate == cur.refreshRate && $0.pixelWidth > $0.width })
            ?? modes().first(where: { $0.isUsableForDesktopGUI() && $0.width != cur.width }) else { print("FAIL no other mode"); exit(2) }
    var cfg: CGDisplayConfigRef?; CGBeginDisplayConfiguration(&cfg); CGConfigureDisplayWithDisplayMode(cfg, did, alt, nil)
    let r = CGCompleteDisplayConfiguration(cfg, .forSession)
    Thread.sleep(forTimeInterval: 10)
    let held = CGDisplayCopyDisplayMode(did)!
    CGBeginDisplayConfiguration(&cfg); CGConfigureDisplayWithDisplayMode(cfg, did, cur, nil); CGCompleteDisplayConfiguration(cfg, .forSession)
    Thread.sleep(forTimeInterval: 2)
    let back = CGDisplayCopyDisplayMode(did)!
    let line = "before \(desc(cur)) set \(desc(alt)) rc \(r.rawValue) after 10 s \(desc(held)) restored \(desc(back))"
    print(held.width == alt.width && held.pixelWidth == alt.pixelWidth && back.width == cur.width ? "ok \(line)" : "FAIL \(line)")
case "gamma":
    let n: UInt32 = 256
    var r0 = [CGGammaValue](repeating: 0, count: Int(n)), g0 = r0, b0 = r0; var cnt: UInt32 = 0
    CGGetDisplayTransferByTable(did, n, &r0, &g0, &b0, &cnt)
    var lin = (0..<Int(cnt)).map { CGGammaValue($0) / CGGammaValue(cnt - 1) }; var lin2 = lin; var cool = lin.map { $0 * 0.8 }
    let e = CGSetDisplayTransferByTable(did, cnt, &lin, &lin2, &cool)
    var r1 = [CGGammaValue](repeating: 0, count: Int(n)), g1 = r1, b1 = r1; var c1: UInt32 = 0
    CGGetDisplayTransferByTable(did, n, &r1, &g1, &b1, &c1)
    let took = abs(b1[Int(c1) - 1] - 0.8) < 0.02
    CGSetDisplayTransferByTable(did, cnt, &r0, &g0, &b0)
    var r2 = [CGGammaValue](repeating: 0, count: Int(n)), g2 = r2, b2 = r2; var c2: UInt32 = 0
    CGGetDisplayTransferByTable(did, n, &r2, &g2, &b2, &c2)
    let back = abs(b2[Int(c2) - 1] - b0[Int(cnt) - 1]) < 0.01
    let line = "table \(cnt) entries, set rc \(e.rawValue), blue top before \(b0[Int(cnt) - 1]) set \(b1[Int(c1) - 1]) restored \(b2[Int(c2) - 1])"
    print(took && back ? "ok \(line)" : "FAIL \(line)")
case "edr":
    let s = NSScreen.main!
    print("edr \(s.maximumPotentialExtendedDynamicRangeColorComponentValue) current \(s.maximumExtendedDynamicRangeColorComponentValue) reference \(s.maximumReferenceExtendedDynamicRangeColorComponentValue)")
    print("depth \(s.depth.rawValue) bitsPerPixel \(s.depth.bitsPerPixel) colorSpace \(s.colorSpace?.localizedName ?? "?")")
case "brightness":
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it)
    var svc = IOIteratorNext(it); var found = false
    while svc != 0 {
        var before: Float = 0
        if IODisplayGetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, &before) == kIOReturnSuccess {
            found = true
            let target: Float = before > 0.5 ? before - 0.3 : before + 0.3
            let rs = IODisplaySetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, target)
            Thread.sleep(forTimeInterval: 1)
            var after: Float = 0; IODisplayGetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, &after)
            IODisplaySetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, before)
            Thread.sleep(forTimeInterval: 1)
            var back: Float = 0; IODisplayGetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, &back)
            let line = String(format: "before %.2f set %.2f (rc 0x%x) read %.2f restored %.2f", before, target, rs, after, back)
            print(abs(after - target) < 0.05 && abs(back - before) < 0.05 ? "ok \(line)" : "FAIL \(line)")
        }
        IOObjectRelease(svc); svc = IOIteratorNext(it)
    }
    if !found { print("FAIL no display answers the brightness parameter (IODisplayConnect)") }
default:
    print("usage: display modes|setmode|gamma|edr|brightness")
}
