import Metal
import XCTest

@testable import WallpaperMachine

/// The Performance readout turns the kernel's cumulative coalition counters into mean
/// milliwatts. These cover the arithmetic, the coalitions it must leave out, the GPU
/// contention and native video flags, the averaging window, and that the private ABI
/// still reads sanely.
@MainActor
final class EnergyUsageMonitorTests: XCTestCase {
  private let second: UInt64 = 1_000_000_000

  private func sample(
    at seconds: UInt64, own: [UInt64: (cpu: UInt64, gpu: UInt64)], others: [UInt64: UInt64] = [:]
  ) -> EnergyUsageSample {
    EnergyUsageSample(
      uptimeNanoseconds: seconds * second,
      own: own.mapValues {
        CoalitionEnergyCounters(
          cpuEnergyNanojoules: $0.cpu, gpuEnergyNanojoules: $0.gpu, gpuTimeNanoseconds: 0)
      },
      otherGPUTime: others)
  }

  func testReadingSumsAppAndExtensionCoalitionsIntoMilliwatts() {
    let older = sample(at: 10, own: [1: (1_000, 5_000), 2: (0, 0)])
    // Over 2 s: app 280 mJ CPU and 1180 mJ GPU, extension 2 mJ CPU.
    let newer = sample(at: 12, own: [1: (280_001_000, 1_180_005_000), 2: (2_000_000, 0)])

    let reading = EnergyUsageReading.between(older, newer)

    XCTAssertEqual(reading.status, .ready)
    XCTAssertEqual(reading.cpuMilliwatts, 141, accuracy: 0.001)
    XCTAssertEqual(reading.gpuMilliwatts, 590, accuracy: 0.001)
    XCTAssertEqual(reading.seconds, 2, accuracy: 0.001)
  }

  func testCoalitionPresentInOnlyOneSampleIsNotCountedFromZero() {
    // An extension that launched inside the window arrives with its lifetime totals.
    let older = sample(at: 0, own: [1: (0, 0)])
    let newer = sample(at: 2, own: [1: (2_000_000, 0), 7: (9_000_000_000, 9_000_000_000)])

    let reading = EnergyUsageReading.between(older, newer)

    XCTAssertEqual(reading.cpuMilliwatts, 1, accuracy: 0.001)
    XCTAssertEqual(reading.gpuMilliwatts, 0)
  }

  func testGPUIsFlaggedOnlyWhenOtherCoalitionsKeepItBusyPastTheThreshold() {
    let older = sample(at: 0, own: [1: (0, 0)], others: [3: 0, 4: 0])
    let quiet = sample(at: 2, own: [1: (0, 0)], others: [3: 300_000_000, 4: 150_000_000])
    let busy = sample(at: 2, own: [1: (0, 0)], others: [3: 300_000_000, 4: 250_000_000])
    // A coalition that appeared inside the window has no delta, however large its total.
    let newcomer = sample(
      at: 2, own: [1: (0, 0)], others: [3: 300_000_000, 4: 150_000_000, 5: 60 * second])

    XCTAssertFalse(EnergyUsageReading.between(older, quiet).gpuContended, "22.5 % busy")
    XCTAssertTrue(EnergyUsageReading.between(older, busy).gpuContended, "27.5 % busy")
    XCTAssertFalse(EnergyUsageReading.between(older, newcomer).gpuContended)
  }

  func testReadingAveragesTheRetainedWindowAndReportsLostCounters() {
    let monitor = EnergyUsageMonitor(source: nil)
    var changes = 0
    monitor.onChange = { changes += 1 }

    monitor.record(sample(at: 0, own: [1: (0, 0)]))
    XCTAssertEqual(monitor.reading.status, .measuring, "one sample has no interval yet")

    // 100 mW, then a 400 mW spike, then 100 mW for three more intervals.
    let cpu: [UInt64] = [200_000_000, 1_000_000_000, 1_200_000_000, 1_400_000_000, 1_600_000_000]
    for (index, total) in cpu.enumerated() {
      monitor.record(sample(at: UInt64(index + 1) * 2, own: [1: (total, 0)]))
    }
    // Only the last four samples remain: 6 s from 1000 mJ to 1600 mJ, spike aged out.
    XCTAssertEqual(monitor.reading.cpuMilliwatts, 100, accuracy: 0.001)
    XCTAssertEqual(monitor.reading.seconds, 6, accuracy: 0.001)

    monitor.record(nil)
    XCTAssertEqual(monitor.reading.status, .unavailable)
    XCTAssertGreaterThan(changes, 0)
  }

