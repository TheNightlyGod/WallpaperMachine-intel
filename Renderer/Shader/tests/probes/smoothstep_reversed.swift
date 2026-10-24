// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// A Metal compute probe, run by tests/gpu_probe.rs when WM_SHADER_GPU_PROBES=1. It asks the
// backend what `smoothstep` returns for reversed edges (edge0 > edge1, undefined in the Metal
// specification) with edges the compiler cannot fold, with edges it can, and for a vector, and
// what `fmod` returns for a negative dividend (the remainder the dialect's `%` needs).
// Output: one line per sample, `sample x builtin_runtime_edges builtin_literal_edges builtin_vector fmod`.

import Foundation
import Metal

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void probe(device const float* xs [[buffer(0)]], device float* outs [[buffer(1)]],
                  device const float* edges [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    float x = xs[i];
    float e0 = edges[0];
    float e1 = edges[1];
    float2 v = metal::smoothstep(float2(e0), float2(e1), float2(x, x));
    outs[i * 4 + 0] = metal::smoothstep(e0, e1, x);
    outs[i * 4 + 1] = metal::smoothstep(0.9, 0.4, x);
    outs[i * 4 + 2] = v.y;
    outs[i * 4 + 3] = metal::fmod(x * 7.0 - 3.0, 2.0);
}
"""

guard let device = MTLCreateSystemDefaultDevice() else {
    print("no-device")
    exit(2)
}
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "probe")!)
let xs: [Float] = [0.2, 0.4, 0.5, 0.65, 0.8, 0.9, 1.0]
let edges: [Float] = [0.9, 0.4]
let xsBuffer = device.makeBuffer(bytes: xs, length: xs.count * 4)!
let edgeBuffer = device.makeBuffer(bytes: edges, length: edges.count * 4)!
let outBuffer = device.makeBuffer(length: xs.count * 4 * 4)!
let queue = device.makeCommandQueue()!
let commands = queue.makeCommandBuffer()!
let encoder = commands.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(xsBuffer, offset: 0, index: 0)
encoder.setBuffer(outBuffer, offset: 0, index: 1)
encoder.setBuffer(edgeBuffer, offset: 0, index: 2)
let grid = MTLSize(width: xs.count, height: 1, depth: 1)
encoder.dispatchThreads(grid, threadsPerThreadgroup: grid)
encoder.endEncoding()
commands.commit()
commands.waitUntilCompleted()
let out = outBuffer.contents().bindMemory(to: Float.self, capacity: xs.count * 4)
for (i, x) in xs.enumerated() {
    print("sample \(x) \(out[i * 4]) \(out[i * 4 + 1]) \(out[i * 4 + 2]) \(out[i * 4 + 3])")
}
