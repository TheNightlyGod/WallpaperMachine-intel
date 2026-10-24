// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Runs one Metal compute kernel with a single thread over a read-write float buffer and prints
// the buffer afterwards, one value per line. Used by tests/gpu_probe.rs (opt-in) to evaluate
// converted shaders on the GPU. No window and no display are involved.
//
// usage: run_kernel <msl file> <kernel name> <float count> [initial float values...]

import Foundation
import Metal

let args = CommandLine.arguments
guard args.count >= 4, let count = Int(args[3]) else {
    print("usage: run_kernel <msl file> <kernel name> <float count> [values...]")
    exit(64)
}
guard let device = MTLCreateSystemDefaultDevice() else {
    print("no-device")
    exit(2)
}
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
guard let function = library.makeFunction(name: args[2]) else {
    print("no-kernel")
    exit(65)
}
let pipeline = try device.makeComputePipelineState(function: function)
var values = [Float](repeating: 0, count: count)
for (i, text) in args.dropFirst(4).enumerated() where i < count {
    values[i] = Float(text) ?? 0
}
let buffer = device.makeBuffer(bytes: values, length: count * 4)!
let queue = device.makeCommandQueue()!
let commands = queue.makeCommandBuffer()!
let encoder = commands.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(buffer, offset: 0, index: 0)
encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
encoder.endEncoding()
commands.commit()
commands.waitUntilCompleted()
let out = buffer.contents().bindMemory(to: Float.self, capacity: count)
for i in 0..<count {
    print(out[i])
}