  func testWithoutTheKernelInterfaceTheReadoutIsUnavailableAndNothingRuns() {
    let monitor = EnergyUsageMonitor(source: nil)
    monitor.setActive(true)
    XCTAssertEqual(monitor.reading.status, .unavailable)
    XCTAssertFalse(monitor.isActive)
  }

  func testReactivatingStartsAFreshMeasurement() {
    let monitor = EnergyUsageMonitor(source: FixedSource(), interval: .seconds(3600))
    monitor.record(sample(at: 0, own: [1: (0, 0)]))
    monitor.record(sample(at: 2, own: [1: (2_000_000, 0)]))
    XCTAssertEqual(monitor.reading.status, .ready)

    monitor.setActive(true)
    XCTAssertTrue(monitor.isActive)
    XCTAssertEqual(monitor.reading.status, .measuring, "old figures are not shown as current")
    monitor.setActive(false)
    XCTAssertFalse(monitor.isActive)
  }

  func testSettingChangeComparesSettledUncontendedWindowsBeforeAndAfter() {
    let monitor = EnergyUsageMonitor(source: FixedSource(), interval: .seconds(3600))
    monitor.setActive(true)
    defer { monitor.setActive(false) }
    var time: UInt64 = 0
    var energy: UInt64 = 0
    var otherBusy: UInt64 = 0
    // One 2 s step at `milliwatts`; `busy` is other coalitions' GPU time added in it.
    func step(_ milliwatts: UInt64, busy: UInt64 = 0) {
      time += 2
      energy += milliwatts * 2_000_000
      otherBusy += busy
      monitor.record(sample(at: time, own: [1: (energy, 0)], others: [9: otherBusy]))
    }
    monitor.record(sample(at: 0, own: [1: (0, 0)], others: [9: 0]))

    step(1_000)
    monitor.settingChanged()
    XCTAssertNil(monitor.comparison, "two samples are not a settled window to compare with")

    for _ in 0..<4 { step(1_000) }
    monitor.settingChanged()
    XCTAssertEqual(monitor.reading.status, .measuring, "the old figure is not the new setting's")
    XCTAssertEqual(monitor.comparison?.before.totalMilliwatts ?? 0, 1_000, accuracy: 0.001)
    XCTAssertNil(monitor.comparison?.after)

    step(600)
    step(600)
    monitor.settingChanged()
    XCTAssertEqual(
      monitor.comparison?.before.totalMilliwatts ?? 0, 1_000, accuracy: 0.001,
      "a second change before the first settled compares with the state before both")

    for _ in 0..<3 { step(250) }
    step(250, busy: 6 * second)
    XCTAssertNil(monitor.comparison?.after, "a full window beside a busy GPU is not the answer")
    for _ in 0..<2 { step(250) }
    XCTAssertNil(monitor.comparison?.after, "the busy interval is still inside the window")
    step(250)
    XCTAssertEqual(monitor.comparison?.after?.totalMilliwatts ?? 0, 250, accuracy: 0.001)

    monitor.setActive(false)
    XCTAssertNil(monitor.comparison, "a comparison does not outlive the readout")
  }

  func testSnapshotGradesOnlyUncontendedReadingsAndSharesThemOfTheBattery() {
    let monitor = EnergyUsageMonitor(
      source: FixedSource(), interval: .seconds(3600), batteryWattHours: { 50 })
    monitor.setActive(true)
    defer { monitor.setActive(false) }
    monitor.record(sample(at: 0, own: [1: (0, 0)], others: [9: 0]))
    // 500 mW CPU and 500 mW GPU over 2 s.
    monitor.record(
      sample(at: 2, own: [1: (1_000_000_000, 1_000_000_000)], others: [9: 0]))

    XCTAssertEqual(monitor.snapshot["level"] as? String, "medium")
    XCTAssertEqual(
      monitor.snapshot["batteryPercentPerHour"] as? Double ?? 0, 2, accuracy: 0.001,
      "1 W from a 50 Wh battery is 2 % an hour")

    monitor.record(
      sample(at: 4, own: [1: (2_000_000_000, 2_000_000_000)], others: [9: 4 * second]))
    XCTAssertTrue(monitor.reading.gpuContended)
    XCTAssertNil(monitor.snapshot["level"])
    XCTAssertNil(monitor.snapshot["batteryPercentPerHour"])
  }

