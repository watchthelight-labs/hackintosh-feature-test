// <wtl> project: hackintosh-feature-test | file: probes/capture.swift | author: watchthelight </wtl>
// capture screen: screencapture to a file + ScreenCaptureKit stream for 3 s (frame count, non-black frames)
// capture camera: one AVFoundation frame from the default camera (resolution, non-black)
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage

var fails = 0
func ok(_ n: String, _ d: String) { print("ok \(n) \(d)") }
func fail(_ n: String, _ d: String) { fails += 1; print("FAIL \(n) \(d)") }
func luma(_ pb: CVPixelBuffer) -> Double {
    let ci = CIImage(cvPixelBuffer: pb)
    let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
    var px = [UInt8](repeating: 0, count: 4)
    CIContext().render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screen"
if mode == "screen" {
    let f = "screencap.png"
    let r = Process(); r.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); r.arguments = ["-x", f]
    try? r.run(); r.waitUntilExit()
    if let img = CIImage(contentsOf: URL(fileURLWithPath: f)) { ok("screencapture", "\(Int(img.extent.width))x\(Int(img.extent.height))") }
    else { fail("screencapture", "no image (Screen Recording permission for Terminal?)") }

    final class Sink: NSObject, SCStreamOutput {
        var frames = 0, dark = 0
        func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of t: SCStreamOutputType) {
            guard t == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            frames += 1; if frames % 20 == 1 && luma(pb) < 2 { dark += 1 }
        }
    }
    let sem = DispatchSemaphore(value: 0); var content: SCShareableContent?; var err: Error?
    SCShareableContent.getWithCompletionHandler { c, e in content = c; err = e; sem.signal() }; sem.wait()
    if let d = content?.displays.first {
        let cfg = SCStreamConfiguration(); cfg.width = d.width; cfg.height = d.height; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let st = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
        let sink = Sink()
        try? st.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck"))
        let s2 = DispatchSemaphore(value: 0); var e2: Error?
        st.startCapture { e in e2 = e; s2.signal() }; s2.wait()
        if let e2 = e2 { fail("screencapturekit", "start: \(e2.localizedDescription)") }
        else {
            Thread.sleep(forTimeInterval: 3)
            let s3 = DispatchSemaphore(value: 0); st.stopCapture { _ in s3.signal() }; s3.wait()
            let d = "\(sink.frames) frames in 3 s, \(sink.dark) black samples"
            if sink.frames > 5 && sink.dark == 0 { ok("screencapturekit", d) } else { fail("screencapturekit", d) }
        }
    } else { fail("screencapturekit", "no display: \(err?.localizedDescription ?? "none")") }
} else {
    let s = DispatchSemaphore(value: 0); var allowed = false
    AVCaptureDevice.requestAccess(for: .video) { a in allowed = a; s.signal() }; s.wait()
    guard allowed else { fail("webcam", "camera permission denied"); exit(2) }
    guard let dev = AVCaptureDevice.default(for: .video), let inp = try? AVCaptureDeviceInput(device: dev) else { fail("webcam", "no camera"); exit(2) }
    final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var n = 0, w = 0, h = 0, l = 0.0
        func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            n += 1; if n == 20 { w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb); l = luma(pb) }
        }
    }
    let sess = AVCaptureSession(); sess.addInput(inp)
    let out = AVCaptureVideoDataOutput(); let g = Grab(); out.setSampleBufferDelegate(g, queue: DispatchQueue(label: "cam")); sess.addOutput(out)
    sess.startRunning(); Thread.sleep(forTimeInterval: 3); sess.stopRunning()
    let d = "\(dev.localizedName) \(g.w)x\(g.h), \(g.n) frames in 3 s, mean luma \(Int(g.l))"
    if g.n >= 20 && g.l > 3 { ok("webcam", d) } else { fail("webcam", d) }
}
print("summary \(fails) fail"); exit(fails == 0 ? 0 : 2)
