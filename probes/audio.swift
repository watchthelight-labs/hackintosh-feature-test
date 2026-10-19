// <wtl> project: hackintosh-feature-test | file: probes/audio.swift | author: watchthelight </wtl>
// audio list | volume | record. list: every CoreAudio device with its direction and rates; volume: set and read the
// default output's volume, restored; record: 3 s from the default input, RMS. ok <detail> | FAIL <detail>
import Foundation
import CoreAudio
import AVFoundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ v: T) -> T? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var x = v; var sz = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &x) == noErr ? x : nil
}
func name(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &n) == noErr ? (n?.takeRetainedValue() as String? ?? "?") : "?"
}
func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0; guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, buf) == noErr else { return 0 }
    let l = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return l.reduce(0) { $0 + Int($1.mNumberChannels) }
}
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "list"
let sys = AudioObjectID(kAudioObjectSystemObject)
switch mode {
case "list":
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4); AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids)
    var outs = 0, ins = 0
    for id in ids {
        let o = channels(id, kAudioObjectPropertyScopeOutput), i = channels(id, kAudioObjectPropertyScopeInput)
        let rate = prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
        if o > 0 { outs += 1 }; if i > 0 { ins += 1 }
        print("device \(name(id)) out \(o) ch in \(i) ch \(Int(rate)) Hz")
    }
    let dout = prop(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    let din = prop(sys, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    print("summary \(outs) output, \(ins) input devices; default out '\(name(dout))', in '\(name(din))'")
case "volume":
    let dout = prop(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var before: Float32 = 0; var sz = UInt32(4)
    guard AudioObjectGetPropertyData(dout, &a, 0, nil, &sz, &before) == noErr else { print("FAIL volume not readable on '\(name(dout))'"); exit(2) }
    var target: Float32 = before > 0.5 ? before - 0.2 : before + 0.2
    let rs = AudioObjectSetPropertyData(dout, &a, 0, nil, 4, &target)
    var after: Float32 = 0; AudioObjectGetPropertyData(dout, &a, 0, nil, &sz, &after)
    var b = before; AudioObjectSetPropertyData(dout, &a, 0, nil, 4, &b)
    var back: Float32 = 0; AudioObjectGetPropertyData(dout, &a, 0, nil, &sz, &back)
    let line = String(format: "'%@' before %.2f set %.2f (rc %d) read %.2f restored %.2f", name(dout), before, target, rs, after, back)
    print(abs(after - target) < 0.03 && abs(back - before) < 0.03 ? "ok \(line)" : "FAIL \(line)")
case "record":
    let s = DispatchSemaphore(value: 0); var allowed = false
    AVCaptureDevice.requestAccess(for: .audio) { a in allowed = a; s.signal() }; s.wait()
    guard allowed else { print("FAIL microphone permission denied"); exit(2) }
    let eng = AVAudioEngine(); let inp = eng.inputNode; let fmt = inp.outputFormat(forBus: 0)
    var sum = 0.0, n = 0, peak: Float = 0
    inp.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
        guard let d = buf.floatChannelData else { return }
        for i in 0..<Int(buf.frameLength) { let v = d[0][i]; sum += Double(v * v); peak = max(peak, abs(v)) }; n += Int(buf.frameLength)
    }
    do { try eng.start() } catch { print("FAIL engine start: \(error.localizedDescription)"); exit(2) }
    Thread.sleep(forTimeInterval: 3); eng.stop()
    let rms = n > 0 ? sqrt(sum / Double(n)) : 0
    print(String(format: "rms %.5f peak %.4f over %d samples at %.0f Hz", rms, peak, n, fmt.sampleRate))
default: print("usage: audio list|volume|record")
}