  func testNativeVideoReadingsAreShownButNeitherGradedNorCompared() {
    let monitor = EnergyUsageMonitor(
      source: FixedSource(), interval: .seconds(3600), batteryWattHours: { 50 })
    monitor.setActive(true)
    defer { monitor.setActive(false) }
    var native = false
    monitor.nativeVideoPlaying = { native }
    var time: UInt64 = 0
    var energy: UInt64 = 0
    func step(_ milliwatts: UInt64) {
      time += 2
      energy += milliwatts * 2_000_000
      monitor.record(sample(at: time, own: [1: (energy, 0)]))
    }
    monitor.record(sample(at: 0, own: [1: (0, 0)]))
    for _ in 0..<3 { step(800) }
    monitor.settingChanged()
    XCTAssertEqual(monitor.comparison?.before.totalMilliwatts ?? 0, 800, accuracy: 0.001)

    // The change sent the video to macOS's player, whose work is charged elsewhere.
    native = true
    step(20)
    step(20)
    XCTAssertEqual(monitor.reading.totalMilliwatts, 20, accuracy: 0.001)
    XCTAssertTrue(monitor.reading.nativeVideo)
    XCTAssertNil(monitor.comparison, "a near-total saving that was never measured is not shown")
    XCTAssertEqual(monitor.snapshot["nativeVideo"] as? Bool, true)
    XCTAssertNil(monitor.snapshot["level"])
    XCTAssertNil(monitor.snapshot["batteryPercentPerHour"])

    native = false
    for _ in 0..<3 { step(800) }
    XCTAssertTrue(monitor.reading.nativeVideo, "the window still holds a native-video sample")
    step(800)
    XCTAssertFalse(monitor.reading.nativeVideo)
    XCTAssertEqual(monitor.snapshot["level"] as? String, "medium")
  }

  func testEnergyLevelBoundaries() {
    XCTAssertEqual(EnergyLevel(milliwatts: 499.9), .low)
    XCTAssertEqual(EnergyLevel(milliwatts: 500), .medium)
    XCTAssertEqual(EnergyLevel(milliwatts: 1_999.9), .medium)
    XCTAssertEqual(EnergyLevel(milliwatts: 2_000), .high)
  }

  func testBatteryCapacityFromRegistryProperties() throws {
    let pack: [String: Any] = [
      "BatteryInstalled": true, "AppleRawMaxCapacity": 8_532, "DesignCapacity": 8_579,
      "Voltage": 12_993, "BatteryData": ["CellVoltage": [4_331, 4_330, 4_331]],
    ]
    XCTAssertEqual(
      try XCTUnwrap(BatteryCapacity.wattHours(pack)), 8.532 * 3 * 3.85, accuracy: 0.001,
      "today's full charge across three nominal cells")

    // Without per-cell voltages the pack's present voltage gives the cell count, from
    // full charge down to near empty.
    var noCells = pack
    noCells["BatteryData"] = nil
    for millivolts in [12_993, 11_100, 9_700] {
      noCells["Voltage"] = millivolts
      XCTAssertEqual(
        try XCTUnwrap(BatteryCapacity.wattHours(noCells)), 8.532 * 3 * 3.85, accuracy: 0.001,
        "\(millivolts) mV")
    }

    // macOS 27 keeps the capacities only inside BatteryData and lists no cell voltages.
    let nested: [String: Any] = [
      "BatteryInstalled": true, "MaxCapacity": 100, "Voltage": 11_944,
      "BatteryData": [
        "FullChargeCapacity": 8_562, "DesignCapacity": 8_579, "NominalChargeCapacity": 8_806,
      ],
    ]
    XCTAssertEqual(
      try XCTUnwrap(BatteryCapacity.wattHours(nested)), 8.562 * 3 * 3.85, accuracy: 0.001,
      "today's full charge, not the rated or nominal one")
    var designOnly = nested
    designOnly["BatteryData"] = ["DesignCapacity": 8_579]
    XCTAssertEqual(
      try XCTUnwrap(BatteryCapacity.wattHours(designOnly)), 8.579 * 3 * 3.85, accuracy: 0.001)

    var removed = pack
    removed["BatteryInstalled"] = false
    XCTAssertNil(BatteryCapacity.wattHours(removed))
    XCTAssertNil(BatteryCapacity.wattHours(["BatteryInstalled": true, "Voltage": 12_000]))
  }

