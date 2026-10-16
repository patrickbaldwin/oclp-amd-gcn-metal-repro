// SPDX-License-Identifier: MIT
// Standalone Metal check (no ANGLE): can the GPU's shader compiler build a render pipeline whose fragment
// function reads a uniform block through an argument buffer (the way ANGLE's Metal backend passes UBOs)?
// Build: clang -fobjc-arc -framework Metal -framework Foundation ubo_argbuf.m -o ubo_argbuf
// Usage: ubo_argbuf <variant> [gpu=0]
//   plain   : fragment reads `constant float4 &color [[buffer(1)]]`                          (control)
//   argbuf  : `struct AB { constant UBO *p [[id(0)]]; }; constant AB &ab [[buffer(1)]]`      (ANGLE shape)
//   argbufc : like argbuf, plus function constants and a sample-mask output like ANGLE's generated code
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *srcFor(NSString *v) {
  NSString *head = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VOut { float4 pos [[position]]; };\n"
    "vertex VOut vs(uint vid [[vertex_id]]) { float2 p[3] = {{-1,-1},{3,-1},{-1,3}}; VOut o; o.pos = float4(p[vid],0,1); return o; }\n";
  if ([v isEqualToString:@"plain"])
    return [head stringByAppendingString:@"fragment float4 fs(VOut in [[stage_in]], constant float4 &color [[buffer(1)]]) { return color; }\n"];
  if ([v isEqualToString:@"argbuf"])
    return [head stringByAppendingString:
      @"struct UBO { float4 color; };\n"
       "struct AB { constant UBO *p [[id(0)]]; };\n"
       "fragment float4 fs(VOut in [[stage_in]], constant AB &ab [[buffer(1)]]) { return ab.p->color; }\n"];
  return [head stringByAppendingString:
    @"constant bool ANGLEMultisampledRendering [[function_constant(2)]];\n"
     "constant bool ANGLESampleMaskWriteEnabled = ANGLEMultisampledRendering;\n"
     "struct UBO { float4 color; };\n"
     "struct AB { constant UBO *p [[id(0)]]; };\n"
     "struct FOut { float4 c [[color(0)]]; uint32_t m [[sample_mask, function_constant(ANGLESampleMaskWriteEnabled)]]; };\n"
     "fragment FOut fs(VOut in [[stage_in]], constant AB &ab [[buffer(1)]]) { FOut o; o.c = ab.p->color; if (ANGLESampleMaskWriteEnabled) o.m = 0xFFFFFFFF; return o; }\n"];
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: ubo_argbuf plain|argbuf|argbufc [gpu]\n"); return 2; }
    NSString *variant = [NSString stringWithUTF8String:argv[1]];
    int gpu = argc > 2 ? atoi(argv[2]) : 0;
    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    if (gpu >= (int)devs.count) { printf("SKIP: no GPU index %d\n", gpu); return 3; }
    id<MTLDevice> dev = devs[gpu];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:srcFor(variant) options:nil error:&err];
    if (!lib) { printf("FAIL(library) %s: %s\n", variant.UTF8String, err.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
    bool ms = false; [fcv setConstantValue:&ms type:MTLDataTypeBool atIndex:2];
    id<MTLFunction> fs = [variant isEqualToString:@"argbufc"] ? [lib newFunctionWithName:@"fs" constantValues:fcv error:&err] : [lib newFunctionWithName:@"fs"];
    if (!fs) { printf("FAIL(function) %s: %s\n", variant.UTF8String, err.description.UTF8String); return 1; }
    pd.fragmentFunction = fs;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    printf("%s variant=%s gpu=%d(%s): %s\n", ps ? "OK  " : "FAIL", variant.UTF8String, gpu, dev.name.UTF8String,
           ps ? "pipeline created" : err.description.UTF8String);
    return ps ? 0 : 1;
  }
}
