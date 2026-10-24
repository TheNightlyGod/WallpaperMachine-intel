// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Builds a render pipeline state from the Metal text of a vertex stage and of a fragment stage, the
// step that fails when the stage interface is beyond the hardware's inter-stage budget (amendment
// d R66). Nothing is drawn: no window, no display, no command queue. Used by tests/metal_compile.rs
// (opt-in).
//
// usage: render_pipeline <vertex.metal>::<vertex entry> <fragment.metal>::<fragment entry> [<attribute-format> ...]
// where attribute i is described by the ith format: float, float2, float3 or float4.
// Prints `ok` or `error: <description>`.

import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice() else {
    print("no-device")
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("error: expected a vertex and a fragment stage")
    exit(1)
}

func function(_ arg: String) throws -> MTLFunction {
    let parts = arg.components(separatedBy: "::")
    let source = try String(contentsOfFile: parts[0], encoding: .utf8)
    let library = try device.makeLibrary(source: source, options: nil)
    guard let f = library.makeFunction(name: parts[1]) else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no function named \(parts[1])"])
    }
    return f
}

do {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = try function(args[0])
    descriptor.fragmentFunction = try function(args[1])
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let vertexDescriptor = MTLVertexDescriptor()
    let formats: [String: (MTLVertexFormat, Int)] = [
        "float": (.float, 4), "float2": (.float2, 8), "float3": (.float3, 12), "float4": (.float4, 16),
    ]
    for (i, name) in args.dropFirst(2).enumerated() {
        guard let (format, stride) = formats[name] else {
            print("error: unknown attribute format \(name)")
            exit(1)
        }
        vertexDescriptor.attributes[i].format = format
        vertexDescriptor.attributes[i].offset = 0
        vertexDescriptor.attributes[i].bufferIndex = 10 + i
        vertexDescriptor.layouts[10 + i].stride = stride
    }
    if args.count > 2 { descriptor.vertexDescriptor = vertexDescriptor }
    _ = try device.makeRenderPipelineState(descriptor: descriptor)
    print("ok")
} catch {
    print("error: " + "\(error)".replacingOccurrences(of: "\n", with: " | "))
}
