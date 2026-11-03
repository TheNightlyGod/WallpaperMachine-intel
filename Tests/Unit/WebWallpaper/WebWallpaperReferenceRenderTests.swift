import AppKit
import Darwin
import IOKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// Draws real web wallpapers the way the desktop host does, for
/// `scripts/we_reference.py render`, which compares them with Wallpaper Engine's own
/// frames. It is not a check: without `WALLPAPER_MACHINE_WEB_REFERENCE` (a job file the
/// script writes) it skips.
///
/// Each job is one project shown in a `WebWallpaperPage` at the screenshot's pixel size,
/// in a window that only reports visibility, so nothing reaches the desktop. The page is
/// given the project's properties and snapshotted at the screenshot's moment; the report
/// beside the pictures records what the page logged, its viewport, and the CPU time,
/// memory and animation frames it used over a fixed stretch, so a change that costs
/// performance shows up next to the picture it buys.
@MainActor
final class WebWallpaperReferenceRenderTests: XCTestCase {
  private struct Job: Decodable {
    struct Shot: Decodable {
      var at: Double
      var out: String
    }
    var name: String
    var project: String
    var entry: String
    var pixels: [Int]
    var properties: String
    var shots: [Shot]
    var report: String
    /// Seconds over which the performance figures are read, after the last shot.
    var measure: Double?
  }

  private struct Jobs: Decodable { var jobs: [Job] }

  /// Supplies WebKit's visibility input without ordering a desktop window.
  private final class VisibilityWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  /// Collects what the page reports as broken, as the desktop log would show it.
  private static let errorProbe = """
    (() => {
      const seen = window.__mweReferenceErrors = [];
      const keep = (kind, text) => { if (seen.length < 40) seen.push(kind + ": " + String(text).slice(0, 300)); };
      addEventListener("error", e => {
        if (e.target && e.target !== window && (e.target.src || e.target.href)) keep("resource", e.target.src || e.target.href);
        else keep("uncaught", (e.message || e) + (e.filename ? " @ " + e.filename.split("/").pop() + ":" + e.lineno : ""));
      }, true);
      addEventListener("unhandledrejection", e => keep("rejection", e.reason && (e.reason.stack || e.reason.message) || e.reason));
      const error = console.error.bind(console);
      console.error = (...args) => { keep("console", args.map(String).join(" ")); error(...args); };
    })();
    """

