// <wtl> project: hackintosh-feature-test | file: probes/avplay.swift | author: watchthelight </wtl>
// avplay: plays the clips vtprobe wrote (clip-*.mov in the current folder) through AVPlayer with a video output, the
// path QuickTime and Safari use, and counts frames delivered and black frames. ok <clip> ... | FAIL <clip> ...
import Foundation
import AVFoundation

var fails = 0
let clips = (try? FileManager.default.contentsOfDirectory(atPath: "."))?.filter { $0.hasPrefix("clip-") && $0.hasSuffix(".mov") && !$0.contains("hw-") }.sorted() ?? []
if clips.isEmpty { print("FAIL avplay no clips (run vtprobe first)"); exit(2) }
for c in clips {
    let item = AVPlayerItem(url: URL(fileURLWithPath: c))
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(out)
    let p = AVPlayer(playerItem: item); p.isMuted = true
    var t0 = Date()
    while item.status == .unknown && Date().timeIntervalSince(t0) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    if item.status != .readyToPlay { fails += 1; print("FAIL \(c) not ready: \(item.error?.localizedDescription ?? "status \(item.status.rawValue)")"); continue }
    p.play(); t0 = Date()
    var frames = 0, black = 0, last = CMTime.invalid
    while Date().timeIntervalSince(t0) < 3.0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { continue }
        if CMTimeCompare(t, last) == 0 { continue }; last = t; frames += 1
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb), h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb)
        var sum = 0; for y in stride(from: 0, to: h, by: h / 8) { for x in stride(from: 0, to: w, by: w / 8) { let i = y * bpr + x * 4; sum += Int(base[i]) + Int(base[i + 1]) + Int(base[i + 2]) } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        if sum < 64 { black += 1 }
    }
    p.pause()
    let dropped = item.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? -1
    let d = "\(frames) frames in 3 s (clip is 60 fps, 2 s), \(black) black, dropped \(dropped)"
    if frames >= 100 && black == 0 { print("ok \(c) \(d)") } else { fails += 1; print("FAIL \(c) \(d)") }
}
print("summary \(fails) fail"); exit(fails == 0 ? 0 : 2)
