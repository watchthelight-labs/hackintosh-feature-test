// <wtl> project: hackintosh-feature-test | file: probes/mpsci.swift | author: watchthelight </wtl>
// mpsci: Metal Performance Shaders and Core Image on the GPU, each compared with the same work on the CPU.
//   ok <name> <detail> | FAIL <name> <why>
import Foundation
import Metal
import MetalPerformanceShaders
import CoreImage

let dev = MTLCreateSystemDefaultDevice()!
let q = dev.makeCommandQueue()!
let W = 256, H = 256
var fails = 0

func pattern() -> [UInt8] {
    var p = [UInt8](repeating: 0, count: W * H * 4)
    for y in 0..<H { for x in 0..<W {
        let i = (y * W + x) * 4
        p[i] = UInt8((x * 7 + y * 3) & 255); p[i + 1] = UInt8((x ^ y) & 255); p[i + 2] = UInt8(((x / 16 + y / 16) & 1) * 255); p[i + 3] = 255
    } }
    return p
}
func texture(_ px: [UInt8]?) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .managed
    let t = dev.makeTexture(descriptor: d)!
    if let px = px { t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4) }
    return t
}
func read(_ t: MTLTexture) -> [UInt8] {
    let cb = q.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: t); b.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var out = [UInt8](repeating: 0, count: W * H * 4)
    t.getBytes(&out, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    return out
}
func cmp(_ a: [UInt8], _ b: [UInt8], tol: Int) -> (bad: Int, maxd: Int) {
    var bad = 0, m = 0
    for i in 0..<a.count where i % 4 != 3 { let d = abs(Int(a[i]) - Int(b[i])); m = max(m, d); if d > tol { bad += 1 } }
    return (bad, m)
}
func report(_ n: String, _ r: (bad: Int, maxd: Int), _ tol: Int) {
    if r.bad == 0 { print("ok \(n) max diff \(r.maxd) (tolerance \(tol))") }
    else { fails += 1; print("FAIL \(n) \(r.bad) channel values off by more than \(tol) (max \(r.maxd))") }
}

let src = pattern()

// 1. MPS Gaussian blur vs the same blur through Core Image on the CPU renderer
do {
    let a = texture(src), b = texture(nil)
    let cb = q.makeCommandBuffer()!
    MPSImageGaussianBlur(device: dev, sigma: 3).encode(commandBuffer: cb, sourceTexture: a, destinationTexture: b)
    cb.commit(); cb.waitUntilCompleted()
    if cb.status != .completed { fails += 1; print("FAIL mps_gaussian command buffer \(cb.status.rawValue)") }
    else {
        let gpu = read(b)
        let ci = CIImage(bitmapData: Data(src), bytesPerRow: W * 4, size: CGSize(width: W, height: H), format: .RGBA8, colorSpace: nil)
            .clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let cpuCtx = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var cpu = [UInt8](repeating: 0, count: W * H * 4)
        cpuCtx.render(ci, toBitmap: &cpu, rowBytes: W * 4, bounds: ci.extent, format: .RGBA8, colorSpace: nil)
        // MPS and CI blur kernels differ slightly at the edges; compare the interior
        var a1 = [UInt8](), b1 = [UInt8]()
        for y in 16..<(H - 16) { for x in 16..<(W - 16) { let i = (y * W + x) * 4; a1 += gpu[i..<i + 4]; b1 += cpu[i..<i + 4] } }
        report("mps_gaussian_vs_cpu", cmp(a1, b1, tol: 12), 12)
    }
}
// 2. Core Image filter graph: GPU (Metal) context vs CPU (software) context
do {
    let ci = CIImage(bitmapData: Data(src), bytesPerRow: W * 4, size: CGSize(width: W, height: H), format: .RGBA8, colorSpace: nil)
    let graph = ci.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.4, "inputContrast": 1.1])
        .applyingFilter("CIHueAdjust", parameters: ["inputAngle": 0.6])
        .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5])
        .applyingFilter("CIVignette", parameters: ["inputIntensity": 0.8, "inputRadius": 1.5])
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    func render(_ c: CIContext) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: W * H * 4)
        c.render(graph, toBitmap: &o, rowBytes: W * 4, bounds: graph.extent, format: .RGBA8, colorSpace: nil); return o
    }
    let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]
    let gpu = render(CIContext(mtlDevice: dev, options: opts))
    let cpu = render(CIContext(options: opts.merging([.useSoftwareRenderer: true]) { $1 }))
    report("coreimage_graph_gpu_vs_cpu", cmp(gpu, cpu, tol: 6), 6)
}
// 3. MPS matrix multiply vs CPU
do {
    let n = 128
    let desc = MPSMatrixDescriptor(rows: n, columns: n, rowBytes: n * 4, dataType: .float32)
    var A = [Float](repeating: 0, count: n * n), B = A
    for i in 0..<(n * n) { A[i] = Float(i % 7) * 0.25; B[i] = Float(i % 5) * 0.5 }
    let ba = dev.makeBuffer(bytes: A, length: n * n * 4)!, bb = dev.makeBuffer(bytes: B, length: n * n * 4)!, bc = dev.makeBuffer(length: n * n * 4)!
    let cb = q.makeCommandBuffer()!
    MPSMatrixMultiplication(device: dev, resultRows: n, resultColumns: n, interiorColumns: n)
        .encode(commandBuffer: cb, leftMatrix: MPSMatrix(buffer: ba, descriptor: desc), rightMatrix: MPSMatrix(buffer: bb, descriptor: desc),
                resultMatrix: MPSMatrix(buffer: bc, descriptor: desc))
    cb.commit(); cb.waitUntilCompleted()
    let C = bc.contents().bindMemory(to: Float.self, capacity: n * n)
    var bad = 0
    for r in 0..<n { for c in 0..<n {
        var s: Float = 0; for k in 0..<n { s += A[r * n + k] * B[k * n + c] }
        if abs(s - C[r * n + c]) > 0.01 * max(1, abs(s)) { bad += 1 }
    } }
    if bad == 0 { print("ok mps_matrix_multiply 128x128") } else { fails += 1; print("FAIL mps_matrix_multiply \(bad) of \(n * n) wrong") }
}
print("summary \(fails) fail")
exit(fails == 0 ? 0 : 2)