  func testRenderReferenceJobs() async throws {
    guard let path = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_WEB_REFERENCE"] else {
      throw XCTSkip("set WALLPAPER_MACHINE_WEB_REFERENCE to a job file (scripts/we_reference.py render)")
    }
    let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for job in jobs.jobs { try await render(job) }
  }

  private func render(_ job: Job) async throws {
    // The display the page would be on, which the window below takes its backing scale from.
    let backing = max(1, NSScreen.main?.backingScaleFactor ?? 2)
    let size = NSSize(width: CGFloat(job.pixels[0]) / backing, height: CGFloat(job.pixels[1]) / backing)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    let page = WebWallpaperPage(
      projectURL: URL(fileURLWithPath: job.project), entryFile: job.entry, persistentData: false)
    page.addUserScript(
      WKUserScript(source: Self.errorProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    page.attach(to: container)
    // Not deferred, so that it has the main display's backing scale as a desktop window has its
    // display's; it is never ordered in.
    let window = VisibilityWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    page.applyAudioOutput(volume: 0, muted: true)
    page.applyGeneralProperties(fps: 60)
    page.applyUserProperties(json: job.properties)
    let start = ContinuousClock.now
    page.load()

    var report: [String: Any] = ["name": job.name, "backing": backing]
    var shots: [[String: Any]] = []
    for shot in job.shots {
      let due = start + .milliseconds(Int(shot.at * 1000))
      if due > .now { try await Task.sleep(until: due, clock: .continuous) }
      let taken = try await snapshot(page.webView, pixels: job.pixels)
      try taken.write(to: URL(fileURLWithPath: shot.out))
      shots.append(["at": shot.at, "out": shot.out, "loaded": page.isLoaded])
    }
    report["shots"] = shots

    let state = try? await page.webView.evaluateJavaScript(
      """
      JSON.stringify({ innerWidth, innerHeight, devicePixelRatio, errors: window.__mweReferenceErrors || [] })
      """)
    if let text = state as? String, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    {
      report["page"] = object
    }
    report["performance"] = await measure(page, seconds: job.measure ?? 10)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: job.report))
  }

  /// A PNG of the whole view at exactly `pixels`, whatever the view's backing scale.
  private func snapshot(_ webView: WKWebView, pixels: [Int]) async throws -> Data {
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    let image = try await webView.takeSnapshot(configuration: configuration)
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels[0], pixelsHigh: pixels[1], bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    rep.size = NSSize(width: pixels[0], height: pixels[1])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: pixels[0], height: pixels[1]).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: pixels[0], height: pixels[1]))
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }

  /// CPU seconds per second of the page's WebContent process and of the WebKit GPU
  /// process this test host owns, the Mac's GPU utilization, the WebContent footprint
  /// (mean and peak of readings four times a second), and animation frames per second,
  /// over `seconds` of the running page.
  private func measure(_ page: WebWallpaperPage, seconds: Double) async -> [String: Any] {
    let content = (page.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    let gpu = Self.ownedProcesses(named: "com.apple.WebKit.GPU")
    _ = try? await page.webView.evaluateJavaScript(
      """
      window.__mweReferenceFrames = 0;
      (function tick() { window.__mweReferenceFrames++; requestAnimationFrame(tick); })();
      """)
    let before = (content: Self.cpuSeconds(content), gpu: gpu.map(Self.cpuSeconds).reduce(0, +))
    let started = ContinuousClock.now
    var utilization: [Double] = []
    var footprints: [Double] = []
    while ContinuousClock.now - started < .milliseconds(Int(seconds * 1000)) {
      try? await Task.sleep(for: .milliseconds(250))
      if let busy = Self.gpuUtilization() { utilization.append(busy) }
      if let bytes = ProcessFootprint.current(pid: content) { footprints.append(Double(bytes) / 1_048_576) }
    }
    let elapsed = Double((ContinuousClock.now - started).components.attoseconds) / 1e18
      + Double((ContinuousClock.now - started).components.seconds)
    let frames = (try? await page.webView.evaluateJavaScript("window.__mweReferenceFrames")) as? Double ?? 0
    let after = (content: Self.cpuSeconds(content), gpu: gpu.map(Self.cpuSeconds).reduce(0, +))
    return [
      "seconds": elapsed,
      "webcontent_cpu": (after.content - before.content) / elapsed,
      "gpu_process_cpu": (after.gpu - before.gpu) / elapsed,
      // A page's heap rises and falls with its garbage collection, so one reading says little.
      "webcontent_footprint_mb": footprints.isEmpty ? 0 : footprints.reduce(0, +) / Double(footprints.count),
      "webcontent_footprint_peak_mb": footprints.max() ?? 0,
      "raf_per_second": frames / elapsed,
      "gpu_utilization": utilization.isEmpty ? -1 : utilization.reduce(0, +) / Double(utilization.count) / 100,
    ]
  }

  /// The GPU's own "Device Utilization %", for the whole Mac: a page measured alone on a
  /// quiet Mac is most of it, and the same figure read right after a change compares.
  private static func gpuUtilization() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
      == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    var busiest: Double?
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard
        let statistics = IORegistryEntryCreateCFProperty(
          service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          as? [String: Any],
        let busy = statistics["Device Utilization %"] as? NSNumber
      else { continue }
      busiest = max(busiest ?? 0, busy.doubleValue)
    }
    return busiest
  }

  private static func cpuSeconds(_ pid: pid_t) -> Double {
    guard pid > 0 else { return 0 }
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return 0 }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = Double(usage.ri_user_time + usage.ri_system_time)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
  }

  /// Processes called `name` that this test host is responsible for (WebKit's XPC
  /// services are children of launchd, so the parent id does not say).
  private static func ownedProcesses(named name: String) -> [pid_t] {
    typealias Responsible = @convention(c) (pid_t) -> pid_t
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return [] }
    let responsible = unsafeBitCast(symbol, to: Responsible.self)
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let me = getpid()
    return pids.prefix(max(0, count)).filter { pid in
      guard pid > 0, responsible(pid) == me else { return false }
      var buffer = [CChar](repeating: 0, count: 256)
      proc_name(pid, &buffer, UInt32(buffer.count))
      return String(cString: buffer).hasPrefix(name)
    }
  }
}
