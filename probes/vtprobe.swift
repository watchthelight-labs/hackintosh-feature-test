// <wtl> project: hackintosh-feature-test | file: probes/vtprobe.swift | author: watchthelight </wtl>
// vtprobe: VideoToolbox hardware decode and encode per codec. Writes test clips (clip-h264.mov, clip-hevc.mov) into the
// current folder for avplay. Lines: ok <name> <detail> | FAIL <name> <why> | none <name> <why> (no decoder at all).
import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

var fails = 0
func ok(_ n: String, _ d: String) { print("ok \(n) \(d)") }
func fail(_ n: String, _ d: String) { fails += 1; print("FAIL \(n) \(d)") }

// 1. Which codecs have a hardware decoder at all
let codecs: [(String, CMVideoCodecType)] = [("h264", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC),
    ("av1", kCMVideoCodecType_AV1), ("vp9", kCMVideoCodecType_VP9), ("prores422", kCMVideoCodecType_AppleProRes422),
    ("mpeg4", kCMVideoCodecType_MPEG4Video)]
for (n, c) in codecs {
    let hw = VTIsHardwareDecodeSupported(c)
    if hw { ok("decode_hw_\(n)", "VTIsHardwareDecodeSupported YES") }
    else if n == "h264" || n == "hevc" { fail("decode_hw_\(n)", "no hardware decoder") }
    else { print("none decode_hw_\(n) no hardware decoder (driver has none for this codec)") }
}

// 2. Hardware encode: a compression session that requires the hardware encoder, 60 frames of 1080p
func hwEncode(_ codec: CMVideoCodecType) -> (OSStatus, Int, Double) {
    var sess: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
    var frames = 0
    let st = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: codec, encoderSpecification: spec,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &sess)
    guard st == noErr, let s = sess else { return (st, 0, 0) }
    let t0 = Date()
    for f in 0..<60 {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let b = pb else { break }
        CVPixelBufferLockBaseAddress(b, []); memset(CVPixelBufferGetBaseAddress(b)!, Int32(f * 4 & 255), CVPixelBufferGetDataSize(b))
        CVPixelBufferUnlockBaseAddress(b, [])
        VTCompressionSessionEncodeFrame(s, imageBuffer: b, presentationTimeStamp: CMTime(value: Int64(f), timescale: 60), duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil) { status, _, sb in if status == noErr && sb != nil { frames += 1 } }
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    let dt = Date().timeIntervalSince(t0)
    VTCompressionSessionInvalidate(s)
    return (noErr, frames, Double(frames) / dt)
}
for (n, c) in [("h264", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC)] {
    let (st, frames, fps) = hwEncode(c)
    if st == noErr && frames == 60 { ok("encode_hw_\(n)", "1080p, \(frames) frames, \(Int(fps)) fps") }
    else { fail("encode_hw_\(n)", st != noErr ? "session refused \(st) (-12902 = no hardware encoder)" : "\(frames)/60 frames") }
}
func encode(_ name: String, codec: AVVideoCodecType, w: Int, h: Int, requireHW: Bool) -> URL? {
    let url = URL(fileURLWithPath: "clip-\(name).mov"); try? FileManager.default.removeItem(at: url)
    guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
    let comp: [String: Any] = [AVVideoAverageBitRateKey: 8_000_000]
    let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                     AVVideoCompressionPropertiesKey: comp])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes:
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
         kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    wr.add(inp); guard wr.startWriting() else { return nil }; wr.startSession(atSourceTime: .zero)
    let t0 = Date()
    for f in 0..<120 {
        while !inp.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
        guard let b = pb else { return nil }
        CVPixelBufferLockBaseAddress(b, []); let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h { for x in stride(from: 0, to: w, by: 1) { let i = y * bpr + x * 4
            p[i] = UInt8((x + f * 4) & 255); p[i + 1] = UInt8((y + f * 2) & 255); p[i + 2] = UInt8(((x / 64 + y / 64 + f / 10) & 1) * 200); p[i + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(b, [])
        if !ad.append(b, withPresentationTime: CMTime(value: Int64(f), timescale: 60)) { break }
    }
    inp.markAsFinished(); let sem = DispatchSemaphore(value: 0); wr.finishWriting { sem.signal() }; sem.wait()
    if wr.status != .completed { print("  writer \(name): \(wr.error?.localizedDescription ?? "status \(wr.status.rawValue)")"); return nil }
    print("  encoded \(name) \(w)x\(h) 120 frames in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    return url
}
// clips for the decode test and avplay: hardware if it works, otherwise any encoder
var clips: [(String, URL)] = []
for (n, c) in [("h264", AVVideoCodecType.h264), ("hevc", AVVideoCodecType.hevc)] {
    for (res, w, h) in [("1080p", 1920, 1080), ("4k", 3840, 2160)] {
        if let u = encode("\(n)-\(res)", codec: c, w: w, h: h, requireHW: false) { clips.append(("\(n)_\(res)", u)) }
    }
}

// 3. Decode each clip through a session; check the hardware flag and the decode rate
for (n, url) in clips {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first, let rd = try? AVAssetReader(asset: asset) else { fail("decode_\(n)", "cannot read clip"); continue }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil); rd.add(out); rd.startReading()
    var samples: [CMSampleBuffer] = []
    while let s = out.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 && CMSampleBufferGetFormatDescription(s) != nil { samples.append(s) } }
    guard let fd = samples.first.flatMap({ CMSampleBufferGetFormatDescription($0) }) else { fail("decode_\(n)", "no samples"); continue }
    var sess: VTDecompressionSession?
    let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
    let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
    var st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec, imageBufferAttributes: attrs,
                                          outputCallback: nil, decompressionSessionOut: &sess)
    guard st == noErr, let s = sess else { fail("decode_\(n)", "session create \(st)"); continue }
    var hwv: CFTypeRef?; VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hwv)
    let hw = (hwv as? Bool) ?? false
    var frames = 0, errs = 0; let t0 = Date()
    for smp in samples {
        st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: smp, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr && img != nil { frames += 1 } else { errs += 1 } }
        if st != noErr { errs += 1 }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(s)
    let fps = Double(frames) / Date().timeIntervalSince(t0)
    VTDecompressionSessionInvalidate(s)
    let d = "\(frames)/\(samples.count) frames, \(Int(fps)) fps, hardware \(hw ? "yes" : "NO")"
    if frames == samples.count && errs == 0 && hw { ok("decode_\(n)", d) } else { fail("decode_\(n)", d + ", \(errs) errors") }
}
print("summary \(fails) fail")
exit(fails == 0 ? 0 : 2)
