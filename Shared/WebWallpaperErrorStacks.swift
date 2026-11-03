import Foundation

/// V8's `Error.prototype.stack` format for the errors a page builds.
///
/// Wallpaper Engine runs a web wallpaper in Chromium, whose `stack` starts with a
/// `Name: message` line and gives each frame as `    at function (location)`, or as
/// `    at location` for top-level code and anonymous functions. WebKit writes
/// `function@location` lines and no header, so a page that reads its caller off a fixed
/// line of the stack, as a common logging helper does when it is built at start-up, got
/// `undefined` and threw before it set up its canvas, its property listener and its
/// animation loop: the wallpaper stayed the page's plain background.
///
/// The script this holds runs at document start in every frame, as Chromium writes every
/// frame's stacks that way. It replaces `Error` and its native subclasses with constructors
/// that build the browser's own error (same prototype, so `instanceof`, `constructor` and
/// `class … extends Error` behave as before), drop their own frame with
/// `Error.captureStackTrace`, and give the error a `stack` that is formatted from WebKit's
/// frames when it is first read, as V8 formats it lazily too; assigning `stack` replaces
/// it. `Error.stackTraceLimit` and `Error.captureStackTrace` keep working on the browser's
/// own constructor. Errors the engine raises itself (a `TypeError` from reading a property
/// of `undefined`) never pass through a constructor and keep WebKit's format.
///
/// Nothing runs per frame: the cost is one stack capture per error the page builds, and
/// the formatting when a stack is read.
enum WebWallpaperErrorStacks {
  static let script = """
    (() => {
      const NativeError = window.Error;
      if (typeof NativeError !== "function" || window.__mweErrorStacks) return;
      Object.defineProperty(window, "__mweErrorStacks", { value: true });
      const capture = NativeError.captureStackTrace;
      const errorToString = NativeError.prototype.toString;
      const describe = error => {
        try { return errorToString.call(error); } catch (failure) { return "Error"; }
      };
      // One WebKit frame, `function@location`, as V8 writes it.
      const frame = line => {
        const at = line.indexOf("@");
        let name = at < 0 ? "" : line.slice(0, at);
        let location = at < 0 ? line : line.slice(at + 1);
        if (name === "global code" || name === "module code") name = "";
        else if (name === "eval code") name = "eval";
        if (location === "" || location === "[native code]") location = "<anonymous>";
        return "    at " + (name ? name + " (" + location + ")" : location);
      };
      const format = (error, frames) =>
        [describe(error)].concat(frames.split("\\n").filter(line => line !== "").map(frame)).join("\\n");
      // Replaces the `stack` WebKit gave `error` with one formatted when first read.
      const adopt = error => {
        const own = Object.getOwnPropertyDescriptor(error, "stack");
        if (!own || typeof own.value !== "string") return;
        const frames = own.value;
        let formatted = null;
        Object.defineProperty(error, "stack", {
          configurable: true,
          enumerable: false,
          get() {
            if (formatted === null) formatted = format(error, frames);
            return formatted;
          },
          set(value) {
            Object.defineProperty(error, "stack", { value, writable: true, configurable: true, enumerable: false });
          },
        });
      };
      const wrap = (Native, Parent) => {
        const Wrapped = function () {
          const error = Reflect.construct(Native, arguments, new.target || Wrapped);
          if (typeof capture === "function") capture.call(NativeError, error, Wrapped);
          adopt(error);
          return error;
        };
        // `length`, `name` and the static functions (`isError`) as the browser has them.
        for (const key of Reflect.ownKeys(Native)) {
          if (key === "prototype" || key === "stackTraceLimit" || key === "captureStackTrace") continue;
          Object.defineProperty(Wrapped, key, Object.getOwnPropertyDescriptor(Native, key));
        }
        Object.defineProperty(Wrapped, "prototype", { value: Native.prototype, writable: false });
        Object.defineProperty(Native.prototype, "constructor", {
          value: Wrapped, writable: true, configurable: true, enumerable: false,
        });
        Object.setPrototypeOf(Wrapped, Parent || Object.getPrototypeOf(Native));
        return Wrapped;
      };
      const Error = wrap(NativeError, null);
      // WebKit reads the limit off its own constructor.
      Object.defineProperty(Error, "stackTraceLimit", {
        configurable: true,
        enumerable: false,
        get() { return NativeError.stackTraceLimit; },
        set(value) { NativeError.stackTraceLimit = value; },
      });
      if (typeof capture === "function") {
        Object.defineProperty(Error, "captureStackTrace", {
          configurable: true,
          enumerable: false,
          writable: true,
          value: function captureStackTrace(target, constructorOpt) {
            capture.call(
              NativeError, target, typeof constructorOpt === "function" ? constructorOpt : captureStackTrace);
            if (target !== null && typeof target === "object") adopt(target);
          },
        });
      }
      window.Error = Error;
      for (const name of [
        "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError", "AggregateError",
      ]) {
        if (typeof window[name] === "function") window[name] = wrap(window[name], Error);
      }
    })()
    """
}
