// Clean-room implementation from the WallpaperMachine spec e3-scripting.md; written without access to the original source.
//
// The script-side library of the SceneScript host, part 1: the environment every
// program shares (host values, timers, listeners, `shared`, `localStorage`,
// `console`, the WE modules). It is evaluated once per execution context as the
// first fragment of one function body; `ScriptLibraryScene.hpp` and
// `ScriptLibraryPrograms.hpp` follow in the same scope. The fragment that closes
// the function lives in the last of them.
#pragma once

namespace wallpaper::script_library
{

inline constexpr char kCore[] = R"JS(
(function (n) {
'use strict';
var G = globalThis;
var Vec2 = G.__WEVec2, Vec3 = G.__WEVec3, Vec4 = G.__WEVec4, Mat4 = G.__WEMat4, Mat3 = G.Mat3;
var hasOwn = Object.prototype.hasOwnProperty;

// ---- errors ---------------------------------------------------------------
function describe(e) {
  try {
    if (e !== null && typeof e === 'object' && e.message !== undefined) return String(e.message);
    return String(e);
  } catch (_) { return 'unprintable error'; }
}
function stackOf(e) {
  try { return e !== null && typeof e === 'object' && typeof e.stack === 'string' ? e.stack : ''; }
  catch (_) { return ''; }
}
function reportError(entry, e) { n.error(entry, describe(e), stackOf(e)); }

function finiteOr(value, fallback) { return typeof value === 'number' && isFinite(value) ? value : fallback; }

// ---- host values ----------------------------------------------------------
var language = 'en-us';
var canvasW = 0, canvasH = 0, resW = 0, resH = 0, curX = 0.5, curY = 0.5;
var sceneTime = 0;
var worldVec = new Vec3(0, 0, 0);

// The host's own fields of `engine` and `input`. They read and assign like plain
// properties, but each is a fixed accessor over a variable of this library: a script
// can neither turn one into code that runs inside the host's refresh nor freeze the
// object so that the refresh fails; the host writes through the returned setter.
function hostField(target, key, initial) {
  var current = initial;
  Object.defineProperty(target, key, {
    get: function () { return current; },
    set: function (value) { current = value; },
    enumerable: true, configurable: false
  });
  return function (value) { current = value; };
}

var engine = {
  AUDIO_RESOLUTION_16: 16,
  AUDIO_RESOLUTION_32: 32,
  AUDIO_RESOLUTION_64: 64,
  isRunningInEditor: function () { return false; },
  isScreensaver: function () { return false; },
  isWallpaper: function () { return !engine.isScreensaver(); },
  isDesktopDevice: function () { return true; },
  isMobileDevice: function () { return false; },
  isPortrait: function () { return resH > resW; },
  isLandscape: function () { return resW >= resH; },
  registerAsset: function (file) { return file === undefined ? '' : file; }
};
var putCanvasSize = hostField(engine, 'canvasSize', new Vec2(0, 0));
var putResolution = hostField(engine, 'screenResolution', new Vec2(0, 0));
var putFrametime = hostField(engine, 'frametime', 0);
var putRuntime = hostField(engine, 'runtime', 0);
var putUserProperties = hostField(engine, 'userProperties', {});
Object.defineProperty(engine, 'timeOfDay', {
  get: function () { return n.timeOfDay(); }, enumerable: true, configurable: true
});

var input = {};
var putCursor = hostField(input, 'cursorPosition', new Vec2(0.5, 0.5));
var putWorld = hostField(input, 'cursorWorldPosition', worldVec);
var putLocal = hostField(input, 'cursorLocalPosition', worldVec);
var putScreen = hostField(input, 'cursorScreenPosition', new Vec2(0, 0));
var putLeftDown = hostField(input, 'cursorLeftDown', false);
var putDown = hostField(input, 'mouseButtonsDown', 0);
var putPressed = hostField(input, 'mouseButtonsPressed', 0);
var putReleased = hostField(input, 'mouseButtonsReleased', 0);
var putInWindow = hostField(input, 'inWindow', false);
// Old scripts read the canvas size as a global of its own.
var putGlobalCanvas = hostField(G, 'canvasSize', engine.canvasSize);

// Called by the host with the groups of the context that changed since the last
// call (bit 0 canvas, 1 resolution, 2 times, 3 pointer, 4 world pointer, 5
// buttons, 6 in-window flag, 7 language).
function hostUpdate(m, cw, ch, rw, rh, ft, rt, cx, cy, wx, wy, wz, inw, down, pressed, released, lang) {
  if (m & 3) {
    if (m & 1) {
      canvasW = cw; canvasH = ch;
      var canvas = new Vec2(cw, ch);
      putCanvasSize(canvas);
      putGlobalCanvas(canvas);
    }
    var w = rw > 0 && isFinite(rw) ? rw : canvasW;
    var h = rh > 0 && isFinite(rh) ? rh : canvasH;
    resW = w; resH = h;
    putResolution(new Vec2(w, h));
  }
  if (m & 4) { sceneTime = rt; putFrametime(ft); putRuntime(rt); }
  if (m & 8) { curX = cx; curY = cy; putCursor(new Vec2(cx, cy)); }
  if (m & 11) putScreen(new Vec2(curX * resW, curY * resH));
  if (m & 16) {
    worldVec = new Vec3(wx, wy, wz);
    putWorld(worldVec);
    putLocal(worldVec);
  }
  if (m & 32) {
    putDown(down);
    putPressed(pressed);
    putReleased(released);
    putLeftDown((down & 1) !== 0);
  }
  if (m & 64) putInWindow(inw);
  if (m & 128) language = lang;
}

// ---- user properties ------------------------------------------------------
var lowerProps = null;
var userProps = {};
function setProps(obj) { userProps = obj; putUserProperties(obj); lowerProps = null; }
function propertyFallback(name) {
  if (lowerProps === null) {
    lowerProps = Object.create(null);
    var props = userProps;
    for (var key in props) lowerProps[key.toLowerCase()] = props[key];
  }
  return lowerProps[name.toLowerCase()];
}

// ---- event listeners ------------------------------------------------------
var listeners = Object.create(null);
function addListener(event, fn) {
  if (typeof event !== 'string' || typeof fn !== 'function') return;
  var list = listeners[event];
  if (list === undefined) listeners[event] = list = [];
  list.push(fn);
}
// A listener added while the list runs is first called by the next run; a
// throwing listener ends this run (the caller reports it once).
function runListeners(event, arg) {
  var list = listeners[event];
  if (list === undefined) return;
  var count = list.length;
  for (var i = 0; i < count; ++i) list[i](arg);
}
engine.on = addListener;

// ---- timers ---------------------------------------------------------------
var timers = [];
var cancelers = new WeakMap();
// The host leaves out the frame's call of a value program without `update` while no timer is
// due and no audio buffer is registered, since `evaluate` would only have run those. It is
// told the earliest due time of the live timers whenever that may have moved earlier, and
// after every pass that ran or dropped one; a timer cleared in between is still counted.
var toldDue = Infinity, toldAudio = false;
function tellHost() {
  var due = Infinity;
  for (var i = 0; i < timers.length; ++i) {
    var timer = timers[i];
    if (timer.dead) continue;
    var at = timer.due === timer.due ? timer.due : -Infinity;
    if (at < due) due = at;
  }
  var audio = audioBuffers.length > 0;
  if (due === toldDue && audio === toldAudio) return;
  toldDue = due;
  toldAudio = audio;
  n.waiting(due, audio);
}
function addTimer(fn, delay, repeat) {
  var ms = Number(delay);
  if (!(ms > 0)) ms = 0;
  var seconds = ms / 1000;
  var timer = { fn: fn, due: sceneTime + seconds, period: seconds, repeat: repeat && ms > 0, dead: false };
  timers.push(timer);
  if (!(timer.due >= toldDue)) tellHost();
  var cancel = function () { timer.dead = true; };
  cancelers.set(cancel, timer);
  return cancel;
}
function clearTimer(handle) {
  if (typeof handle !== 'function') return;
  var timer = cancelers.get(handle);
  if (timer !== undefined) timer.dead = true;
}
function runTimers() {
  var count = timers.length;
  if (count === 0) return;
  var now = sceneTime;
  var failed = false, failure;
  var anyDead = false, anyRan = false;
  for (var i = 0; i < count; ++i) {
    var timer = timers[i];
    if (timer.dead) { anyDead = true; continue; }
    if (timer.due > now) continue;
    anyRan = true;
    if (timer.repeat) {
      var next = timer.due + timer.period;
      timer.due = next <= now ? now + timer.period : next;
    } else {
      timer.dead = true;
      anyDead = true;
    }
    if (typeof timer.fn !== 'function') continue;
    try { timer.fn(); } catch (e) { if (!failed) { failed = true; failure = e; } }
  }
  if (anyDead || timers.length !== count) {
    var kept = [];
    for (var j = 0; j < timers.length; ++j) if (!timers[j].dead) kept.push(timers[j]);
    timers = kept;
  }
  if (anyRan || anyDead || timers.length !== count) tellHost();
  if (failed) reportError('timer pass', failure);
}
engine.setTimeout = function (fn, delay) { return addTimer(fn, delay, false); };
engine.setInterval = function (fn, delay) { return addTimer(fn, delay, true); };
engine.clearTimeout = clearTimer;
engine.clearInterval = clearTimer;
G.setTimeout = engine.setTimeout;
G.setInterval = engine.setInterval;
G.clearTimeout = clearTimer;
G.clearInterval = clearTimer;

// ---- shared, localStorage, console ----------------------------------------
var shared = {
  STARTS_WITH: 0,
  END_WITH: 1,
  userPropertyCategories: new Map(),
  offsetedStartAni: function (animation, percentage) {
    if (percentage === undefined) percentage = 1;
    animation.play();
    animation.setFrame(animation.frameCount * percentage);
  },
  delayedStartAni: function (animation, delay) {
    var started = false;
    var go = function () { if (!started) { started = true; animation.play(); } };
    var cancel = engine.setTimeout(go, delay);
    return function () { cancel(); go(); };
  }
};

// Wallpaper Engine's LocalStorageSet/Get (scenescript64.dll sub_181658680 / sub_181658A80): the key
// must be a string, the value is JSON.stringify'd without a replacer at the call and JSON.parse'd at
// each get (a fresh copy; a Vec3 comes back as a plain {x,y,z}), an undefined value deletes, and the
// location is global only for the word 'global'. The text lives in SceneScriptStorage, which also
// refuses a location over WE's 100,000 bytes (wallpaper64.exe sub_14018E3A0).
function storageLocation(l) { return l === 'global' ? 'global' : 'screen'; }
function storageKey(k) {
  if (typeof k !== 'string') throw new TypeError('LocalStorageSet key not a string.');
  return k;
}
var localStorage = {
  LOCATION_GLOBAL: 'global',
  LOCATION_SCREEN: 'screen',
  get: function (key, location) {
    var text = n.storage('get', storageLocation(location), storageKey(key));
    return text === undefined ? undefined : JSON.parse(text);
  },
  set: function (key, value, location) {
    var k = storageKey(key), loc = storageLocation(location);
    var text = value === undefined ? undefined : JSON.stringify(value);
    if (text === undefined) { n.storage('delete', loc, k); return value; }
    if (! n.storage('set', loc, k, text)) throw new Error('LocalStorageSet failed, possibly out of memory.');
    return value;
  },
  delete: function (key, location) { return !! n.storage('delete', storageLocation(location), storageKey(key)); },
  // Ours only (I9): an alias some scenes call.
  remove: function (key, location) { return !! n.storage('delete', storageLocation(location), storageKey(key)); },
  clear: function (location) {
    if (location === undefined) { n.storage('clear', 'global'); n.storage('clear', 'screen'); }
    else n.storage('clear', storageLocation(location));
  }
};

var noop = function () {};
var consoleShim = {
  log: noop, error: noop, warn: noop, info: noop, debug: noop, trace: noop, dir: noop,
  assert: noop, group: noop, groupCollapsed: noop, groupEnd: noop
};

// ---- WE modules -----------------------------------------------------------
var MediaPlaybackEvent = Object.freeze({ PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 });

function clamp(v, lo, hi) { return Math.min(Math.max(v, lo), hi); }
function smoothstep(e0, e1, v) {
  var t = clamp((v - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
}
var WEMath = {
  mix: function (a, b, v) { return a + (b - a) * v; },
  lerp: function (x, y, a) { return x * (1 - a) + y * a; },
  clamp: clamp,
  saturate: function (v) { return clamp(v, 0, 1); },
  step: function (edge, v) { return v < edge ? 0 : 1; },
  sign: function (v) { return Math.sign(v); },
  fract: function (v) { return v - Math.floor(v); },
  smoothstep: smoothstep,
  smoothStep: smoothstep,
  deg2rad: Math.PI / 180,
  rad2deg: 180 / Math.PI
};

function comp(v) { return typeof v === 'number' && isFinite(v) ? v : 0; }
var WEColor = {
  rgb2hsv: function (c) {
    var r = comp(c.x), g = comp(c.y), b = comp(c.z);
    var hi = Math.max(r, g, b), lo = Math.min(r, g, b), d = hi - lo;
    var h = 0;
    if (d !== 0) {
      if (hi === r) h = ((g - b) / d) % 6;
      else if (hi === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
      if (h < 0) h += 1;
    }
    return new Vec3(h, hi === 0 ? 0 : d / hi, hi);
  },
  hsv2rgb: function (c) {
    var h = comp(c.x) * 6, s = comp(c.y), v = comp(c.z);
    var sextant = Math.floor(h);
    if (sextant < 0) return new Vec3(0, 0, 0);
    var f = h - sextant;
    var p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    switch (sextant % 6) {
      case 0: return new Vec3(v, t, p);
      case 1: return new Vec3(q, v, p);
      case 2: return new Vec3(p, v, t);
      case 3: return new Vec3(p, q, v);
      case 4: return new Vec3(t, p, v);
      default: return new Vec3(v, p, q);
    }
  },
  normalizeColor: function (c) { return new Vec3(comp(c.x) / 255, comp(c.y) / 255, comp(c.z) / 255); },
  expandColor: function (c) { return new Vec3(comp(c.x) * 255, comp(c.y) * 255, comp(c.z) * 255); }
};
var WEVector = {
  angleVector2: function (degrees) {
    var a = comp(degrees) * Math.PI / 180;
    return new Vec2(Math.cos(a), Math.sin(a));
  },
  vectorAngle2: function (d) { return Math.atan2(comp(d.y), comp(d.x)) * 180 / Math.PI; }
};

var modules = { WEMath: WEMath, WEColor: WEColor, WEVector: WEVector, Vec2: Vec2, Vec3: Vec3, Vec4: Vec4,
                Mat3: Mat3, Mat4: Mat4, MediaPlaybackEvent: MediaPlaybackEvent };
function moduleNamespace(name) { return hasOwn.call(modules, name) ? modules[name] : undefined; }
function moduleNamed(name) {
  var m = moduleNamespace(name);
  if (m === undefined) throw new Error("Cannot find module '" + name + "'");
  return m;
}
)JS";

} // namespace wallpaper::script_library
