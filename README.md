# oclp-amd-gcn-metal-repro

Two small, self-contained Metal programs that reproduce driver failures on first-generation AMD GCN GPUs (FirePro
D300/D500/D700, Radeon HD 7000 series, R9 M370X, ...) running **macOS 13 or newer through OpenCore Legacy Patcher
(OCLP)**, where the Monterey-era `AMDMTLBronzeDriver` is reinstalled onto a newer macOS.

Context: [dortania/OpenCore-Legacy-Patcher#1145](https://github.com/dortania/OpenCore-Legacy-Patcher/issues/1145)
(Chrome 125+ and Electron apps freeze or show red/glitched windows on these GPUs).

They need no Chrome, Electron or ANGLE: just a Mac and a C compiler (Xcode or the Command Line Tools).

## What they test

| program | what it does | what a healthy GPU prints |
|---|---|---|
| `msaa_resolve.m` | Draws into a 32x32 multisampled texture, then gets a single-sample result in a second pass using one of several methods (hardware resolve, re-attach and resolve, compute kernel, or a **fragment shader that reads a `texture2d_ms`**). Waits for the command buffer and reports its status and error. | `OK` for every variant |
| `ubo_argbuf.m` | Only tries to **create a render pipeline** whose fragment function reads a uniform block either as a plain `constant` buffer (control) or through an **argument buffer holding a `constant` pointer** (the form ANGLE's Metal backend uses for GLSL uniform blocks). | `OK pipeline created` for both |

## Run it

```sh
sh run_matrix.sh
```

This builds both programs and runs them on every GPU in the Mac (about 1-2 minutes; a failing case can pause ~5 s
while the GPU times out). To run a single case by hand:

```sh
clang -fobjc-arc -framework Metal -framework Foundation msaa_resolve.m -o msaa_resolve
./msaa_resolve rgba8 store loop 4 0     # <format> <store action> <read method> [samples] [GPU index]
```

Formats: `rgba8 r32f rgba16f r8 bgra8 rgb10a2`. Store actions: `store resolve storeresolve`. Read methods: `loop` (fragment
shader averages all samples), `one` (fragment shader reads sample 0), `hw` (no second pass), `hwload` (second render
pass: load the MSAA texture, resolve on store), `compute` (compute kernel reads sample 0).

## Results so far

Measured on a Mac Pro (Late 2013, `MacPro6,1`) with two FirePro D300 (PCI `1002:6810`), macOS 13.7.8 (22H730), OCLP 2.4.1,
`AMDMTLBronzeDriver` 4.8.101. Both D300 GPUs behave identically. Comparison machine: MacBook Pro 16" 2019
(`MacBookPro16,1`), macOS 15.7.7, Apple's own drivers.

| variant (rgba8, 4 samples unless noted) | FirePro D300, macOS 13.7.8 + OCLP | Radeon Pro 5500M, macOS 15 | Intel UHD 630, macOS 15 |
|---|---|---|---|
| hardware resolve (`MultisampleResolve` store action) | OK | OK | OK |
| second pass: re-attach MSAA texture, resolve on store (`hwload`) | OK (also rgba16f, r8, rgb10a2) | OK | OK |
| second pass: compute kernel reads `texture2d_ms` | OK | OK | OK |
| second pass: **fragment shader reads sample 0** | **FAIL** | OK | OK |
| second pass: **fragment shader averages all samples** | **FAIL** | OK | OK |
| fragment read, 2 and 8 samples | **FAIL** | not run | not run |
| fragment read, `r32f` | **FAIL** | OK | OK |
| fragment read, `r8` / `rgba16f` | not yet run | OK (`rgba16f`) | OK (`rgba16f`) |
| uniform block as plain `constant` buffer: pipeline creation | OK | OK | OK |
| uniform block via argument buffer: pipeline creation | **FAIL** | OK | OK |

Failure signatures on the D300:

- `msaa_resolve`: `MTLCommandBufferErrorDomain Code=1 "Internal Error (00000001:Internal Error)"` (in a larger
  workload the same fault shows up as a GPU timeout, `kIOAccelCommandBufferCallbackErrorTimeout`).
- `ubo_argbuf`: `CompilerError Code=2 "Compiler encountered an internal error"` from `newRenderPipelineStateWithDescriptor`.

Reading: on this driver, a fragment shader that reads a multisample texture fails the command buffer, and a fragment
function with an argument buffer containing a `constant` pointer cannot be compiled into a pipeline. Everything else
tried (drawing into MSAA textures, hardware resolve, compute reads, plain constant buffers) works.

**Not established:** whether these failures are what freezes Chrome or Electron in #1145. ANGLE's Metal backend does
both things (it resolves multisampled framebuffers with a fragment shader read, and passes uniform blocks through
argument buffers), and its own test-suite fails on the D300 in exactly these places, so it is a strong candidate. It has
not yet been confirmed inside Chrome.

## Please run it and report

Especially owners of **FirePro D500/D700, Radeon HD 7000 series, R9 M370X, and any Polaris GPU (Radeon Pro 4xx/5xx)
using `AMDMTLBronzeDriver` on macOS 13+**. Only `1002:6810` has been confirmed so far; other GPUs are not assumed
affected. Reports from **supported** Macs with the same GPUs (running Apple's own driver) are just as useful.

Please paste:

1. the complete output of `sh run_matrix.sh`,
2. your OCLP version,
3. the version of `AMDMTLBronzeDriver.bundle` if you can find it (Finder > Get Info).

## Licence

MIT, see `LICENSE`.