  /// A virtual machine (the CI runners) reports no energy at all: the guest's
  /// coalitions read 0 nJ however busy it is.
  private func skipInVirtualMachine() throws {
    var hypervisor: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let virtualised = sysctlbyname("kern.hv_vmm_present", &hypervisor, &size, nil, 0) == 0 && hypervisor == 1
    try XCTSkipIf(virtualised, "energy counters are not modelled in a virtual machine")
  }

  /// Guards the private struct layout: if a macOS update moved the fields, CPU energy
  /// would read as zero or as some unrelated counter.
  func testKernelCountersForThisProcessAdvanceWithCPUWork() throws {
    try skipInVirtualMachine()
    let source = try XCTUnwrap(
      CoalitionEnergySource(), "coalition accounting is expected on the deployment target")
    let before = try XCTUnwrap(source.sample())
    let end = Date().addingTimeInterval(0.5)
    var x = 0.0
    while Date() < end { for i in 0..<10_000 { x += sin(Double(i)) } }
    XCTAssertNotEqual(x, 42)
    let after = try XCTUnwrap(source.sample())

    let reading = EnergyUsageReading.between(before, after)
    XCTAssertEqual(reading.status, .ready)
    XCTAssertGreaterThan(reading.cpuMilliwatts, 10, "a busy core draws well above 10 mW")
    XCTAssertLessThan(reading.cpuMilliwatts, 200_000, "no Mac draws 200 W on the CPU")
    XCTAssertGreaterThanOrEqual(reading.gpuMilliwatts, 0)
    XCTAssertFalse(after.otherGPUTime.isEmpty, "other coalitions are listed")
  }

  /// The GPU half of the layout guard. macOS 27 appended five fields to the struct;
  /// one inserted before `gpu_energy_nj` would turn the GPU figure into another counter.
  func testKernelCountersForThisProcessAdvanceWithGPUWork() throws {
    try skipInVirtualMachine()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let library = try device.makeLibrary(
      source: """
        #include <metal_stdlib>
        kernel void spin(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
          float x = i;
          for (int j = 0; j < 2048; j++) x = metal::fma(x, 1.0001f, 0.37f);
          out[i] = x;
        }
        """, options: nil)
    let pipeline = try device.makeComputePipelineState(
      function: try XCTUnwrap(library.makeFunction(name: "spin")))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let buffer = try XCTUnwrap(device.makeBuffer(length: 4 << 20, options: .storageModePrivate))
    func dispatch(for seconds: TimeInterval) throws {
      let end = Date().addingTimeInterval(seconds)
      while Date() < end {
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(
          MTLSize(width: 1 << 20, height: 1, depth: 1),
          threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
      }
    }
    let source = try XCTUnwrap(CoalitionEnergySource())
    let before = try XCTUnwrap(source.sample())
    // The kernel posts GPU energy to coalitions every half second, and a test host
    // launched moments ago was seen to get its first posts late, so the GPU stays busy
    // until a post has arrived.
    var after = before
    let deadline = Date().addingTimeInterval(5)
    repeat {
      try dispatch(for: 0.5)
      after = try XCTUnwrap(source.sample())
    } while EnergyUsageReading.between(before, after).gpuMilliwatts == 0 && Date() < deadline

    let reading = EnergyUsageReading.between(before, after)
    XCTAssertGreaterThan(reading.gpuMilliwatts, 10, "a busy GPU draws well above 10 mW")
    XCTAssertLessThan(reading.gpuMilliwatts, 200_000, "no Mac draws 200 W on the GPU")
    let gpuTime = { (sample: EnergyUsageSample) in
      sample.own.values.reduce(0) { $0 + $1.gpuTimeNanoseconds }
    }
    XCTAssertGreaterThan(gpuTime(after), gpuTime(before), "GPU time advances with GPU work")
  }
}

private struct FixedSource: EnergyUsageSource {
  func sample() -> EnergyUsageSample? {
    EnergyUsageSample(uptimeNanoseconds: 0, own: [:], otherGPUTime: [:])
  }
}
