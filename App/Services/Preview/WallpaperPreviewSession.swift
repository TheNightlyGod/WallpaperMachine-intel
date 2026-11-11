import AppKit

@MainActor
protocol WallpaperPreviewSurface: AnyObject {
    var view: NSView { get }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() async throws
    func setPaused(_ paused: Bool) throws
    func setMuted(_ muted: Bool) throws
    /// Shows newer property values on the running preview without starting it again. `json`
    /// has the same shape as the request's `propertiesJSON`.
    func applyProperties(_ json: String) throws
    /// Shows newer Wallpaper Engine options on the running preview. A surface whose wallpaper has
    /// none, or that cannot show them in place, leaves itself as it is.
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws
    func stop()
}

/// Owns one isolated preview and fences late work when the user replaces or closes it.
@MainActor
final class WallpaperPreviewSession {
    enum Phase: Equatable { case closed, loading, playing, paused, failed(String) }
    struct Selection: Equatable, Sendable {
        let wallpaperID: String
        let displayID: String
        var textOverrides: [String: String] = [:]
    }
    typealias Load = @MainActor (Selection) async throws -> WallpaperPreviewRequest
    typealias Factory = @MainActor (WallpaperPreviewRequest, UInt64) throws -> any WallpaperPreviewSurface

    private let load: Load
    private let makeSurface: Factory
    private let sleep: @Sendable (Duration) async throws -> Void
    private let refreshes: PropertyPreviewScheduler
    private let warn: @MainActor (String) -> Void
    private(set) var phase: Phase = .closed
    private(set) var title = ""
    private(set) var selection: Selection?
    private(set) var muted = true
    private(set) var userPaused = false
    private(set) var visible = false
    private(set) var request: WallpaperPreviewRequest?
    private(set) var surface: (any WallpaperPreviewSurface)?
    /// The draft picks a picture or file other than the one the preview started with. A
    /// preview reads those only when it starts, so **Reload preview** shows them.
    private(set) var needsReload = false
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var ready = false
    /// The draft changed since the surface last took it in.
    private var propertiesStale = false
    /// What the surface shows, in the form `LivePropertyPayload` writes; nil until it is changed.
    private var shownProperties: String?
    /// The Wallpaper Engine options the surface shows; nil until they are changed.
    private var shownEngineOptions: WallpaperEngineOptions?
    /// The last problem logged for a refresh, so one that keeps recurring is logged once.
    private var lastRefreshProblem: String?
    var onChange: (() -> Void)?
    var onSurface: ((NSView?) -> Void)?

    private static let refreshKey = "properties"

    /// `refreshes` waits for a draft to settle before the preview follows it; `warn` receives
    /// what could not be shown, which never fails the preview.
    init(load: @escaping Load, makeSurface: @escaping Factory,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         refreshes: PropertyPreviewScheduler? = nil,
         warn: @escaping @MainActor (String) -> Void = { AppLog.warn($0) }) {
        self.load = load
        self.makeSurface = makeSurface
        self.sleep = sleep
        self.refreshes = refreshes ?? PropertyPreviewScheduler()
        self.warn = warn
    }

