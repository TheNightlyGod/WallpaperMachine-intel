import AppKit

/// The `environment.txt` lines that say what state the wallpaper windows are
/// in, so "the wallpaper does not appear" can be told apart from a window on
/// another Space, one the window server does not composite, or one outside its
/// display. Window titles are never read, so nothing here needs redaction
/// beyond what the whole file already gets.
enum DesktopWindowDiagnostics {
    @MainActor
    static func current() -> [String] {
        lines(DesktopWindowReader.current(), separateSpaces: NSScreen.screensHaveSeparateSpaces)
    }

    static func lines(_ windows: [DesktopWindowObservation], separateSpaces: Bool) -> [String] {
        let spaces = "displays have separate Spaces: \(yesNo(separateSpaces))"
        guard !windows.isEmpty else { return ["desktop windows: none open, \(spaces)"] }
        let count = "\(windows.count) wallpaper window\(windows.count == 1 ? "" : "s")"
        return ["desktop windows: \(count), \(spaces)"] + windows.map(line)
    }

    static func line(_ window: DesktopWindowObservation) -> String {
        let display = window.displayID.map(String.init) ?? "?"
        let server = window.server.map {
            "layer \($0.layer), alpha \(decimal($0.alpha)), on screen \(yesNo($0.isOnScreen)), bounds \(rect($0.bounds))"
        } ?? "absent"
        return "desktop window \(window.className) #\(window.windowNumber) display \(display): "
            + "frame \(rect(window.frame)), display frame \(window.displayFrame.map(rect) ?? "?"), "
            + "level \(window.level), collection behavior 0x\(String(window.collectionBehaviorRaw, radix: 16)), "
            + "alpha \(decimal(window.alpha)), ordered in \(yesNo(window.isOrderedIn)), "
            + "active Space \(yesNo(window.isOnActiveSpace)), occlusion visible \(yesNo(window.occlusionVisible)); "
            + "window server: \(server); state \(window.state.rawValue)"
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    /// `(x,y,width,height)`, whole numbers unless the frame is fractional.
    /// `CGRect.null` and `.infinite` hold values that cannot be printed as
    /// numbers; they read `?` rather than trapping.
    private static func rect(_ rect: CGRect) -> String {
        let parts = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { value -> String in
            guard value.isFinite, abs(value) < 1e9 else { return "?" }
            // `+ 0` turns a rounded -0.0 into 0.
            let text = String(format: "%.1f", (Double(value) * 10).rounded() / 10 + 0)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        return "(" + parts.joined(separator: ",") + ")"
    }

    /// At most two decimals, always at least one: `1.0`, `0.5`, `0.33`.
    private static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        let text = String(format: "%.2f", value)
        return text.hasSuffix("0") ? String(text.dropLast()) : text
    }
}
