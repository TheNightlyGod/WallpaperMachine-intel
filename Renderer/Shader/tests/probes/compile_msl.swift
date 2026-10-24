// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Compiles Metal Shading Language texts the way the host does: `makeLibrary(source:options:)`
// with default options, then looks the entry function up by name. Prints one line per input,
// `ok <file>` or `error <file>: <description>`. No window and no display are involved; nothing
// is drawn. Used by tests/metal_compile.rs (opt-in).
//
// usage: compile_msl <msl file>::<entry point> ...

import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice() else {
    print("no-device")
    exit(2)
}
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.components(separatedBy: "::")
    guard parts.count == 2 else {
        print("error \(arg): expected <file>::<entry>")
        continue
    }
    do {
        let source = try String(contentsOfFile: parts[0], encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        if library.makeFunction(name: parts[1]) == nil {
            print("error \(parts[0]): no function named \(parts[1])")
        } else {
            print("ok \(parts[0])")
        }
    } catch {
        let text = "\(error)".replacingOccurrences(of: "\n", with: " | ")
        print("error \(parts[0]): \(text)")
    }
}