    func open(_ selection: Selection) {
        release()
        self.selection = selection
        title = ""
        muted = true
        userPaused = false
        phase = .loading
        onChange?()
        let ticket = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let input = try await load(selection)
                try Task.checkCancellation()
                guard ticket == generation else { return }
                request = input
                title = input.title
                operation = nil
                onChange?()
                if visible { startSurface(ticket: ticket) }
            } catch is CancellationError {
                if ticket == generation { fail(String(localized: "Preview loading was cancelled. Try again."), ticket: ticket) }
            } catch { fail(error.localizedDescription, ticket: ticket) }
        }
    }

    func reload() {
        guard var selection else { return }
        selection.textOverrides = [:]
        open(selection)
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible, surface == nil, request != nil, phase == .loading {
            startSurface(ticket: generation)
        } else {
            do { try surface?.setPaused(!visible || userPaused) }
            catch { fail(error.localizedDescription, ticket: generation) }
            updatePhase()
        }
        if !visible { deadline?.cancel(); deadline = nil }
        else if !ready, surface != nil, phase == .loading { armDeadline(ticket: generation) }
        if visible { refreshPropertiesIfNeeded() }
    }

    /// The property draft of `wallpaperID` changed. The preview follows it once the edits stop,
    /// when it is showing and ready; a hidden or still loading preview takes the newest draft
    /// once, when it can. Other wallpapers, a closed or failed preview, and a video (no property
    /// reaches its player) are left alone.
    ///
    /// `whileDragging` says a slider or colour is being dragged, whose steps arrive spaced
    /// already and never stop for the quiet period an edit waits out, so the preview follows the
    /// newest one as soon as it has taken the one before.
    func propertiesDidChange(wallpaperID: String, whileDragging: Bool = false) {
        guard let selection, selection.wallpaperID == wallpaperID else { return }
        switch phase {
        case .closed, .failed: return
        case .loading, .playing, .paused: break
        }
        if request?.kind == .video { return }
        propertiesStale = true
        refreshPropertiesIfNeeded(delay: whileDragging ? .zero : nil)
    }

    func togglePause() {
        guard ready else { return }
        userPaused.toggle()
        do { try surface?.setPaused(!visible || userPaused); updatePhase() }
        catch { fail(error.localizedDescription, ticket: generation) }
    }

    func toggleMute() {
        guard surface != nil else { return }
        muted.toggle()
        do { try surface?.setMuted(muted); onChange?() }
        catch { fail(error.localizedDescription, ticket: generation) }
    }

    func close() {
        release()
        selection = nil
        title = ""
        visible = false
        phase = .closed
        onChange?()
    }

    private func startSurface(ticket: UInt64) {
        guard surface == nil, let request, ticket == generation else { return }
        do {
            let created = try makeSurface(request, ticket)
            surface = created
            created.onReady = { [weak self] in self?.didBecomeReady(ticket: ticket) }
            created.onFailure = { [weak self] message in self?.fail(message, ticket: ticket) }
            try created.setMuted(muted)
            onSurface?(created.view)
            armDeadline(ticket: ticket)
            operation = Task { [weak self, weak created] in
                guard let self, let created else { return }
                do {
                    try await created.start()
                    guard ticket == generation else { return }
                    try created.setPaused(!visible || userPaused)
                    operation = nil
                } catch is CancellationError {
                    if ticket == generation { fail(String(localized: "Preview loading was cancelled. Try again."), ticket: ticket) }
                } catch { fail(error.localizedDescription, ticket: ticket) }
            }
        } catch { fail(error.localizedDescription, ticket: ticket) }
    }

    private func didBecomeReady(ticket: UInt64) {
        guard ticket == generation, surface != nil else { return }
        deadline?.cancel()
        deadline = nil
        ready = true
        updatePhase()
        refreshPropertiesIfNeeded()
    }

    private func refreshPropertiesIfNeeded(delay: Duration? = nil) {
        guard propertiesStale, ready, visible, surface != nil else { return }
        let ticket = generation
        refreshes.schedule(key: Self.refreshKey, delay: delay) { [weak self] in await self?.refreshProperties(ticket: ticket) }
    }

    /// Reads the draft again and shows what changed. Open-time text overrides are dropped: they
    /// describe what was typed when the preview opened, and a later edit must win over them.
    private func refreshProperties(ticket: UInt64) async {
        guard ticket == generation, propertiesStale, visible, ready, var latestSelection = selection else { return }
        propertiesStale = false
        latestSelection.textOverrides = [:]
        do {
            let latest = try await load(latestSelection)
            try Task.checkCancellation()
            guard ticket == generation, let surface, let started = request else { return }
            // Hidden meanwhile: the window does no work, and the next time it shows takes the draft.
            guard visible else { propertiesStale = true; return }
            let frozen = started.frozenPropertyIDs.union(latest.frozenPropertyIDs)
            guard let merged = LivePropertyPayload.merge(started: started.propertiesJSON, latest: latest.propertiesJSON,
                                                         frozen: frozen) else {
                reportRefreshProblem("the properties could not be read")
                return
            }
            if needsReload != merged.frozenChanged {
                needsReload = merged.frozenChanged
                onChange?()
            }
            let shown = shownProperties ?? LivePropertyPayload.canonical(started.propertiesJSON)
            if merged.json != shown {
                try surface.applyProperties(merged.json)
                shownProperties = merged.json
            }
            if let options = latest.engineOptions, options != (shownEngineOptions ?? started.engineOptions) {
                try surface.applyEngineOptions(options)
                shownEngineOptions = options
            }
            lastRefreshProblem = nil
        } catch is CancellationError {
            return
        } catch {
            guard ticket == generation else { return }
            // The preview keeps playing what it has; the next edit tries again.
            reportRefreshProblem(error.localizedDescription)
        }
    }

    private func reportRefreshProblem(_ message: String) {
        guard lastRefreshProblem != message else { return }
        lastRefreshProblem = message
        warn("wallpaper preview: property edits were not shown: \(message)")
    }

    private func updatePhase() {
        if ready { phase = userPaused || !visible ? .paused : .playing }
        onChange?()
    }

    private func armDeadline(ticket: UInt64) {
        deadline?.cancel()
        deadline = Task { [weak self, sleep] in
            do { try await sleep(.seconds(30)) } catch { return }
            guard let self, ticket == generation, visible, !ready else { return }
            fail(String(localized: "The preview did not become ready within 30 seconds. Try another wallpaper or reload the preview."), ticket: ticket)
        }
    }

    private func fail(_ message: String, ticket: UInt64) {
        guard ticket == generation else { return }
        let previous = request
        release()
        request = previous
        phase = .failed(message)
        onChange?()
    }

    private func release() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        deadline?.cancel()
        deadline = nil
        refreshes.cancel(Self.refreshKey)
        propertiesStale = false
        shownProperties = nil
        shownEngineOptions = nil
        lastRefreshProblem = nil
        needsReload = false
        surface?.onReady = nil
        surface?.onFailure = nil
        surface?.stop()
        surface = nil
        onSurface?(nil)
        request = nil
        ready = false
    }
}
