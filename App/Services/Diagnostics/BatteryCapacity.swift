import Foundation
import IOKit

/// Full-charge energy of the Mac's internal battery, so a power figure can be put as a
/// share of a charge. Read from the `AppleSmartBattery` registry entry, which needs no
/// privileges; a Mac without a battery has no such entry.
enum BatteryCapacity {
  /// Lithium-ion cells are rated at about 3.85 V: a MacBook Pro sold as 100 Wh reports
  /// 8,579 mAh across three cells, which gives 99 Wh.
  static let nominalCellVolts = 3.85

  static func fullChargeWattHours() -> Double? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        == KERN_SUCCESS,
      let properties = unmanaged?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return wattHours(properties)
  }

  /// Today's full charge in mAh is `AppleRawMaxCapacity`, or `FullChargeCapacity` inside
  /// `BatteryData` on macOS 27, which keeps the capacities only there; the rated
  /// `DesignCapacity` from either place stands in when neither is present. Cell count
  /// comes from the per-cell voltages, which macOS 27 no longer lists; failing that, from
  /// the pack's present voltage: a cell stays between about 3.2 and 4.4 V while the Mac
  /// runs, so the nearest whole number of nominal cells is the count.
  static func wattHours(_ properties: [String: Any]) -> Double? {
    let data = properties["BatteryData"] as? [String: Any] ?? [:]
    guard properties["BatteryInstalled"] as? Bool != false,
      let milliampHours =
        (properties["AppleRawMaxCapacity"] ?? data["FullChargeCapacity"]
        ?? properties["DesignCapacity"] ?? data["DesignCapacity"]) as? Int,
      milliampHours > 0
    else { return nil }
    let cells: Int
    if let count = (data["CellVoltage"] as? [Int])?.count, count > 0 {
      cells = count
    } else if let millivolts = properties["Voltage"] as? Int {
      cells = Int((Double(millivolts) / 1000 / nominalCellVolts).rounded())
    } else {
      return nil
    }
    guard cells > 0 else { return nil }
    return Double(milliampHours) * Double(cells) * nominalCellVolts / 1000
  }
}
