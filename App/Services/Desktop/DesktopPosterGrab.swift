import AppKit

/// One request for a still and the wait for its answer.
@MainActor
final class DesktopPosterGrab {
    private let center: NotificationCenter
    private let contextPrefix: String
    private let acceptsOtherRequests: Bool
    private var cancelled = false
    private var continuation: CheckedContinuation<DesktopPosterFrame?, Never>?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?

    init(center: NotificationCenter, contextPrefix: String = "switch-hold", acceptsOtherRequests: Bool = true) {
        self.center = center
        self.contextPrefix = contextPrefix
        self.acceptsOtherRequests = acceptsOtherRequests
    }

    /// Asks `layer`'s surface for a frame and waits for it, up to `timeout`. The first frame the
    /// layer reports can be taken whatever it was asked for: another request for the same layer (the
    /// poster sync's) yields an equally fresh one, and the sync ignores a frame that carries
    /// this request's context, so the still can never become the desktop poster. The listener
    /// is in place before the request goes out, because an answer may come back inside it.
    /// Replicas require their own context so a late answer from an older source revision is ignored.
    /// With `asks` false nothing is requested: the grab waits for the answer to a request someone
    /// else made, which a request of its own would take the place of.
    func run(on layer: CALayer, timeout: Duration, asks: Bool = true,
             sleep: @escaping @Sendable (Duration) async throws -> Void) async -> DesktopPosterFrame? {
        guard !cancelled else { return nil }
        let context = contextPrefix + ":" + UUID().uuidString
        return await withCheckedContinuation { (continuation: CheckedContinuation<DesktopPosterFrame?, Never>) in
            self.continuation = continuation
            observer = center.addObserver(
                forName: DesktopPosterNotification.ready, object: layer, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsOtherRequests
                            || DesktopPosterNotification.context(in: notification.userInfo) == context else { return }
                    if let frame = DesktopPosterFrame(userInfo: notification.userInfo) { self.finish(frame) }
                }
            }
            self.timeout = Task { [weak self] in
                do { try await sleep(timeout) } catch { return }
                self?.finish(nil)
            }
            guard asks else { return }
            center.post(name: DesktopPosterNotification.request, object: layer,
                        userInfo: [DesktopPosterNotification.Key.context: context])
        }
    }

    /// Ends the wait with no frame.
    func cancel() { cancelled = true; finish(nil) }

    private func finish(_ frame: DesktopPosterFrame?) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { center.removeObserver(observer) }
        observer = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: frame)
    }
}
