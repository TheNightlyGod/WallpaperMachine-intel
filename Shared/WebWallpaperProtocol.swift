import Foundation

/// Wallpaper Engine author protocol, shared by desktop and native saver web content.
enum WebWallpaperProtocol {
    /// Resolves a project-relative entry file to the path identity used for
    /// comparison, or nil when it leaves the project folder once symlinks are
    /// resolved. Comparing only the last path component instead makes a nested
    /// entry such as `sub/index.html` never equal to itself, which rebuilds the
    /// page on every reconcile.
    static func canonicalEntryURL(projectURL: URL, entryFile: String) -> URL? {
        // A manifest entry is always relative to its project. An absolute path
        // would otherwise be appended as a component and silently resolve to a
        // file inside the project that the author never named.
        guard !entryFile.isEmpty, !entryFile.hasPrefix("/") else { return nil }
        let root = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let entry = projectURL.appendingPathComponent(entryFile)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        guard entry.pathComponents.count > rootComponents.count,
              Array(entry.pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return entry
    }
    /// Name of the single page-to-host channel. Everything the page initiates —
    /// listener registration and random-file requests — arrives here as one
    /// tagged object, so there is exactly one place that has to distrust the page.
    static let messageHandlerName = "mweWallpaper"

    /// What a page's document-start script needs to know before any page script
    /// runs. The frame-rate limit has to be known by the page's very first
    /// `requestAnimationFrame` call and the render scale by its very first read
    /// of `devicePixelRatio`, so both are baked into the script of each document
    /// instead of being delivered once the document has loaded.
    struct Seed: Equatable {
        /// Wraps `requestAnimationFrame` so the limit can be enforced (desktop
        /// and preview pages). The screen saver keeps the native function.
        var framePacing = false
        /// Callbacks per second, or 0 for none; `frameLimit(forFPS:)` derives it.
        var frameLimit = 0
        /// Multiplies `window.devicePixelRatio`; see `clampedRenderScale`. At 1
        /// the page keeps WebKit's own property.
        var renderScale = 1.0
    }

    /// The range a web page's internal render scale is held to. The bridge
    /// allows 0.25 for a scene, but page text and interface drawn at a quarter
    /// of the pixel density are not a usable quality tier, so half is the floor.
    static let renderScaleRange: ClosedRange<Double> = 0.5...1

    /// `scale` held to `renderScaleRange`; a value that is not a number is no
    /// scale at all and means full resolution, because guessing low would leave
    /// a page blurry for good.
    static func clampedRenderScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return renderScaleRange.upperBound }
        return min(max(scale, renderScaleRange.lowerBound), renderScaleRange.upperBound)
    }

    /// The file-request fixes, and nothing else. They are the one part of the page
    /// host that every frame of a page gets, the main frame and the subframes it
    /// embeds, so this source reaches for no seed, no author API and no message
    /// handler: a subframe never sees `wallpaperPropertyListener` or the channel to
    /// the host. It is idempotent per document. `userScripts(seed:)` injects it.
    static let compatScript = """
    (() => {
      if (window.__mweFileCompat) return;
      Object.defineProperty(window, "__mweFileCompat", { value: true });
      // A document served over http(s) cannot read a project file, so there is
      // nothing for the fixes to do there, and a remote page a wallpaper embeds
      // keeps its own fetch and XMLHttpRequest exactly as the browser made them.
      if (location.protocol === "http:" || location.protocol === "https:") return;
      // WebKit resolves fetch() of a project file with status 0, ok === false and
      // no headers. Wallpaper Engine's Chromium host answers like a server: 200 OK
      // with a Content-Type from the extension. Loaders that check response.ok,
      // or stream into WebAssembly.instantiateStreaming (which demands
      // application/wasm), fail without it, so a found file:// GET/HEAD gets the
      // same status and type. The body stream is handed over, never buffered;
      // missing files and every other response are left exactly as WebKit made them.
      const nativeFetch = window.fetch;
      if (typeof nativeFetch === "function" && typeof Response === "function") {
        const FILE_TYPES = {
          html: "text/html", htm: "text/html", js: "text/javascript", mjs: "text/javascript",
          css: "text/css", json: "application/json", wasm: "application/wasm", txt: "text/plain",
          xml: "text/xml", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg",
          jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", avif: "image/avif",
          bmp: "image/bmp", ico: "image/x-icon", mp3: "audio/mpeg", wav: "audio/wav",
          ogg: "audio/ogg", oga: "audio/ogg", m4a: "audio/mp4", flac: "audio/flac",
          mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", ogv: "video/ogg",
          woff: "font/woff", woff2: "font/woff2", ttf: "font/ttf", otf: "font/otf",
        };
        const fileType = url => {
          const path = url.split(/[?#]/)[0];
          const dot = path.lastIndexOf(".");
          return dot > path.lastIndexOf("/") ? FILE_TYPES[path.slice(dot + 1).toLowerCase()] : undefined;
        };
        const served = new WeakSet();
        // A constructed Response forgets its URL; keep what the page would read.
        const asFetched = (response, url, redirected) => {
          served.add(response);
          return Object.defineProperties(response, {
            url: { value: url, enumerable: true },
            type: { value: "basic", enumerable: true },
            redirected: { value: redirected, enumerable: true },
            clone: { configurable: true, writable: true,
              value() { return asFetched(Response.prototype.clone.call(this), url, redirected); } },
          });
        };
        const asServed = response => {
          if (response.status !== 0 || response.type !== "basic" || !response.url.startsWith("file:")) return response;
          const headers = new Headers();
          const type = fileType(response.url);
          if (type) headers.set("Content-Type", type);
          return asFetched(new Response(response.body, { status: 200, statusText: "OK", headers }),
            response.url, response.redirected);
        };
        window.fetch = function fetch(input, init) {
          const pending = nativeFetch.apply(this, arguments);
          const method = String((init && init.method) || (input instanceof Request ? input.method : "GET")).toUpperCase();
          return method === "GET" || method === "HEAD" ? pending.then(asServed) : pending;
        };
        // Now that a project .wasm streams as application/wasm, the streaming
        // APIs would take WebKit's streaming compiler, which starts a large module
        // measurably later than compiling the same bytes from an ArrayBuffer (a
        // whole local file is already there to read). Only responses served above
        // take that path; anything else, including errors, stays native.
        const wasm = typeof WebAssembly === "object" ? WebAssembly : null;
        const wrapStreaming = (name, fromBytes) => {
          const native = wasm && wasm[name];
          if (typeof native !== "function") return;
          wasm[name] = async function (source, ...rest) {
            const response = await source;
            if (!served.has(response) || response.status !== 200 || response.bodyUsed
                || response.headers.get("Content-Type") !== "application/wasm") {
              return native.call(this, response, ...rest);
            }
            return fromBytes(await response.arrayBuffer(), ...rest);
          };
        };
        const compile = wasm && wasm.compile, instantiate = wasm && wasm.instantiate;
        wrapStreaming("compileStreaming", bytes => compile.call(wasm, bytes));
        wrapStreaming("instantiateStreaming", (bytes, imports) => instantiate.call(wasm, bytes, imports));
      }
      // Local XHR has the same status mismatch as fetch. WebKit exposes a
      // responseURL only once a response exists and clears it on failure/abort;
      // status 0 alone (or even a synchronous load event) is not proof of success.
      // Read native metadata so synchronous loaders and ready-state callbacks
      // both see 200 OK without buffering bodies or changing event delivery.
      if (typeof XMLHttpRequest === "function") {
        const prototype = XMLHttpRequest.prototype;
        const status = Object.getOwnPropertyDescriptor(prototype, "status");
        const statusText = Object.getOwnPropertyDescriptor(prototype, "statusText");
        const responseURL = Object.getOwnPropertyDescriptor(prototype, "responseURL").get;
        const isServedFile = xhr => status.get.call(xhr) === 0
          && responseURL.call(xhr).startsWith("file:");
        Object.defineProperties(prototype, {
          status: { ...status, get() { return isServedFile(this) ? 200 : status.get.call(this); } },
          statusText: { ...statusText, get() { return isServedFile(this) ? "OK" : statusText.get.call(this); } },
        });
      }
    })()
    """

    /// The host script of one document, for the main frame only: the author API,
    /// the message channel, the frame-rate limit and the render scale. Only
    /// numbers and booleans are interpolated into it.
    static func makeHostScript(seed: Seed) -> String {
        """
        \(hostScriptSource)({ framePacing: \(seed.framePacing), frameLimit: \(seed.frameLimit), \
        renderScale: \(clampedRenderScale(seed.renderScale)) })
        """
    }

    /// A function expression taking the seed; `makeHostScript` calls it.
    private static let hostScriptSource = """
    (seed => {
      if (window.__mweWallpaperHost) return;
      // Frame-rate limit. WebKit gives a page no frame-rate control, so a limit
      // below the ceiling is enforced on requestAnimationFrame itself: callbacks
      // are held back to the limit and run on the native frame that follows, with
      // that frame's timestamp. Only the main frame's requestAnimationFrame is
      // paced; timers, video frame callbacks, CSS, workers and subframes are not.
      // At the ceiling or above, or with no limit, the wrapper hands every call
      // straight to the native function. The wrappers are in place before any page
      // script runs, so a library that stores requestAnimationFrame at load holds
      // the paced one.
      const createFramePacer = \(framePacerSource);
      let pacer = null;
      if (seed.framePacing && typeof window.requestAnimationFrame === "function"
          && typeof window.cancelAnimationFrame === "function") {
        const nativeRequest = window.requestAnimationFrame.bind(window);
        const nativeCancel = window.cancelAnimationFrame.bind(window);
        pacer = createFramePacer(nativeRequest, nativeCancel, error => {
          try { window.reportError(error); } catch (unavailable) { setTimeout(() => { throw error; }, 0); }
        });
        pacer.setLimit(seed.frameLimit);
        const pacedRequest = function requestAnimationFrame(callback) {
          return typeof callback === "function" && pacer.isPacing()
            ? pacer.request(callback) : nativeRequest(...arguments);
        };
        // A handle is cancelled where it was issued: paced ids sit above every native one.
        const pacedCancel = function cancelAnimationFrame(handle) {
          const id = typeof handle === "number" || typeof handle === "string" ? Number(handle) : NaN;
          if (pacer.owns(id)) { pacer.cancel(id); return; }
          return nativeCancel(...arguments);
        };
        const replace = (names, wrapper) => {
          for (const name of names) if (typeof window[name] === "function") window[name] = wrapper;
        };
        replace(["requestAnimationFrame", "webkitRequestAnimationFrame"], pacedRequest);
        replace(["cancelAnimationFrame", "webkitCancelAnimationFrame", "webkitCancelRequestAnimationFrame"], pacedCancel);
      }
      // Internal render scale. A page sizes its canvases and WebGL buffers from
      // window.devicePixelRatio, so multiplying that number by the scale gives it
      // fewer pixels to draw, and WebKit stretches the result over the same area.
      // The scaled property is an accessor installed only while the scale is below
      // 1, and returning to 1 puts WebKit's own descriptor back unchanged. A live
      // change raises one resize event, which is what resize-aware pages listen for
      // to rebuild their buffers; the value the document starts with raises none.
      // Pages that read the ratio once keep full resolution until they reload,
      // media queries on resolution and subframes are not touched, and a page that
      // assigned the property itself keeps its own value. The getter and the event
      // use what is captured here, whatever the page does to its globals later.
      const nativeRatio = Object.getOwnPropertyDescriptor(window, "devicePixelRatio");
      const nativeDispatch = EventTarget.prototype.dispatchEvent;
      const NativeEvent = Event;
      let renderScale = 1;
      let scaledRatio = null;
      let resizePending = false;
      const setScale = value => {
        if (!nativeRatio || !nativeRatio.configurable || typeof nativeRatio.get !== "function") return false;
        const next = Number.isFinite(value) ? Math.min(1, Math.max(0.5, value)) : 1;
        if (next === renderScale) return false;
        renderScale = next;
        if (next < 1 && !scaledRatio) {
          scaledRatio = Object.getOwnPropertyDescriptor({
            get devicePixelRatio() { return nativeRatio.get.call(window) * renderScale; },
          }, "devicePixelRatio").get;
          Object.defineProperty(window, "devicePixelRatio", {
            configurable: true, enumerable: nativeRatio.enumerable, get: scaledRatio, set: nativeRatio.set,
          });
        } else if (next === 1 && scaledRatio) {
          const current = Object.getOwnPropertyDescriptor(window, "devicePixelRatio");
          if (current && current.get === scaledRatio) Object.defineProperty(window, "devicePixelRatio", nativeRatio);
          scaledRatio = null;
        }
        return true;
      };
      setScale(seed.renderScale);
      const post = message => {
        try { window.webkit.messageHandlers.\(WebWallpaperProtocol.messageHandlerName).postMessage(message); }
        catch (error) { console.error("wallpaper host channel unavailable", error); }
      };
      let listener = null;
      let lastPaused = null;
      // The pause state the page last took in.
      let pausedTakenIn = null;
      // What the host has told this document about each watched directory, so a
      // listener registered after the files arrived still sees them, and which of
      // those files the page has taken in.
      const directories = new Map();
      const filesTakenIn = new Map();
      // True only when the listener has the function and it returned without throwing.
      const call = (name, ...args) => {
        if (listener && typeof listener[name] === "function") {
          try { listener[name](...args); return true; } catch (error) { console.error("wallpaperPropertyListener." + name + " failed", error); }
        }
        return false;
      };
      // Wallpaper Engine runs applyUserProperties once at load with every
      // property and afterwards only with the properties whose values changed;
      // applyGeneralProperties follows the same rule. The host resends the whole
      // set on every apply (and the screen saver on every reconcile), so the
      // difference is computed here. `latest` is always the full set, for replay
      // to a listener that registers later; `delivered` is what the page last
      // accepted, through whichever listener it had then, as canonical strings so
      // that the key order of the host's JSON never reads as a change. A listener
      // that lacks the function, or throws, leaves `delivered` as it was, so the
      // next apply is measured against the last values the page really took in.
      const canonical = value => {
        if (value === null || typeof value !== "object") return String(JSON.stringify(value));
        if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
        return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
      };
      const propertySets = {
        applyUserProperties: { latest: null, delivered: null },
        applyGeneralProperties: { latest: null, delivered: null },
      };
      // `restaged` names properties the host restaged: the value reads the same but
      // the bytes behind it are new (a file reselected after it was edited, or
      // another folder's file of the same name), so they count as changed once.
      // The deliver functions return whether the page took something in.
      const deliverProperties = (name, properties, restaged) => {
        const set = propertySets[name];
        set.latest = properties;
        const again = new Set(Array.isArray(restaged) ? restaged : []);
        // A restaged property the page did not take in, for want of a handler or
        // because it threw, is still owed to it.
        const owe = () => {
          if (set.delivered) for (const key of again) set.delivered.delete(key);
          return false;
        };
        if (!listener || typeof listener[name] !== "function") return owe();
        const source = properties !== null && typeof properties === "object" ? properties : {};
        const snapshot = new Map(Object.keys(source).map(key => [key, canonical(source[key])]));
        let payload = properties;
        if (set.delivered) {
          const changed = Object.keys(source).filter(key => again.has(key) || set.delivered.get(key) !== snapshot.get(key));
          if (changed.length === 0) return false;
          payload = Object.fromEntries(changed.map(key => [key, source[key]]));
        }
        if (!call(name, payload)) return owe();
        set.delivered = snapshot;
        return true;
      };
      const deliverPaused = () => {
        if (!call("setPaused", lastPaused)) return false;
        pausedTakenIn = lastPaused;
        return true;
      };
      // A change the handler did not take in is owed again, even for a file it had.
      const deliverDirectoryFiles = (property, files) => {
        if (!filesTakenIn.has(property)) filesTakenIn.set(property, new Set());
        const takenIn = filesTakenIn.get(property);
        const accepted = call("userDirectoryFilesAddedOrChanged", property, files);
        for (const file of files) accepted ? takenIn.add(file) : takenIn.delete(file);
        return accepted;
      };
      // Wallpaper Engine calls whichever listener is there when it delivers, and
      // assigning one is not a delivery: a listener that replaces one which took
      // the values in hears nothing until a value changes. A page that assigns its
      // listener while it renders, as a React component body does, would otherwise
      // set state inside its own render on every pass, which loops until the
      // framework gives up and leaves the page blank. What the page has not taken
      // in (it had no listener or handler yet, or the handler threw) is replayed
      // once the turn that assigned the listener is over: strictly more forgiving
      // than Wallpaper Engine, so bundled pages that register asynchronously still
      // start.
      let replayQueued = false;
      let reassigned = false;
      const queueReplay = () => { replayQueued = true; queueMicrotask(replayOwed); };
      const replayOwed = () => {
        reassigned = false;
        let tookIn = false;
        try {
          for (const name of ["applyGeneralProperties", "applyUserProperties"]) {
            if (propertySets[name].latest && deliverProperties(name, propertySets[name].latest)) tookIn = true;
          }
          if (lastPaused !== null && lastPaused !== pausedTakenIn && deliverPaused()) tookIn = true;
          for (const [property, files] of directories) {
            const takenIn = filesTakenIn.get(property);
            const owed = files.filter(file => !(takenIn && takenIn.has(file)));
            if (owed.length && deliverDirectoryFiles(property, owed)) tookIn = true;
          }
        } finally {
          // Cleared only now: a listener assigned during the pass is noted, not queued.
          replayQueued = false;
        }
        // That listener may have a handler the one before it lacked. It gets another
        // pass, but only after a pass the page took something in from, so a handler
        // that throws and assigns a listener cannot loop.
        if (reassigned && tookIn) queueReplay();
      };
      Object.defineProperty(window, "wallpaperPropertyListener", {
        configurable: true,
        get() { return listener; },
        set(value) {
          listener = value;
          if (replayQueued) reassigned = true;
          else queueReplay();
        },
      });
      // Right clicks are forwarded to the page, never to WebKit's own context
      // menu: a wallpaper has no Reload or Inspect Element. Page handlers still run.
      window.addEventListener("contextmenu", event => event.preventDefault(), true);

      // Registration replaces, never accumulates: a page that re-registers, or
      // that is reloaded after a crash, must not end up receiving every frame
      // twice. The host is told only when the page crosses between having no
      // listener and having one, so capture opens and closes on real demand.
      let audioListener = null;
      window.wallpaperRegisterAudioListener = value => {
        const next = typeof value === "function" ? value : null;
        const had = audioListener !== null;
        audioListener = next;
        if ((next !== null) !== had) post({ type: next ? "audioSubscribed" : "audioUnsubscribed" });
      };

      const MEDIA_SLOTS = ["status", "properties", "thumbnail", "playback", "timeline"];
      const mediaListeners = {};
      const mediaValue = {};
      const mediaEncoded = {};
      const mediaCount = () => MEDIA_SLOTS.reduce((total, slot) => total + (mediaListeners[slot] ? 1 : 0), 0);
      const fireMedia = (slot, event) => {
        const target = mediaListeners[slot];
        if (!target) return;
        try { target(event); } catch (error) { console.error("wallpaper media listener " + slot + " failed", error); }
      };
      for (const slot of MEDIA_SLOTS) {
        mediaListeners[slot] = null;
        mediaValue[slot] = null;
        mediaEncoded[slot] = null;
        const name = "wallpaperRegisterMedia" + slot.charAt(0).toUpperCase() + slot.slice(1) + "Listener";
        window[name] = value => {
          const next = typeof value === "function" ? value : null;
          const before = mediaCount();
          mediaListeners[slot] = next;
          const after = mediaCount();
          if (before === 0 && after > 0) post({ type: "mediaSubscribed" });
          else if (before > 0 && after === 0) post({ type: "mediaUnsubscribed" });
          if (next && mediaValue[slot] !== null) fireMedia(slot, mediaValue[slot]);
        };
      }
      // The official documentation uses both spellings in its own examples.
      const PLAYING = 0, PAUSED = 1, STOPPED = 2;
      window.wallpaperMediaIntegration = Object.freeze({
        PLAYBACK_PLAYING: PLAYING, PLAYBACK_PAUSED: PAUSED, PLAYBACK_STOPPED: STOPPED,
        playback: Object.freeze({ PLAYING, PAUSED, STOPPED }),
      });

      let randomFileSequence = 0;
      const randomFileCallbacks = new Map();
      window.wallpaperRequestRandomFileForProperty = (property, callback) => {
        if (typeof property !== "string" || property === "" || typeof callback !== "function") return;
        const requestId = "r" + (++randomFileSequence);
        randomFileCallbacks.set(requestId, callback);
        post({ type: "randomFileRequest", requestId, propertyId: property });
      };

      window.__mweWallpaperHost = Object.freeze({
        applyUserProperties(properties, restaged) { deliverProperties("applyUserProperties", properties, restaged); },
        applyGeneralProperties(properties) { deliverProperties("applyGeneralProperties", properties); },
        // Takes effect on the next frame, and only where the seed asked for pacing.
        setFrameLimit(limit) { if (pacer) pacer.setLimit(limit); },
        // Changes made in one turn of the page share one resize event.
        setRenderScale(scale) {
          if (!setScale(scale) || resizePending) return;
          resizePending = true;
          queueMicrotask(() => { resizePending = false; nativeDispatch.call(window, new NativeEvent("resize")); });
        },
        setPaused(paused) { lastPaused = !!paused; deliverPaused(); },
        deliverAudio(bins) {
          if (!audioListener) return false;
          try { audioListener(bins); return true; } catch (error) { console.error("wallpaperRegisterAudioListener callback failed", error); return false; }
        },
        // Each media listener fires only when its own part changed. The host
        // already drops unchanged values, but a resume replay and a provider
        // re-emission can still race, so the last payload is compared here too.
        // Compared key by key in sorted order: the host builds these objects
        // from a dictionary, whose key order is not part of the contract.
        deliverMedia(slot, event) {
          if (!MEDIA_SLOTS.includes(slot)) return;
          const encoded = JSON.stringify(Object.keys(event).sort().map(key => [key, event[key]]));
          if (mediaEncoded[slot] === encoded) return;
          mediaEncoded[slot] = encoded;
          mediaValue[slot] = event;
          fireMedia(slot, event);
        },
        deliverRandomFile(requestId, property, filePath) {
          const callback = randomFileCallbacks.get(requestId);
          if (!callback) return;
          randomFileCallbacks.delete(requestId);
          try { callback(property, filePath); } catch (error) { console.error("wallpaperRequestRandomFileForProperty callback failed", error); }
        },
        userDirectoryFilesAddedOrChanged(property, files) {
          const known = directories.get(property) || [];
          directories.set(property, known.concat(files.filter(file => !known.includes(file))));
          deliverDirectoryFiles(property, files);
        },
        userDirectoryFilesRemoved(property, files) {
          const known = directories.get(property);
          if (known) directories.set(property, known.filter(file => !files.includes(file)));
          const takenIn = filesTakenIn.get(property);
          if (takenIn) for (const file of files) takenIn.delete(file);
          call("userDirectoryFilesRemoved", property, files);
        },
      });
    })
    """
}
