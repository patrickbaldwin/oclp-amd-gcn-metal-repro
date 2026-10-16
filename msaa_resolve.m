// SPDX-License-Identifier: MIT
// Standalone Metal reproduction (no ANGLE): draw into an MSAA texture, then read it with texture2d_ms in a
// second render pass. Variants selected by argv. Build:
//   clang -fobjc-arc -O0 -framework Metal -framework Foundation msaa_resolve.m -o msaa_resolve
// Usage: msaa_resolve <fmt: rgba8|r32f|rgba16f|r8> <store: store|resolve|storeresolve> <read: loop|one|hw> [samples=4] [gpu=0]
//   store: store action of the MSAA pass. read: how the second pass gets a single-sample result:
//     loop = fragment shader averaging texture2d_ms.read over get_num_samples()  (what ANGLE does)
//     one  = fragment shader reading only sample 0
//     hw   = no second pass (hardware resolve via the store action only)
//     hwload  = second render pass: attach MSAA texture with Load, store MultisampleResolve into a 1x texture
//     compute = compute kernel reading texture2d_ms sample 0 into a 1x texture
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *kSrc = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; };\n"
    "vertex VOut vs(uint vid [[vertex_id]]) {\n"
    "  float2 p[6] = {{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};\n"
    "  VOut o; o.pos = float4(p[vid],0,1); return o; }\n"
    "fragment float4 fsRed(VOut in [[stage_in]]) { return float4(1,0,0,1); }\n"
    "fragment float4 fsLoop(VOut in [[stage_in]], texture2d_ms<float> src [[texture(0)]]) {\n"
    "  uint2 c = uint2(in.pos.xy); uint n = src.get_num_samples(); float4 s = 0;\n"
    "  for (uint i = 0; i < n; ++i) s += src.read(c, i);\n"
    "  return s / n; }\n"
    "kernel void csRead(texture2d_ms<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {\n"
    "  dst.write(src.read(gid, 0), gid); }\n"
    "fragment float4 fsOne(VOut in [[stage_in]], texture2d_ms<float> src [[texture(0)]]) {\n"
    "  return src.read(uint2(in.pos.xy), 0); }\n";

static MTLPixelFormat fmtFor(const char *s) {
  if (!strcmp(s, "rgba8")) return MTLPixelFormatRGBA8Unorm;
  if (!strcmp(s, "r32f")) return MTLPixelFormatR32Float;
  if (!strcmp(s, "rgba16f")) return MTLPixelFormatRGBA16Float;
  if (!strcmp(s, "r8")) return MTLPixelFormatR8Unorm;
  if (!strcmp(s, "bgra8")) return MTLPixelFormatBGRA8Unorm;
  if (!strcmp(s, "rgb10a2")) return MTLPixelFormatRGB10A2Unorm;
  fprintf(stderr, "bad fmt\n"); exit(2);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage\n"); return 2; }
    MTLPixelFormat fmt = fmtFor(argv[1]);
    NSString *store = [NSString stringWithUTF8String:argv[2]];
    NSString *read = [NSString stringWithUTF8String:argv[3]];
    int samples = argc > 4 ? atoi(argv[4]) : 4;
    int gpu = argc > 5 ? atoi(argv[5]) : 0;
    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    if (gpu >= (int)devs.count) { printf("SKIP: no GPU index %d (%d GPUs)\n", gpu, (int)devs.count); return 3; }
    id<MTLDevice> dev = devs[gpu];
    if (![dev supportsTextureSampleCount:samples]) { printf("SKIP: %d samples unsupported\n", samples); return 3; }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
    if (!lib) { printf("shader compile error: %s\n", err.description.UTF8String); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue];

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:32 height:32 mipmapped:NO];
    d.textureType = MTLTextureType2DMultisample; d.sampleCount = samples;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ms = [dev newTextureWithDescriptor:d];
    MTLTextureDescriptor *d1 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:32 height:32 mipmapped:NO];
    d1.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d1.storageMode = MTLStorageModePrivate;
    id<MTLTexture> resolved = [dev newTextureWithDescriptor:d1];
    d1.usage |= MTLTextureUsageShaderWrite; id<MTLTexture> out = [dev newTextureWithDescriptor:d1];

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fsRed"];
    pd.colorAttachments[0].pixelFormat = fmt; pd.rasterSampleCount = samples;
    id<MTLRenderPipelineState> p1 = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!p1) { printf("pso1 error: %s\n", err.description.UTF8String); return 2; }

    id<MTLRenderPipelineState> p2 = nil;
    if (![read isEqualToString:@"hw"] && ![read isEqualToString:@"hwload"] && ![read isEqualToString:@"compute"]) {
      MTLRenderPipelineDescriptor *pd2 = [MTLRenderPipelineDescriptor new];
      pd2.vertexFunction = [lib newFunctionWithName:@"vs"];
      pd2.fragmentFunction = [lib newFunctionWithName:[read isEqualToString:@"one"] ? @"fsOne" : @"fsLoop"];
      pd2.colorAttachments[0].pixelFormat = fmt;
      p2 = [dev newRenderPipelineStateWithDescriptor:pd2 error:&err];
      if (!p2) { printf("pso2 error: %s\n", err.description.UTF8String); return 2; }
    }

    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = ms;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
    if ([store isEqualToString:@"store"]) rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    else if ([store isEqualToString:@"resolve"]) { rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve; rp.colorAttachments[0].resolveTexture = resolved; }
    else { rp.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve; rp.colorAttachments[0].resolveTexture = resolved; }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:p1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [e endEncoding];

    if (p2) {
      MTLRenderPassDescriptor *rp2 = [MTLRenderPassDescriptor renderPassDescriptor];
      rp2.colorAttachments[0].texture = out;
      rp2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
      rp2.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> e2 = [cb renderCommandEncoderWithDescriptor:rp2];
      [e2 setRenderPipelineState:p2];
      [e2 setFragmentTexture:ms atIndex:0];
      [e2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
      [e2 endEncoding];
    }
    if ([read isEqualToString:@"hwload"]) {
      MTLRenderPassDescriptor *rp3 = [MTLRenderPassDescriptor renderPassDescriptor];
      rp3.colorAttachments[0].texture = ms;
      rp3.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rp3.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
      rp3.colorAttachments[0].resolveTexture = resolved;
      id<MTLRenderCommandEncoder> e3 = [cb renderCommandEncoderWithDescriptor:rp3];
      [e3 endEncoding];
    }
    if ([read isEqualToString:@"compute"]) {
      id<MTLComputePipelineState> cp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"csRead"] error:&err];
      if (!cp) { printf("cpso error: %s\n", err.description.UTF8String); return 2; }
      id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
      [ce setComputePipelineState:cp];
      [ce setTexture:ms atIndex:0]; [ce setTexture:out atIndex:1];
      [ce dispatchThreads:MTLSizeMake(32, 32, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [ce endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];
    printf("%s fmt=%s store=%s read=%s samples=%d gpu=%d(%s): status=%ld error=%s\n",
           cb.status == MTLCommandBufferStatusCompleted ? "OK  " : "FAIL",
           argv[1], argv[2], argv[3], samples, gpu, dev.name.UTF8String, (long)cb.status,
           cb.error ? cb.error.description.UTF8String : "none");
    return cb.status == MTLCommandBufferStatusCompleted ? 0 : 1;
  }
}
