// <wtl> project: hackintosh-feature-test | file: probes/metalcaps.m | author: watchthelight </wtl>
// metalcaps: what the default Metal device says it supports. One "key value" line each, for the feature matrix.
#import <Metal/Metal.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { printf("FAIL no Metal device\n"); return 1; }
    printf("name %s\n", d.name.UTF8String);
    printf("registryID 0x%llx lowPower %d headless %d removable %d unifiedMemory %d\n", d.registryID, d.isLowPower,
           d.isHeadless, d.isRemovable, d.hasUnifiedMemory);
    struct { const char *n; MTLGPUFamily f; } fam[] = {
        {"Apple1", MTLGPUFamilyApple1}, {"Apple2", MTLGPUFamilyApple2}, {"Apple3", MTLGPUFamilyApple3},
        {"Apple4", MTLGPUFamilyApple4}, {"Apple5", MTLGPUFamilyApple5}, {"Apple6", MTLGPUFamilyApple6},
        {"Apple7", MTLGPUFamilyApple7}, {"Apple8", MTLGPUFamilyApple8}, {"Apple9", MTLGPUFamilyApple9},
        {"Mac2", MTLGPUFamilyMac2}, {"Common1", MTLGPUFamilyCommon1}, {"Common2", MTLGPUFamilyCommon2},
        {"Common3", MTLGPUFamilyCommon3}, {"Metal3", MTLGPUFamilyMetal3},
    };
    for (size_t i = 0; i < sizeof fam / sizeof fam[0]; i++)
        printf("family %s %s\n", fam[i].n, [d supportsFamily:fam[i].f] ? "YES" : "no");
    printf("argumentBuffersTier %ld\n", (long)d.argumentBuffersSupport + 1);
    printf("readWriteTextureTier %ld\n", (long)d.readWriteTextureSupport);
    printf("raytracing %d\n", d.supportsRaytracing);
    printf("raytracingFromRender %d\n", d.supportsRaytracingFromRender);
    printf("functionPointers %d fromRender %d\n", d.supportsFunctionPointers, d.supportsFunctionPointersFromRender);
    printf("dynamicLibraries %d fromRender %d\n", d.supportsDynamicLibraries, d.supportsRenderDynamicLibraries);
    printf("barycentrics %d\n", d.supportsShaderBarycentricCoordinates);
    printf("primitiveMotionBlur %d\n", d.supportsPrimitiveMotionBlur);
    printf("rasterOrderGroups %d\n", d.areRasterOrderGroupsSupported);
    printf("BCTextureCompression %d\n", d.supportsBCTextureCompression);
    printf("depth24Stencil8 %d\n", d.isDepth24Stencil8PixelFormatSupported);
    printf("32bitFloatFiltering %d 32bitMSAA %d\n", d.supports32BitFloatFiltering, d.supports32BitMSAA);
    printf("queryTextureLOD %d pullModelInterpolation %d\n", d.supportsQueryTextureLOD, d.supportsPullModelInterpolation);
    printf("programmableSamplePositions %d\n", d.areProgrammableSamplePositionsSupported);
    printf("sparseTileBytes %lu\n", (unsigned long)d.sparseTileSizeInBytes);
    printf("maxBufferLength %llu MB\n", (unsigned long long)d.maxBufferLength >> 20);
    printf("recommendedMaxWorkingSet %llu MB\n", d.recommendedMaxWorkingSetSize >> 20);
    printf("maxThreadsPerThreadgroup %lux%lux%lu\n", (unsigned long)d.maxThreadsPerThreadgroup.width,
           (unsigned long)d.maxThreadsPerThreadgroup.height, (unsigned long)d.maxThreadsPerThreadgroup.depth);
    printf("maxThreadgroupMemory %lu\n", (unsigned long)d.maxThreadgroupMemoryLength);
    printf("maxArgumentBufferSamplers %lu\n", (unsigned long)d.maxArgumentBufferSamplerCount);
    printf("location %ld locationNumber %lu peerGroup %llu\n", (long)d.location, (unsigned long)d.locationNumber, d.peerGroupID);
    NSMutableString *sc = [NSMutableString string];
    for (int n = 1; n <= 16; n *= 2) if ([d supportsTextureSampleCount:n]) [sc appendFormat:@" %d", n];
    printf("sampleCounts%s\n", sc.UTF8String);
    NSMutableString *cs = [NSMutableString string];
    for (id<MTLCounterSet> s in d.counterSets) [cs appendFormat:@" %@", s.name];
    printf("counterSets%s\n", cs.length ? cs.UTF8String : " none");
    printf("counterSampling atDraw %d atDispatch %d atBlit %d atStage %d\n",
           [d supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary],
           [d supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary],
           [d supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary],
           [d supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]);
    NSArray *all = MTLCopyAllDevices();
    printf("devices %lu\n", (unsigned long)all.count);
    for (id<MTLDevice> x in all) printf("device %s lowPower %d headless %d\n", x.name.UTF8String, x.isLowPower, x.isHeadless);
    return 0;
} }
