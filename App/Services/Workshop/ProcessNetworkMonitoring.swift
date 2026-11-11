import Foundation

@MainActor
protocol ProcessNetworkMonitoring: AnyObject {
    func start(processID: Int32)
    func rate(at time: TimeInterval) -> Double?
    /// Bytes the process has received since monitoring began, or nil while no meter is running.
    func bytesReceived() -> Int64?
    func stop() async
}
