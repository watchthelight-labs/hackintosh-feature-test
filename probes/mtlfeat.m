// <wtl> project: hackintosh-feature-test | file: probes/mtlfeat.m | author: watchthelight </wtl>
// mtlfeat: renders or computes with each Metal feature and reads the result back. One line per check:
//   ok <name> <detail> | FAIL <name> <why> | refused <name> <why>   (refused = the device says it does not support it)
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

static id<MTLDevice> D; static id<MTLCommandQueue> Q;
static int nok, nfail;
#define OK(n, ...) do { nok++; printf("ok %s ", n); printf(__VA_ARGS__); printf("\n"); } while (0)
#define FAIL(n, ...) do { nfail++; printf("FAIL %s ", n); printf(__VA_ARGS__); printf("\n"); } while (0)
#define REFUSED(n, ...) do { printf("refused %s ", n); printf(__VA_ARGS__); printf("\n"); } while (0)

static id<MTLFunction> fn(id<MTLLibrary> L, NSString *n, const char *test) {
    id<MTLFunction> f = [L newFunctionWithName:n];
    if (!f) FAIL(test, "newFunctionWithName(%s) returned nil", n.UTF8String);
    return f;
}
static id<MTLLibrary> lib(NSString *src, NSError **e) {
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion3_0;
    return [D newLibraryWithSource:src options:o error:e];
}
static BOOL run(id<MTLCommandBuffer> cb, const char *name) {
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { FAIL(name, "command buffer status %ld: %s", (long)cb.status,
        cb.error.localizedDescription.UTF8String ?: ""); return NO; }
    return YES;
}
static id<MTLTexture> rt(MTLPixelFormat f, int w, int h, int samples) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    t.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; t.storageMode = MTLStorageModePrivate;
    if (samples > 1) { t.textureType = MTLTextureType2DMultisample; t.sampleCount = samples; }
    return [D newTextureWithDescriptor:t];
}
// BGRA8 / RGBA8 texture -> pixels (4 bytes each)
static NSData *readback(id<MTLTexture> t) {
    NSUInteger bpr = t.width * 4;
    id<MTLBuffer> b = [D newBufferWithLength:bpr * t.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [Q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
               toBuffer:b destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * t.height];
    [bl endEncoding];
    if (!run(cb, "readback")) return nil;
    return [NSData dataWithBytes:b.contents length:b.length];
}
static BOOL near(const uint8_t *p, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {  // BGRA in memory
    return abs(p[2] - r) <= 2 && abs(p[1] - g) <= 2 && abs(p[0] - b) <= 2 && abs(p[3] - a) <= 2;
}

static NSString *kTri = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vtri(uint i [[vertex_id]]) { float2 q[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(q[i],0,1); return o; }\n"
    "fragment half4 fred() { return half4(1, 0.5h, 0.25h, 1); }\n"
    "kernel void add(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *c [[buffer(2)]], uint i [[thread_position_in_grid]]) { c[i] = a[i] + b[i]; }\n";

static id<MTLRenderPipelineState> triPSO(id<MTLLibrary> L, int samples, MTLPixelFormat f) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [L newFunctionWithName:@"vtri"]; pd.fragmentFunction = [L newFunctionWithName:@"fred"];
    pd.colorAttachments[0].pixelFormat = f; pd.rasterSampleCount = samples;
    NSError *e; id<MTLRenderPipelineState> p = [D newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!p) printf("  pso error: %s\n", e.localizedDescription.UTF8String);
    return p;
}
static MTLRenderPassDescriptor *pass(id<MTLTexture> t, id<MTLTexture> resolve) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = resolve ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    rp.colorAttachments[0].resolveTexture = resolve;
    return rp;
}

static void t_clear(void) {
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    MTLRenderPassDescriptor *rp = pass(t, nil); rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    if (!run(cb, "clear")) return;
    NSData *d = readback(t); if (!d) return;
    const uint8_t *p = d.bytes + (32 * 64 + 32) * 4;
    if (near(p, 51, 102, 153, 255)) OK("clear", "64x64 bgra8"); else FAIL("clear", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_triangle(id<MTLLibrary> L) {
    id<MTLRenderPipelineState> ps = triPSO(L, 1, MTLPixelFormatBGRA8Unorm); if (!ps) { FAIL("triangle", "no pipeline"); return; }
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(t, nil)];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    if (!run(cb, "triangle")) return;
    NSData *d = readback(t); if (!d) return; const uint8_t *p = d.bytes + (40 * 64 + 20) * 4;
    if (near(p, 255, 128, 64, 255)) OK("triangle", "runtime-compiled MSL"); else FAIL("triangle", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_msaa(id<MTLLibrary> L) {
    if (![D supportsTextureSampleCount:4]) { REFUSED("msaa4", "no 4x"); return; }
    id<MTLRenderPipelineState> ps = triPSO(L, 4, MTLPixelFormatBGRA8Unorm); if (!ps) { FAIL("msaa4", "no pipeline"); return; }
    id<MTLTexture> ms = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 4), t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(ms, t)];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    if (!run(cb, "msaa4")) return;
    NSData *d = readback(t); if (!d) return; const uint8_t *p = d.bytes + (40 * 64 + 20) * 4;
    if (near(p, 255, 128, 64, 255)) OK("msaa4", "4x resolve"); else FAIL("msaa4", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_compute(id<MTLLibrary> L) {
    const int n = 1 << 20; NSError *er;
    id<MTLFunction> f = fn(L, @"add", "compute"); if (!f) return;
    id<MTLComputePipelineState> cp = [D newComputePipelineStateWithFunction:f error:&er];
    if (!cp) { FAIL("compute", "%s", er.localizedDescription.UTF8String); return; }
    id<MTLBuffer> a = [D newBufferWithLength:n * 4 options:0], b = [D newBufferWithLength:n * 4 options:0], c = [D newBufferWithLength:n * 4 options:0];
    float *pa = a.contents, *pb = b.contents; for (int i = 0; i < n; i++) { pa[i] = i; pb[i] = 2 * i; }
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:cp]; [e setBuffer:a offset:0 atIndex:0]; [e setBuffer:b offset:0 atIndex:1]; [e setBuffer:c offset:0 atIndex:2];
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [e endEncoding];
    if (!run(cb, "compute")) return;
    float *pc = c.contents; int bad = 0; for (int i = 0; i < n; i++) if (pc[i] != 3.0f * i) bad++;
    double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
    if (!bad) OK("compute", "1M adds, %.2f ms GPU", ms); else FAIL("compute", "%d wrong", bad);
}
static void t_blit(void) {
    const int n = 1 << 22;
    id<MTLBuffer> s = [D newBufferWithLength:n options:MTLResourceStorageModeShared], p = [D newBufferWithLength:n options:MTLResourceStorageModePrivate],
        r = [D newBufferWithLength:n options:MTLResourceStorageModeShared];
    uint8_t *ps = s.contents; for (int i = 0; i < n; i++) ps[i] = (uint8_t)(i * 7);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:s sourceOffset:0 toBuffer:p destinationOffset:0 size:n]; [b copyFromBuffer:p sourceOffset:0 toBuffer:r destinationOffset:0 size:n];
    [b fillBuffer:r range:NSMakeRange(0, 16) value:0xAB]; [b endEncoding];
    if (!run(cb, "blit")) return;
    const uint8_t *pr = r.contents; int bad = 0;
    for (int i = 0; i < n; i++) if (pr[i] != (i < 16 ? 0xAB : (uint8_t)(i * 7))) bad++;
    if (!bad) OK("blit", "4 MB shared->private->shared + fill"); else FAIL("blit", "%d bytes wrong", bad);
}
static void t_icb(id<MTLLibrary> L) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [L newFunctionWithName:@"vtri"]; pd.fragmentFunction = [L newFunctionWithName:@"fred"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; pd.supportIndirectCommandBuffers = YES;
    NSError *e; id<MTLRenderPipelineState> ps = [D newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { FAIL("icb", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    MTLIndirectCommandBufferDescriptor *id_ = [MTLIndirectCommandBufferDescriptor new];
    id_.commandTypes = MTLIndirectCommandTypeDraw; id_.inheritPipelineState = NO; id_.inheritBuffers = NO;
    id<MTLIndirectCommandBuffer> icb = [D newIndirectCommandBufferWithDescriptor:id_ maxCommandCount:1 options:0];
    if (!icb) { REFUSED("icb", "newIndirectCommandBuffer nil"); return; }
    id<MTLIndirectRenderCommand> c = [icb indirectRenderCommandAtIndex:0];
    [c setRenderPipelineState:ps]; [c drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:0];
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:pass(t, nil)];
    [en executeCommandsInBuffer:icb withRange:NSMakeRange(0, 1)]; [en endEncoding];
    if (!run(cb, "icb")) return;
    NSData *d = readback(t); if (!d) return; const uint8_t *p = d.bytes + (40 * 64 + 20) * 4;
    if (near(p, 255, 128, 64, 255)) OK("icb", "CPU-encoded indirect draw"); else FAIL("icb", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_mesh(void) {
    if (![D supportsFamily:MTLGPUFamilyMetal3]) { REFUSED("mesh", "no Metal3 family"); return; }
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; }; using M = mesh<V, void, 3, 1, topology::triangle>;\n"
        "[[mesh]] void mtri(M m, uint t [[thread_index_in_threadgroup]]) {\n"
        "  float2 q[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; if (t < 3) { V v; v.p = float4(q[t],0,1); m.set_vertex(t, v); m.set_index(t, t); }\n"
        "  if (t == 0) m.set_primitive_count(1); }\n"
        "fragment half4 fgreen() { return half4(0, 1, 0, 1); }\n";
    NSError *e; id<MTLLibrary> L = lib(src, &e); if (!L) { FAIL("mesh", "compile: %s", e.localizedDescription.UTF8String); return; }
    MTLMeshRenderPipelineDescriptor *md = [MTLMeshRenderPipelineDescriptor new];
    md.meshFunction = [L newFunctionWithName:@"mtri"]; md.fragmentFunction = [L newFunctionWithName:@"fgreen"];
    md.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> ps = [D newRenderPipelineStateWithMeshDescriptor:md options:0 reflection:nil error:&e];
    if (!ps) { FAIL("mesh", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:pass(t, nil)];
    [en setRenderPipelineState:ps];
    [en drawMeshThreadgroups:MTLSizeMake(1, 1, 1) threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(3, 1, 1)];
    [en endEncoding];
    if (!run(cb, "mesh")) return;
    NSData *d = readback(t); if (!d) return; const uint8_t *p = d.bytes + (40 * 64 + 20) * 4;
    if (near(p, 0, 255, 0, 255)) OK("mesh", "mesh shader triangle"); else FAIL("mesh", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_tess(void) {
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct CP { float4 p [[attribute(0)]]; }; struct V { float4 p [[position]]; };\n"
        "[[patch(triangle, 3)]] vertex V vtess(patch_control_point<CP> c [[stage_in]], float3 b [[position_in_patch]]) {\n"
        "  V o; o.p = c[0].p * b.x + c[1].p * b.y + c[2].p * b.z; return o; }\n"
        "fragment half4 fblue() { return half4(0, 0, 1, 1); }\n";
    NSError *e; id<MTLLibrary> L = lib(src, &e); if (!L) { FAIL("tessellation", "compile: %s", e.localizedDescription.UTF8String); return; }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 0;
    vd.layouts[0].stride = 16; vd.layouts[0].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [L newFunctionWithName:@"vtess"]; pd.fragmentFunction = [L newFunctionWithName:@"fblue"];
    pd.vertexDescriptor = vd; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.tessellationPartitionMode = MTLTessellationPartitionModeInteger; pd.maxTessellationFactor = 16;
    pd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionConstant;
    id<MTLRenderPipelineState> ps = [D newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { FAIL("tessellation", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    float cps[12] = {-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1};
    id<MTLBuffer> cpb = [D newBufferWithBytes:cps length:sizeof cps options:0];
    MTLTriangleTessellationFactorsHalf f = {{0x4400, 0x4400, 0x4400}, 0x4400};  // 4.0 in half
    id<MTLBuffer> fb = [D newBufferWithBytes:&f length:sizeof f options:0];
    id<MTLTexture> t = rt(MTLPixelFormatBGRA8Unorm, 64, 64, 1);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:pass(t, nil)];
    [en setRenderPipelineState:ps]; [en setVertexBuffer:cpb offset:0 atIndex:0];
    [en setTessellationFactorBuffer:fb offset:0 instanceStride:0];
    [en drawPatches:3 patchStart:0 patchCount:1 patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
    [en endEncoding];
    if (!run(cb, "tessellation")) return;
    NSData *d = readback(t); if (!d) return; const uint8_t *p = d.bytes + (40 * 64 + 20) * 4;
    if (near(p, 0, 0, 255, 255)) OK("tessellation", "triangle patch, factor 4"); else FAIL("tessellation", "got %d,%d,%d", p[2], p[1], p[0]);
}
static void t_vft(void) {
    if (!D.supportsFunctionPointers) { REFUSED("visible_function_table", "supportsFunctionPointers NO"); return; }
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "[[visible]] float twice(float x) { return 2 * x; }\n"
        "kernel void vk(device float *o [[buffer(0)]], visible_function_table<float(float)> t [[buffer(1)]], uint i [[thread_position_in_grid]]) { o[i] = t[0](float(i)); }\n";
    NSError *e; id<MTLLibrary> L = lib(src, &e); if (!L) { FAIL("visible_function_table", "compile: %s", e.localizedDescription.UTF8String); return; }
    id<MTLFunction> tw = fn(L, @"twice", "visible_function_table"), vk = tw ? fn(L, @"vk", "visible_function_table") : nil; if (!vk) return;
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new]; cd.computeFunction = vk;
    MTLLinkedFunctions *lf = [MTLLinkedFunctions new]; lf.functions = @[tw]; cd.linkedFunctions = lf;
    id<MTLComputePipelineState> cp = [D newComputePipelineStateWithDescriptor:cd options:0 reflection:nil error:&e];
    if (!cp) { FAIL("visible_function_table", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    MTLVisibleFunctionTableDescriptor *vd = [MTLVisibleFunctionTableDescriptor new]; vd.functionCount = 1;
    id<MTLVisibleFunctionTable> vt = [cp newVisibleFunctionTableWithDescriptor:vd];
    [vt setFunction:[cp functionHandleWithFunction:tw] atIndex:0];
    id<MTLBuffer> o = [D newBufferWithLength:64 * 4 options:0];
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:cp]; [en setBuffer:o offset:0 atIndex:0]; [en setVisibleFunctionTable:vt atBufferIndex:1];
    [en dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [en endEncoding];
    if (!run(cb, "visible_function_table")) return;
    float *po = o.contents; int bad = 0; for (int i = 0; i < 64; i++) if (po[i] != 2.0f * i) bad++;
    if (!bad) OK("visible_function_table", "64 calls through the table"); else FAIL("visible_function_table", "%d wrong (o[3]=%g)", bad, po[3]);
}
static void t_raytracing(void) {
    if (!D.supportsRaytracing) { REFUSED("raytracing", "supportsRaytracing NO"); return; }
    float vtx[9] = {-1, -1, 0, 1, -1, 0, 0, 1, 0};
    id<MTLBuffer> vb = [D newBufferWithBytes:vtx length:sizeof vtx options:0];
    MTLAccelerationStructureTriangleGeometryDescriptor *gd = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    gd.vertexBuffer = vb; gd.vertexStride = 12; gd.triangleCount = 1;
    MTLPrimitiveAccelerationStructureDescriptor *ad = [MTLPrimitiveAccelerationStructureDescriptor descriptor]; ad.geometryDescriptors = @[gd];
    MTLAccelerationStructureSizes sz = [D accelerationStructureSizesWithDescriptor:ad];
    id<MTLAccelerationStructure> as = [D newAccelerationStructureWithSize:sz.accelerationStructureSize];
    id<MTLBuffer> scratch = [D newBufferWithLength:MAX(sz.buildScratchBufferSize, 16) options:MTLResourceStorageModePrivate];
    if (!as) { FAIL("raytracing", "no acceleration structure"); return; }
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLAccelerationStructureCommandEncoder> ae = [cb accelerationStructureCommandEncoder];
    [ae buildAccelerationStructure:as descriptor:ad scratchBuffer:scratch scratchBufferOffset:0]; [ae endEncoding];
    if (!run(cb, "raytracing")) return;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal; using namespace raytracing;\n"
        "kernel void rk(primitive_acceleration_structure a [[buffer(0)]], device int *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
        "  ray r(float3((i == 0) ? 0.0 : 5.0, 0, -1), float3(0, 0, 1)); intersector<triangle_data> s; auto h = s.intersect(r, a);\n"
        "  o[i] = h.type == intersection_type::triangle ? 1 : 0; }\n";
    NSError *e; id<MTLLibrary> L = lib(src, &e); if (!L) { FAIL("raytracing", "compile: %s", e.localizedDescription.UTF8String); return; }
    id<MTLFunction> rk = fn(L, @"rk", "raytracing"); if (!rk) return;
    id<MTLComputePipelineState> cp = [D newComputePipelineStateWithFunction:rk error:&e];
    if (!cp) { FAIL("raytracing", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    id<MTLBuffer> o = [D newBufferWithLength:8 options:0];
    cb = [Q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:cp]; [en setAccelerationStructure:as atBufferIndex:0]; [en setBuffer:o offset:0 atIndex:1];
    [en useResource:as usage:MTLResourceUsageRead];
    [en dispatchThreads:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 1, 1)]; [en endEncoding];
    if (!run(cb, "raytracing")) return;
    int *po = o.contents;
    if (po[0] == 1 && po[1] == 0) OK("raytracing", "hit and miss right"); else FAIL("raytracing", "hit=%d miss=%d (want 1,0)", po[0], po[1]);
}
static void t_formats(void) {
    struct { const char *n; MTLPixelFormat f; BOOL rtOk; } fs[] = {
        {"rgba16f", MTLPixelFormatRGBA16Float, YES}, {"rgba32f", MTLPixelFormatRGBA32Float, YES}, {"r32uint", MTLPixelFormatR32Uint, YES},
        {"rgb10a2", MTLPixelFormatRGB10A2Unorm, YES}, {"bgra8srgb", MTLPixelFormatBGRA8Unorm_sRGB, YES}, {"a8", MTLPixelFormatA8Unorm, NO},
        {"depth32f_s8", MTLPixelFormatDepth32Float_Stencil8, NO}, {"bc1", MTLPixelFormatBC1_RGBA, NO}, {"bc7", MTLPixelFormatBC7_RGBAUnorm, NO},
        {"astc4x4", MTLPixelFormatASTC_4x4_LDR, NO},
    };
    for (size_t i = 0; i < sizeof fs / sizeof fs[0]; i++) {
        char name[64]; snprintf(name, sizeof name, "format_%s", fs[i].n);
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fs[i].f width:64 height:64 mipmapped:NO];
        t.storageMode = MTLStorageModePrivate;
        t.usage = MTLTextureUsageShaderRead | (fs[i].rtOk || fs[i].f == MTLPixelFormatDepth32Float_Stencil8 ? MTLTextureUsageRenderTarget : 0);
        id<MTLTexture> x = nil;
        @try { x = [D newTextureWithDescriptor:t]; } @catch (NSException *e) { x = nil; }
        if (!x) { if (fs[i].f == MTLPixelFormatASTC_4x4_LDR) REFUSED(name, "ASTC is Apple-GPU only (expected)"); else FAIL(name, "texture not created"); continue; }
        if (fs[i].rtOk) {
            MTLRenderPassDescriptor *rp = pass(x, nil);
            id<MTLCommandBuffer> cb = [Q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            if (!run(cb, name)) continue;
        }
        if (fs[i].f == MTLPixelFormatASTC_4x4_LDR) OK(name, "created (driver accepts ASTC)"); else OK(name, "%s", fs[i].rtOk ? "created + cleared" : "created");
    }
}
static void t_iosurface(id<MTLLibrary> L) {
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64,
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    t.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; t.storageMode = MTLStorageModeManaged;
    id<MTLTexture> x = [D newTextureWithDescriptor:t iosurface:s plane:0];
    if (!x) { FAIL("iosurface_rt", "texture over IOSurface not created"); CFRelease(s); return; }
    id<MTLRenderPipelineState> ps = triPSO(L, 1, MTLPixelFormatBGRA8Unorm);
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass(x, nil)];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    if (!run(cb, "iosurface_rt")) { CFRelease(s); return; }
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *p = (const uint8_t *)IOSurfaceGetBaseAddress(s) + 40 * IOSurfaceGetBytesPerRow(s) + 20 * 4;
    BOOL good = near(p, 255, 128, 64, 255); int r = p[2], g = p[1], b = p[0];
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); CFRelease(s);
    if (good) OK("iosurface_rt", "render into IOSurface, CPU reads it"); else FAIL("iosurface_rt", "CPU sees %d,%d,%d", r, g, b);
}
static void t_argbuf(void) {
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { device float *in; float k; };\n"
        "kernel void ak(constant A &a [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) { o[i] = a.in[i] * a.k; }\n";
    NSError *e; id<MTLLibrary> L = lib(src, &e); if (!L) { FAIL("argument_buffers_t2", "compile: %s", e.localizedDescription.UTF8String); return; }
    id<MTLFunction> ak = fn(L, @"ak", "argument_buffers_t2"); if (!ak) return;
    id<MTLComputePipelineState> cp = [D newComputePipelineStateWithFunction:ak error:&e];
    if (!cp) { FAIL("argument_buffers_t2", "pipeline: %s", e.localizedDescription.UTF8String); return; }
    id<MTLBuffer> in = [D newBufferWithLength:64 * 4 options:0], o = [D newBufferWithLength:64 * 4 options:0];
    float *pi = in.contents; for (int i = 0; i < 64; i++) pi[i] = i;
    struct { uint64_t p; float k; float pad; } arg = {in.gpuAddress, 3.0f, 0};
    id<MTLBuffer> ab = [D newBufferWithBytes:&arg length:sizeof arg options:0];
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:cp]; [en setBuffer:ab offset:0 atIndex:0]; [en setBuffer:o offset:0 atIndex:1];
    [en useResource:in usage:MTLResourceUsageRead];
    [en dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [en endEncoding];
    if (!run(cb, "argument_buffers_t2")) return;
    float *po = o.contents; int bad = 0; for (int i = 0; i < 64; i++) if (po[i] != 3.0f * i) bad++;
    if (!bad) OK("argument_buffers_t2", "GPU address in an argument buffer"); else FAIL("argument_buffers_t2", "%d wrong", bad);
}
static void t_sparse(void) {
    if (!D.sparseTileSizeInBytes) { REFUSED("sparse_heap", "sparseTileSizeInBytes 0"); return; }
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypeSparse; hd.size = 16 << 20; hd.storageMode = MTLStorageModePrivate;
    id<MTLHeap> h = [D newHeapWithDescriptor:hd];
    if (!h) { FAIL("sparse_heap", "sparse heap not created"); return; }
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
    t.storageMode = MTLStorageModePrivate; t.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> x = [h newTextureWithDescriptor:t];
    if (x) OK("sparse_heap", "sparse texture created (tile %lu B)", (unsigned long)D.sparseTileSizeInBytes); else FAIL("sparse_heap", "sparse texture nil");
}

int main(void) { @autoreleasepool {
    D = MTLCreateSystemDefaultDevice(); Q = [D newCommandQueue];
    if (!D) { printf("FAIL device none\n"); return 1; }
    printf("device %s\n", D.name.UTF8String);
    NSError *e; id<MTLLibrary> L = lib(kTri, &e);
    if (!L) { printf("FAIL compile %s\n", e.localizedDescription.UTF8String); return 1; }
    t_clear(); t_triangle(L); t_msaa(L); t_compute(L); t_blit(); t_icb(L); t_mesh(); t_tess(); t_vft(); t_raytracing();
    t_formats(); t_iosurface(L); t_argbuf(); t_sparse();
    printf("summary %d ok %d fail\n", nok, nfail);
    return nfail ? 2 : 0;
} }
