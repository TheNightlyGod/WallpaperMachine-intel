// Clean-room implementation from the WallpaperMachine spec e3-scripting.md; written without access to the original source.
//
// The script-side library of the SceneScript host, part 3: program records, the
// `createScriptProperties` builder, the event entry points the native side calls
// (every handler call is guarded here so one failing call is one recorded
// error), the globals scripts see, and the closing of the library function.
#pragma once

namespace wallpaper::script_library
{

inline constexpr char kPrograms[] = R"JS(

// ---- script parameters ----------------------------------------------------
function toColor(x) {
  if (x instanceof Vec3) return x;
  if (Array.isArray(x)) return new Vec3(num(x[0]), num(x[1]), num(x[2]));
  if (typeof x === 'string') { var p = parseNumbers(x); return new Vec3(num(p[0]), num(p[1]), num(p[2])); }
  if (x !== null && typeof x === 'object') return new Vec3(num(x.x), num(x.y), num(x.z));
  return new Vec3(num(x), num(x), num(x));
}
function makeBuilder(sp) {
  var builder;
  function plain(options) {
    if (options !== null && typeof options === 'object' && options.name !== undefined && !hasOwn.call(sp, options.name)) {
      sp[options.name] = options.value;
    }
    return builder;
  }
  var known = {
    addSlider: plain,
    addCheckbox: plain,
    addText: plain,
    addCombo: function (options) {
      if (options !== null && typeof options === 'object' && options.name !== undefined && !hasOwn.call(sp, options.name)) {
        var value = options.value;
        if (value === undefined && Array.isArray(options.options) && options.options.length > 0) {
          value = options.options[0] !== null && typeof options.options[0] === 'object' ? options.options[0].value : undefined;
        }
        sp[options.name] = value;
      }
      return builder;
    },
    addColor: function (options) {
      if (options !== null && typeof options === 'object' && options.name !== undefined && !hasOwn.call(sp, options.name)) {
        var current = toColor(options.value);
        Object.defineProperty(sp, options.name, {
          get: function () { return current; },
          set: function (x) { current = toColor(x); },
          enumerable: true, configurable: true
        });
      }
      return builder;
    },
    finish: function () { return sp; }
  };
  builder = new Proxy(known, {
    get: function (target, prop) {
      if (typeof prop === 'string' && !(prop in target) && prop.indexOf('add') === 0) return plain;
      return target[prop];
    }
  });
  return builder;
}

// ---- programs -------------------------------------------------------------
var CURSOR = ['cursorClick', 'cursorDown', 'cursorEnter', 'cursorLeave', 'cursorMove', 'cursorUp'];
var HANDLERS = ['init', 'update', 'applyUserProperties', 'applyGeneralSettings', 'resizeScreen',
                'cursorClick', 'cursorDown', 'cursorEnter', 'cursorLeave', 'cursorMove', 'cursorUp',
                'mediaPlaybackChanged', 'mediaPropertiesChanged', 'mediaStatusChanged',
                'mediaTimelineChanged', 'mediaThumbnailChanged', 'animationEvent', 'destroy'];
var MEDIA = { mediaPlaybackChanged: 1, mediaPropertiesChanged: 1, mediaStatusChanged: 1,
              mediaTimelineChanged: 1, mediaThumbnailChanged: 1 };
var MEDIA_COLORS = ['primaryColor', 'secondaryColor', 'tertiaryColor', 'textColor', 'highContrastColor'];

// Runs the factory the native side compiled: the script's top level executes here
// and its handlers come back as plain functions of that scope.
function make(factory, kind, layerName, animIndex, effectRef, animRef) {
  var sp = {};
  var builder = makeBuilder(sp);
  var layerKey = layerName ? n.resolve(layerName) : '';
  var layer = layerName ? getLayer(layerName) : undefined;
  var object = layer;
  if (layer !== undefined) {
    if (animIndex >= 0) object = animationLayerOf(layerKey, animIndex);
    else if (effectRef) object = effectObjectOf(layer, effectRef);
    else if (animRef) object = settingObjectOf(layer, animRef);
  }
  var hooks = {};
  var scene = Object.create(sceneProxy);
  Object.defineProperty(scene, 'createLayer', {
    value: function (cfg) {
      var id;
      try { id = hooks.wid === undefined ? undefined : hooks.wid(); } catch (_) { id = undefined; }
      return createLayer(cfg, layerKey, id);
    },
    writable: true, configurable: true, enumerable: false
  });
  var prog = { kind: kind, layerName: layerName, h: null, sp: sp, started: false, caps: 0 };
  try {
    prog.h = factory(layer, object, scene, function createScriptProperties() { return builder; }, sp,
                     moduleNamespace, moduleNamed, hooks);
  } catch (e) {
    // What a script threw is described here, inside the budgeted call, rather than by
    // the host reading properties off an object the script made.
    var failure = new Error(describe(e));
    failure.stack = stackOf(e);
    throw failure;
  }
  var h = prog.h;
  var caps = typeof h.update === 'function' ? 1 : 0;
  for (var i = 0; i < 6; ++i) if (typeof h[CURSOR[i]] === 'function') caps |= 2 << i;
  if (typeof h.animationEvent === 'function') caps |= 128;
  prog.caps = caps;
  return prog;
}

function guard(entry, prog, arg) {
  var f = prog.h[entry];
  if (typeof f !== 'function') return;
  try { f(arg); } catch (e) { reportError(entry, e); }
}

function noticeLanguage(prog) { guard('applyGeneralSettings', prog, { language: language }); }

function startNotices(prog) {
  noticeLanguage(prog);
  guard('applyUserProperties', prog, Object.assign({}, userProps));
}

// What a handler may keep or change without touching what the next handler gets
// (R14: every call receives its own copy of the property's value).
function ownCopy(value) {
  return value instanceof Vec2 || value instanceof Vec3 || value instanceof Vec4 ? value.copy() : value;
}

// The first step of a value program's start: its `init`, given the value the property holds.
// Answers what `init` returned; `undefined` is "no value".
function runInit(prog, value) {
  refreshAudio();
  prog.started = true;
  var init = prog.h.init;
  if (typeof init !== 'function') return undefined;
  try { return init(ownCopy(value)); } catch (e) { reportError('init', e); return undefined; }
}

// The second step: the language and the user properties, told once every program has had its `init`.
function userNotices(prog, hasRuntime) {
  noticeLanguage(prog);
  if (hasRuntime) guard('applyUserProperties', prog, Object.assign({}, userProps));
}

// One evaluation of a value program (the host has refreshed `engine` already).
// Answers what `update` returned; `undefined` is "no value".
function evaluate(prog, value, hasRuntime) {
  refreshAudio();
  runTimers();
  var update = prog.h.update;
  if (typeof update !== 'function') return undefined;
  try { return update(ownCopy(value)); } catch (e) { reportError('update', e); return undefined; }
}

function startScene(prog) {
  prog.started = true;
  guard('init', prog, undefined);
  startNotices(prog);
  try { runListeners('load', undefined); } catch (e) { reportError('load', e); }
}

function tickScene(prog) {
  refreshAudio();
  runTimers();
  guard('update', prog, undefined);
  try { runListeners('update', undefined); } catch (e) { reportError('update', e); }
}

function cursorEvent(prog, index, button) {
  var name = CURSOR[index];
  // Each program gets its own vectors: one that edits `event.worldPosition` must not
  // change what `input` or the next program's event holds.
  var world = worldVec.copy();
  var event = {
    button: button,
    normalizedPosition: new Vec2(curX, curY),
    worldPosition: world,
    position: world
  };
  shortcutBudget = 1;
  try {
    guard(name, prog, event);
    if (prog.kind === 1) {
      try { runListeners(name, event); } catch (e) { reportError(name, e); }
    }
  } finally {
    shortcutBudget = Infinity;
  }
}

function animationEvent(prog, name, frame) { guard('animationEvent', prog, { name: name, frame: frame }); }
function animationListeners(name, frame) {
  try { runListeners('animationEvent', { name: name, frame: frame }); } catch (e) { reportError('animationEvent', e); }
}

function mediaEvent(prog, event) {
  var type = event.type;
  if (!hasOwn.call(MEDIA, type)) return;
  guard(type, prog, event);
  if (prog.kind === 1) {
    try { runListeners(type, event); } catch (e) { reportError(type, e); }
  }
}
function mediaJson(prog, text) {
  var event;
  try { event = JSON.parse(text); } catch (e) { reportError('unreadable media payload', e); return; }
  if (event === null || typeof event !== 'object' || typeof event.type !== 'string') {
    reportError('untyped media payload', new Error('media event has no readable type'));
    return;
  }
  for (var i = 0; i < MEDIA_COLORS.length; ++i) {
    var c = event[MEDIA_COLORS[i]];
    if (Array.isArray(c)) event[MEDIA_COLORS[i]] = new Vec3(num(c[0]), num(c[1]), num(c[2]));
  }
  mediaEvent(prog, event);
}
function mediaThumbnail(prog, pr, pg, pb, tr, tg, tb) {
  mediaEvent(prog, { type: 'mediaThumbnailChanged', primaryColor: new Vec3(pr, pg, pb),
                     textColor: new Vec3(tr, tg, tb), hasThumbnail: true });
}

function resizeProgram(prog) {
  guard('resizeScreen', prog, new Vec2(resW, resH));
}
function resizeListeners() {
  try { runListeners('resizeScreen', new Vec2(resW, resH)); }
  catch (e) { reportError('resizeScreen', e); }
}

function applyProps(prog, changed) { guard('applyUserProperties', prog, changed); }
function destroyProgram(prog) { guard('destroy', prog, undefined); }
// After an interrupted call: the state a call leaves behind while it runs.
function resetTransient() { shortcutBudget = Infinity; }

// ---- the global environment scripts see -----------------------------------
function lock(name, value) {
  Object.defineProperty(G, name, { value: value, writable: false, configurable: false, enumerable: true });
}
lock('engine', engine);
lock('input', input);
lock('shared', shared);
lock('localStorage', localStorage);
G.scene = sceneProxy;
G.console = consoleShim;
G.WEMath = WEMath;
G.WEColor = WEColor;
G.WEVector = WEVector;
G.MediaPlaybackEvent = MediaPlaybackEvent;
G.isRunningInEditor = false;
G.editorInfo = [];
G.debugMode = false;
G.logInterrupts = false;
G.tips = false;

return {
  hostUpdate: hostUpdate, setProps: setProps, make: make, evaluate: evaluate,
  startScene: startScene, tickScene: tickScene, cursorEvent: cursorEvent,
  animationEvent: animationEvent, animationListeners: animationListeners,
  mediaJson: mediaJson, mediaThumbnail: mediaThumbnail, resizeProgram: resizeProgram,
  resizeListeners: resizeListeners, applyProps: applyProps, destroyProgram: destroyProgram,
  noticeLanguage: noticeLanguage, notifyEnded: notifyAnimationLayerEnded,
  resetTransient: resetTransient, runInit: runInit, userNotices: userNotices
};
})
)JS";

} // namespace wallpaper::script_library
