// Clean-room implementation from the WallpaperMachine spec e3-scripting.md; written without access to the original source.
//
// The script-side library of the SceneScript host, part 2: layer objects, the
// scene API, animation / sprite-sheet / video objects, layer creation and the
// audio buffers. Same function scope as `ScriptLibraryCore.hpp`.
#pragma once

namespace wallpaper::script_library
{

inline constexpr char kScene[] = R"JS(

// ---- small value helpers --------------------------------------------------
function num(x) { return typeof x === 'number' ? x : 0; }
function isVecLike(v) { return v instanceof Vec2 || v instanceof Vec3 || v instanceof Vec4; }
function parseNumbers(text) {
  var parts = text.trim().split(/[\s,]+/);
  var out = [];
  for (var i = 0; i < parts.length; ++i) { var v = parseFloat(parts[i]); out.push(isFinite(v) ? v : 0); }
  return out;
}
// A value written to a three-component layer property: a number fills every
// component, a two-component vector leaves z at 0, a plain object is read with
// missing components 0, a string is the scene file's whitespace form.
function vec3Parts(v) {
  if (typeof v === 'number') return [v, v, v];
  if (typeof v === 'string') { var p = parseNumbers(v); return [num(p[0]), num(p[1]), num(p[2])]; }
  if (v === null || typeof v !== 'object') return [0, 0, 0];
  return [num(v.x), num(v.y), num(v.z)];
}
// A matrix written to a bone: a Mat4's 16 column-major numbers, or such an array; anything
// else is no matrix (the write is ignored).
function matrixParts(v) {
  if (v !== null && typeof v === 'object' && v.m !== undefined && v.m.length === 16) return v.m.slice();
  if (Array.isArray(v) && v.length === 16) return v.slice();
  return null;
}
function vec2Parts(v) {
  if (typeof v === 'number') return [v, v];
  if (typeof v === 'string') { var p = parseNumbers(v); return [num(p[0]), num(p[1])]; }
  if (v === null || typeof v !== 'object') return [0, 0];
  return [num(v.x), num(v.y)];
}
function toVec3(a) { return new Vec3(a[0], a[1], a[2]); }
var RAD = Math.PI / 180, DEG = 180 / Math.PI;

// ---- layers ---------------------------------------------------------------
var KEY = Symbol('layer');
var layerCache = new Map();
// Authentic wrappers are tracked weakly; inheriting from one does not acquire its native
// lifetime. The predicate checks the current native owner, so a retained JS object becomes
// invalid when its layer or animation is destroyed without keeping that native object alive.
var nativeLifetimes = new WeakMap();
engine.isObjectValid = function (object) {
  if (object === null || (typeof object !== 'object' && typeof object !== 'function')) return false;
  var alive = nativeLifetimes.get(object);
  return alive !== undefined && !!alive();
};

function turnLayerToward(layer, target, up, yawOnly) {
  var direction = toVec3(vec3Parts(target)).subtract(layer.origin);
  up = up === undefined ? new Vec3(0, 1, 0) : toVec3(vec3Parts(up));
  if (yawOnly) direction = direction.subtract(up.multiply(direction.dot(up)));
  if (direction.dot(direction) <= 1.1920928955078125e-7) return;
  var forward = direction.normalize();
  if (n.isCamera(layer[KEY].key)) forward = forward.multiply(-1);
  var right = up.cross(forward).normalize();
  var above = forward.cross(right).normalize();
  layer.angles = Mat4.fromBasis(right, above, forward).extractEuler();
}

class Layer {
  constructor(key) {
    var st = { key: key, alpha: 1, alignment: 'center', plain: Object.create(null),
               volume: 1, muted: false, timelines: null, sheet: null, video: null, particleInstance: null,
               listeners: null };
    Object.defineProperty(this, KEY, { value: st });
    nativeLifetimes.set(this, function () { return n.hasNode(st.key); });
    this.originalOrigin = n.hasNode(key) ? toVec3(n.origin(key)) : new Vec3(0, 0, 0);
  }
  getParent() {
    var parent = n.parent(this[KEY].key);
    return parent ? layerFor(parent) : null;
  }
  setParent(parent, attachment, adjustTransforms) {
    var key = '';
    if (typeof parent === 'number') {
      var index = parent;
      if (Number.isInteger(index) && index >= 0 && index < n.layerCount()) key = n.layerNameAt(index);
    } else if (parent !== undefined && parent !== null) {
      key = keyOf(parent);
      if (!n.hasNode(key)) key = '';
    }
    var adjust = (typeof attachment === 'boolean' && attachment) ||
                 (typeof adjustTransforms === 'boolean' && adjustTransforms);
    var anchor = typeof attachment === 'string' ? n.attachmentIndex(key, attachment)
               : Number.isInteger(attachment) ? attachment : -1;
    if (key === this[KEY].key) {
      n.setParent(this[KEY].key, '', -1, false);
      throw new Error('Invalid parent configuration.');
    }
    if (!n.setParent(this[KEY].key, key, anchor, adjust)) throw new Error('Invalid parent configuration.');
  }
  getAttachmentIndex(name) { return n.attachmentIndex(this[KEY].key, String(name)); }
  getAttachmentMatrix(attachment) {
    var key = this[KEY].key;
    var index = typeof attachment === 'string' ? n.attachmentIndex(key, attachment)
              : Number.isInteger(attachment) ? attachment : -1;
    return new Mat4(n.attachmentMatrix(key, index));
  }
  getAttachmentOrigin(attachment) { return this.getAttachmentMatrix(attachment).translation(); }
  getAttachmentAngles(attachment) { return this.getAttachmentMatrix(attachment).extractEuler(); }
  transformAttachmentToTexture(target, attachment) {
    var layer = typeof target === 'number' ? getLayer(target) : target;
    var key = layer === null || layer === undefined ? '' : keyOf(layer);
    var index = typeof attachment === 'string' ? n.attachmentIndex(key, attachment)
              : Number.isInteger(attachment) ? attachment : -1;
    var matrix = n.attachmentTexture(this[KEY].key, key, index);
    return matrix ? new Mat3(matrix) : null;
  }
  getChildren() {
    var self = this[KEY].key, out = [], count = n.layerCount();
    for (var i = 0; i < count; ++i) {
      var k = n.layerNameAt(i);
      if (n.parent(k) === self) out.push(layerFor(k));
    }
    return out;
  }
  getEffectCount() { return n.effectCount(this[KEY].key); }
  getEffect(x) {
    var key = this[KEY].key;
    var ref = typeof x === 'number'
      ? (Number.isInteger(x) && x >= 0 ? n.effectAt(key, x) : '')
      : n.effectByName(key, String(x));
    return ref ? effectObjectOf(this, ref) : null;
  }
  getTransformMatrix() { return new Mat4(n.matrix(this[KEY].key)); }
  // Turns the layer about its own axes: Euler angles in radians (the `angles` property is in degrees).
  rotateObjectSpace(v) {
    var a = vec3Parts(v);
    n.rotateObjectSpace(this[KEY].key, a[0], a[1], a[2]);
  }
  lookAt(target, up) { turnLayerToward(this, target, up, false); }
  lookAtYaw(target, up) { turnLayerToward(this, target, up, true); }
  getAnimation(name) {
    var st = this[KEY];
    if (st.timelines === null) st.timelines = new Map();
    // With no name it is the layer's first animation that has none.
    var key = name === undefined ? '' : String(name);
    var found = st.timelines.get(key);
    if (found === undefined) { found = new Timeline(st.key, key); st.timelines.set(key, found); }
    return found;
  }
  getAnimationLayer(x) { return animationLayerOf(this[KEY].key, x); }
  // createAnimationLayer / playSingleAnimation 0x14020EA30 / 0x14020EF40: from an animation
  // name or a config object; a playSingleAnimation layer goes after its first cycle.
  createAnimationLayer(x, cfg) { return createAnimationLayerOf(this[KEY].key, x, cfg, false); }
  playSingleAnimation(x, cfg) { return createAnimationLayerOf(this[KEY].key, x, cfg, true); }
  destroyAnimationLayer(x) { return destroyAnimationLayerOf(this[KEY].key, x); }
  getAnimationLayerCount() { return n.puppet(this[KEY].key, '', 'layerCount'); }
  // Puppet bones (B-D8): `bone` is an index or a bone name. World matrices are in the space
  // of a cursor event's worldPosition, local ones relative to the parent bone; local angles
  // are radians, as Wallpaper Engine's natives take them. A layer without bones answers 0,
  // -1 or null and ignores writes.
  getBoneCount() { return n.bone(this[KEY].key, 'count'); }
  getBoneIndex(name) { return n.bone(this[KEY].key, 'index', name); }
  getBoneParentIndex(bone) { return n.bone(this[KEY].key, 'parent', bone); }
  getBoneTransform(bone) { var m = n.bone(this[KEY].key, 'world', bone); return m ? new Mat4(m) : null; }
  setBoneTransform(bone, matrix) { n.bone(this[KEY].key, 'setWorld', bone, matrixParts(matrix)); }
  getLocalBoneTransform(bone) { var m = n.bone(this[KEY].key, 'local', bone); return m ? new Mat4(m) : null; }
  setLocalBoneTransform(bone, matrix) { n.bone(this[KEY].key, 'setLocal', bone, matrixParts(matrix)); }
  getLocalBoneOrigin(bone) {
    var m = n.bone(this[KEY].key, 'local', bone);
    return m ? new Vec3(m[12], m[13], m[14]) : null;
  }
  setLocalBoneOrigin(bone, v) {
    var key = this[KEY].key, m = n.bone(key, 'local', bone);
    if (!m) return;
    var a = vec3Parts(v);
    m[12] = a[0]; m[13] = a[1]; m[14] = a[2];
    n.bone(key, 'setLocal', bone, m);
  }
  // 0x14020FA10: the z, y, x turns (Rz * Ry * Rx) of the local matrix as stored.
  getLocalBoneAngles(bone) {
    var m = n.bone(this[KEY].key, 'local', bone);
    if (!m) return null;
    var z = Math.atan2(m[1], m[0]);
    var y = Math.atan2(-m[2], Math.sqrt(m[6] * m[6] + m[10] * m[10]));
    var s = Math.sin(z), c = Math.cos(z);
    var x = Math.atan2(s * m[8] - c * m[9], c * m[5] - s * m[4]);
    return new Vec3(x, y, z);
  }
  // 0x14020FCE0: the turn becomes Rz * Ry * Rx with no scale; the origin stays.
  setLocalBoneAngles(bone, v) {
    var key = this[KEY].key, m = n.bone(key, 'local', bone);
    if (!m) return;
    var a = vec3Parts(v);
    var cx = Math.cos(a[0]), sx = Math.sin(a[0]), cy = Math.cos(a[1]), sy = Math.sin(a[1]);
    var cz = Math.cos(a[2]), sz = Math.sin(a[2]);
    m[0] = cy * cz; m[1] = cy * sz; m[2] = -sy; m[3] = 0;
    m[4] = sy * cz * sx - cx * sz; m[5] = sy * sz * sx + cx * cz; m[6] = sx * cy; m[7] = 0;
    m[8] = cx * cz * sy + sx * sz; m[9] = cx * sz * sy - sx * cz; m[10] = cx * cy; m[11] = 0;
    n.bone(key, 'setLocal', bone, m);
  }
  applyBonePhysicsImpulse(bone, linear, angular) {
    var l = vec3Parts(linear), r = angular === undefined ? [0, 0, 0] : vec3Parts(angular);
    n.bone(this[KEY].key, 'impulse', bone, [l[0], l[1], l[2], r[0], r[1], r[2]]);
  }
  resetBonePhysicsSimulation(bone) { n.bone(this[KEY].key, 'reset', bone); }
  getBlendShapeIndex(name) { return n.bone(this[KEY].key, 'shapeIndex', name); }
  getBlendShapeWeight(shape) { return n.bone(this[KEY].key, 'shapeWeight', shape); }
  setBlendShapeWeight(shape, weight) { n.bone(this[KEY].key, 'setShapeWeight', shape, [Number(weight)]); }
  getTextureAnimation() {
    var st = this[KEY];
    if (st.sheet === null) st.sheet = new Sheet(st.key);
    return st.sheet;
  }
  getVideoTexture() {
    var st = this[KEY];
    if (st.video === null) st.video = new Video(st.key);
    return st.video;
  }
  play() { var key = this[KEY].key; if (!n.particle(key, 'play')) n.soundPlay(key); }
  pause() { var key = this[KEY].key; if (!n.particle(key, 'pause')) n.soundPause(key); }
  stop() { var key = this[KEY].key; if (!n.particle(key, 'stop')) n.soundStop(key); }
  isPlaying() {
    var key = this[KEY].key;
    return n.hasParticles(key) ? n.particle(key, 'isPlaying') : n.soundPlaying(key);
  }
  emitParticles(count) { n.particle(this[KEY].key, 'emit', count === undefined ? 0 : count); }
  get instance() {
    var st = this[KEY];
    if (!n.hasParticles(st.key)) return undefined;
    if (st.particleInstance === null) st.particleInstance = new ParticleInstance(st.key);
    return st.particleInstance;
  }
  on(event, fn) {
    var st = this[KEY];
    if (typeof event !== 'string' || typeof fn !== 'function') return;
    if (st.listeners === null) st.listeners = Object.create(null);
    var list = st.listeners[event];
    if (list === undefined) st.listeners[event] = list = [];
    list.push(fn);
  }
  emit(event, payload) {
    var st = this[KEY];
    var list = st.listeners === null ? undefined : st.listeners[event];
    if (list === undefined) return;
    var count = list.length;
    for (var i = 0; i < count; ++i) list[i](payload);
  }
}

function accessor(name, get, set) {
  Object.defineProperty(Layer.prototype, name, { get: get, set: set, configurable: true, enumerable: false });
}
// Writable: the layer is found by its new name (setter 0x1401A4D00).
accessor('name',
  function () { return n.authoredName(this[KEY].key); },
  function (v) { n.renameLayer(this[KEY].key, String(v)); });
accessor('visible',
  function () { return n.visible(this[KEY].key); },
  function (v) { n.setVisible(this[KEY].key, !!v); });
accessor('origin',
  function () { return toVec3(n.origin(this[KEY].key)); },
  function (v) { var a = vec3Parts(v); n.setOrigin(this[KEY].key, a[0], a[1], a[2]); });
accessor('scale',
  function () { return toVec3(n.scale(this[KEY].key)); },
  function (v) { var a = vec3Parts(v); n.setScale(this[KEY].key, a[0], a[1], a[2]); });
accessor('angles',
  function () { var a = n.rotation(this[KEY].key); return new Vec3(a[0] * DEG, a[1] * DEG, a[2] * DEG); },
  function (v) { var a = vec3Parts(v); n.setRotation(this[KEY].key, a[0] * RAD, a[1] * RAD, a[2] * RAD); });
// A writable Vec2 the draw reads (we_ss_reg_ImageLayer 0x1401EE520, +752, setter 0x1401A4200).
accessor('size',
  function () { var a = n.size(this[KEY].key); return new Vec2(a[0], a[1]); },
  function (v) { var a = vec2Parts(v); n.setSize(this[KEY].key, a[0], a[1]); });
accessor('color',
  function () { var key = this[KEY].key; var l = n.light(key, 'color'); return toVec3(l !== undefined ? l : n.color(key)); },
  function (v) {
    var key = this[KEY].key, a = vec3Parts(v);
    if (!n.setLight(key, 'color', a[0], a[1], a[2])) n.setColor(key, a[0], a[1], a[2]);
  });
accessor('alpha',
  function () {
    var st = this[KEY];
    var value = n.alpha(st.key);
    return value === undefined ? st.alpha : value;
  },
  function (v) {
    var st = this[KEY];
    var value = Number(v);
    if (!isFinite(value)) value = 0;
    st.alpha = value;
    n.setAlpha(st.key, value);
  });
accessor('text',
  function () { return n.text(this[KEY].key); },
  function (v) { n.setText(this[KEY].key, String(v)); });
accessor('alignment',
  function () { return this[KEY].alignment; },
  function (v) { var st = this[KEY]; st.alignment = String(v); n.setAlignment(st.key, st.alignment); });
accessor('parallaxDepth',
  function () { var a = n.parallax(this[KEY].key); return new Vec2(a[0], a[1]); },
  function (v) { var a = vec2Parts(v); n.setParallax(this[KEY].key, a[0], a[1]); });

// An image layer's own members (we_ss_reg_ImageLayer 0x1401EE520). On a layer without them the
// name is a plain property of the script object.
var LAYER_FLAG_BOOLS = { perspective: 1, copybackground: 1, nointerpolation: 1, clampuvs: 1, ledsource: 1, castshadow: 1 };
function layerFlagAccessor(name) {
  var isBool = hasOwn.call(LAYER_FLAG_BOOLS, name);
  accessor(name,
    function () {
      var st = this[KEY];
      var value = n.layerFlag(st.key, name);
      if (value === undefined && name === 'castshadow') { var l = n.light(st.key, name); if (l !== undefined) value = l[0]; }
      if (value === undefined) return st.plain[name];
      return isBool ? value !== 0 : value;
    },
    function (v) {
      var st = this[KEY];
      var value = isBool ? (v ? 1 : 0) : (name === 'colorBlendMode' ? Math.trunc(Number(v)) : Number(v));
      if (n.setLayerFlag(st.key, name, value)) return;
      if (name === 'castshadow' && n.setLight(st.key, name, value)) return;
      st.plain[name] = v;
    });
}
['brightness', 'colorBlendMode', 'perspective', 'copybackground', 'nointerpolation', 'clampuvs', 'ledsource',
 'castshadow'].forEach(layerFlagAccessor);

// Cursor members of every layer (we_ss_reg_SceneObjectBase 0x1401E0530, bits @288).
function cursorAccessor(name, index) {
  accessor(name,
    function () {
      var st = this[KEY];
      var t = n.cursorTarget(st.key);
      return t === undefined ? st.plain[name] : t[index] !== 0;
    },
    function (v) {
      var st = this[KEY];
      var t = n.cursorTarget(st.key);
      if (t === undefined) { st.plain[name] = v; return; }
      var solid = index === 1 ? !!v : t[1] !== 0;
      var blocks = index === 2 ? !!v : t[2] !== 0;
      n.setCursorTarget(st.key, solid, blocks);
    });
}
cursorAccessor('solid', 1);
cursorAccessor('disablepropagation', 2);
// `sortorder`, an integer of every layer (@292).
accessor('sortorder',
  function () { var st = this[KEY]; var v = n.sortOrder(st.key); return v === undefined ? st.plain.sortorder : v; },
  function (v) { var st = this[KEY]; if (!n.setSortOrder(st.key, Number(v))) st.plain.sortorder = v; });

// A light layer's members (we_ss_reg_LightLayer 0x14025DA80); `color`, `castshadow` and
// `visible` are shared with other layers above.
var LIGHT_BOOLS = { usecookie: 1, castvolumetrics: 1 };
var LIGHT_VEC3S = { controlpoint: 1 };
function lightAccessor(name) {
  accessor(name,
    function () {
      var st = this[KEY];
      var v = n.light(st.key, name);
      if (v === undefined) return st.plain[name];
      if (name === 'light') return v;
      if (hasOwn.call(LIGHT_VEC3S, name)) return toVec3(v);
      return hasOwn.call(LIGHT_BOOLS, name) ? v[0] !== 0 : v[0];
    },
    function (value) {
      var st = this[KEY], done;
      if (name === 'light') done = n.setLight(st.key, name, String(value));
      else if (hasOwn.call(LIGHT_VEC3S, name)) { var a = vec3Parts(value); done = n.setLight(st.key, name, a[0], a[1], a[2]); }
      else if (hasOwn.call(LIGHT_BOOLS, name)) done = n.setLight(st.key, name, value ? 1 : 0);
      else done = n.setLight(st.key, name, Number(value));
      if (!done) st.plain[name] = value;
    });
}
['intensity', 'radius', 'exponent', 'innercone', 'outercone', 'density', 'volumetricsexponent',
 'cascadedistance0', 'cascadedistance1', 'cascadedistance2', 'lightsourcesize', 'controlpoint', 'light',
 'usecookie', 'castvolumetrics'].forEach(lightAccessor);

// A sound layer's members (we_ss_reg_SoundLayer 0x1401F7090).
var SOUND_BOOLS = { muteineditor: 1, startsilent: 1, spatialization: 1 };
['mintime', 'maxtime', 'attenuation', 'mindistance', 'playbackmode', 'muteineditor', 'startsilent',
 'spatialization'].forEach(function (name) {
  var isBool = hasOwn.call(SOUND_BOOLS, name);
  accessor(name,
    function () {
      var st = this[KEY];
      var v = n.soundMember(st.key, name);
      if (v === undefined) return st.plain[name];
      return isBool ? v !== 0 : v;
    },
    function (value) {
      var st = this[KEY];
      var arg = name === 'playbackmode' ? String(value) : (isBool ? (value ? 1 : 0) : Number(value));
      if (!n.setSoundMember(st.key, name, arg)) st.plain[name] = value;
    });
});

var STYLE_WORDS = {
  horizontalalign: { left: 1, center: 1, right: 1 },
  verticalalign: { top: 1, center: 1, bottom: 1 },
  depthtest: { enabled: 1, disabled: 1 },
  anchor: { none: 1, center: 1, top: 1, topright: 1, right: 1, bottomright: 1,
            bottom: 1, bottomleft: 1, left: 1, topleft: 1 }
};
function styleAccessor(name, kind) {
  accessor(name,
    function () {
      var st = this[KEY];
      var value = n.textStyle(st.key, name);
      if (value === undefined) return st.plain[name];
      if (kind === 'number' || kind === 'int') return Number(value);
      if (kind === 'bool') return value !== '0';
      if (kind === 'vec2') { var a = parseNumbers(value); return new Vec2(a[0], a[1]); }
      if (kind === 'vec3') return toVec3(parseNumbers(value));
      return value;
    },
    function (value) {
      var st = this[KEY];
      if (n.textStyle(st.key, name) === undefined) { st.plain[name] = value; return; }
      var text;
      if (kind === 'vec2' || kind === 'vec3') {
        var a = kind === 'vec2' ? vec2Parts(value) : vec3Parts(value);
        if (!a.every(isFinite)) return;
        text = a.join(' ');
      } else if (kind === 'bool') text = value ? '1' : '0';
      else if (kind === 'number' || kind === 'int') {
        var number = Number(value);
        if (!isFinite(number) || (name === 'pointsize' && number <= 0)) return;
        text = String(kind === 'int' ? Math.trunc(number) : number);
      } else text = String(value);
      if (hasOwn.call(STYLE_WORDS, name)) {
        if (!hasOwn.call(STYLE_WORDS[name], text)) {
          text = name === 'horizontalalign' ? 'left' : name === 'verticalalign' ? 'center'
            : name === 'depthtest' ? 'disabled' : 'none';
        }
      }
      n.setTextStyle(st.key, name, text);
    });
}
styleAccessor('font');
styleAccessor('pointsize', 'number');
styleAccessor('horizontalalign');
styleAccessor('verticalalign');
styleAccessor('anchor');
styleAccessor('depthtest');
['padding', 'spacing', 'dropshadowoffset'].forEach(function (name) { styleAccessor(name, 'vec2'); });
['backgroundcolor', 'outlinecolor', 'dropshadowcolor'].forEach(function (name) { styleAccessor(name, 'vec3'); });
['maxwidth', 'backgroundbrightness', 'outlinethickness', 'blursize', 'dropshadowsize',
 'dropshadowopacity'].forEach(function (name) { styleAccessor(name, 'number'); });
styleAccessor('maxrows', 'int');
['limitwidth', 'limitrows', 'limituseellipsis', 'blockalign', 'opaquebackground', 'msdf',
 'outline', 'blur', 'dropshadow'].forEach(function (name) { styleAccessor(name, 'bool'); });

accessor('volume',
  function () { var st = this[KEY]; return n.hasSound(st.key) ? n.soundVolume(st.key) : st.volume; },
  function (v) {
    var st = this[KEY];
    var value = Number(v);
    if (!isFinite(value)) value = 0;
    if (n.hasSound(st.key)) n.soundSetVolume(st.key, value); else st.volume = value;
  });
accessor('muted',
  function () { var st = this[KEY]; return n.hasSound(st.key) ? n.soundMuted(st.key) : st.muted; },
  function (v) {
    var st = this[KEY];
    if (n.hasSound(st.key)) n.soundSetMuted(st.key, !!v); else st.muted = !!v;
  });

// What a script that decides an effect's visibility (or calls `layer.getEffect`) has: its layer,
// except that `name`, `visible` and `getMaterial` are the effect's own, so writing `visible`
// switches the effect and leaves the layer.
var effectCache = new Map();
var materialCache = new Map();
function materialConstantFloats(v) {
  if (typeof v === 'number') return [finiteOr(v, 0)];
  if (typeof v === 'boolean') return [v ? 1 : 0];
  if (typeof v === 'string') return parseNumbers(v);
  if (v instanceof Vec4) return [num(v.x), num(v.y), num(v.z), num(v.w)];
  if (v instanceof Vec3) return [num(v.x), num(v.y), num(v.z)];
  if (v instanceof Vec2) return [num(v.x), num(v.y)];
  if (Array.isArray(v)) {
    var out = [];
    for (var i = 0; i < v.length; ++i) out.push(finiteOr(Number(v[i]), 0));
    return out;
  }
  if (v !== null && typeof v === 'object') {
    if ('w' in v) return [num(v.x), num(v.y), num(v.z), num(v.w)];
    if ('z' in v) return [num(v.x), num(v.y), num(v.z)];
    if ('x' in v || 'y' in v) return [num(v.x), num(v.y)];
  }
  return [];
}
// A constant as the material holds it (a number, or a vector of its width), or what a script
// stored under a name the material does not have.
function materialConstantOf(reference, index, store, key) {
  var live = n.materialConstant(reference, index, key);
  if (live === undefined) return store[key];
  if (live.length === 1) return live[0];
  if (live.length === 2) return new Vec2(live[0], live[1]);
  if (live.length === 3) return new Vec3(live[0], live[1], live[2]);
  if (live.length === 4) return new Vec4(live[0], live[1], live[2], live[3]);
  return live;
}
function materialObjectOf(reference, index) {
  var id = reference + '\u0001' + index;
  var found = materialCache.get(id);
  if (found !== undefined) return found;
  var store = Object.create(null);
  var target = {
    getConstant: function (name) { return materialConstantOf(reference, index, store, String(name)); },
    setConstant: function (name, value) {
      var key = String(name);
      store[key] = value;
      var floats = materialConstantFloats(value);
      if (floats.length > 0) n.setMaterialConstant(reference, index, key, floats);
    }
  };
  found = new Proxy(target, {
    get: function (obj, prop) {
      if (typeof prop !== 'string' || prop in obj) return obj[prop];
      return materialConstantOf(reference, index, store, prop);
    },
    set: function (obj, prop, value) {
      if (typeof prop === 'string' && !(prop in obj)) obj.setConstant(prop, value);
      else obj[prop] = value;
      return true;
    }
  });
  materialCache.set(id, found);
  return found;
}
function effectObjectOf(layer, reference) {
  var found = effectCache.get(reference);
  if (found !== undefined) return found;
  var customName;
  var object = {};
  nativeLifetimes.set(object, function () { return n.effectExists(reference); });
  Object.defineProperty(object, 'name', {
    get: function () { return customName !== undefined ? customName : n.effectName(reference); },
    set: function (v) { customName = v; },
    enumerable: false, configurable: true
  });
  Object.defineProperty(object, 'visible', {
    get: function () { return n.effectVisible(reference); },
    set: function (v) { n.setEffectVisible(reference, !!v); },
    enumerable: false, configurable: true
  });
  Object.defineProperty(object, 'getMaterialCount', {
    value: function () { return n.effectMaterialCount(reference); },
    writable: true, enumerable: false, configurable: true
  });
  Object.defineProperty(object, 'getMaterial', {
    value: function (index) {
      var at = typeof index === 'string' ? n.effectMaterialByName(reference, index) : Number(index);
      if (!(Number.isInteger(at) && at >= 0 && at < n.effectMaterialCount(reference))) return null;
      return materialObjectOf(reference, at);
    },
    writable: true, enumerable: false, configurable: true
  });
  Object.defineProperty(object, 'setMaterialProperty', {
    value: function (name, value) {
      var values = materialConstantFloats(value);
      if (values.length > 0) n.setMaterialProperty(reference, String(name), values, typeof value === 'number');
    },
    writable: true, enumerable: false, configurable: true
  });
  Object.defineProperty(object, 'executeMaterialFunction', {
    value: function (name) { n.executeMaterialFunction(reference, String(name)); },
    writable: true, enumerable: false, configurable: true
  });
  effectCache.set(reference, object);
  return object;
}
// What a script on a keyed setting has as `thisObject`: its layer, except that
// `getAnimation()` with no name is the setting's own animation.
function settingObjectOf(layer, reference) {
  var object = Object.create(layer);
  nativeLifetimes.set(object, function () { return n.hasNode(layer[KEY].key); });
  var own = null;
  Object.defineProperty(object, 'getAnimation', {
    value: function (name) {
      if (name !== undefined) return layer.getAnimation(name);
      if (own === null) own = new Timeline('\u0003' + reference, '');
      return own;
    },
    writable: true, enumerable: false, configurable: true
  });
  return object;
}

function layerFor(key) {
  var layer = layerCache.get(key);
  if (layer === undefined) { layer = new Layer(key); layerCache.set(key, layer); }
  return layer;
}
function keyOf(x) {
  if (x !== null && typeof x === 'object' && x[KEY] !== undefined) return x[KEY].key;
  return n.resolve(String(x));
}

// ---- timelines, animation layers, sprite sheets, video textures -----------
class Timeline {
  constructor(layerKey, name) {
    Object.defineProperty(this, KEY, { value: { layer: layerKey, name: name } });
    nativeLifetimes.set(this, function () { return n.timeline(layerKey, name, 'exists') !== 0; });
  }
  get name() { return this[KEY].name; }
  get fps() { return this.op('fps'); }
  get frameCount() { return this.op('frameCount'); }
  get duration() { var fps = this.fps; return fps > 0 ? this.frameCount / fps : 0; }
  get rate() { return this.op('rate'); }
  set rate(v) { if (typeof v === 'number' && isFinite(v)) this.op('setRate', v); }
  op(name, value) { var st = this[KEY]; return n.timeline(st.layer, st.name, name, value); }
  play() { this.op('play'); }
  pause() { this.op('pause'); }
  stop() { this.op('stop'); }
  isPlaying() { return this.op('isPlaying') !== 0; }
  getFrame() { return this.op('frame'); }
  setFrame(f) { if (typeof f === 'number' && isFinite(f)) this.op('setFrame', f); }
}
Object.defineProperty(Timeline.prototype, 'op', { enumerable: false });
var sceneTimelines = new Map();
function sceneAnimation(name) {
  var key = String(name);
  var found = sceneTimelines.get(key);
  if (found === undefined) { found = new Timeline('', key); sceneTimelines.set(key, found); }
  return found;
}

var endedListeners = new Map();
var animationLayers = new Map();
// The ids a layer's animation-layer objects and listeners are filed under, so they
// go when the layer does. An animation layer is filed under its serial, which follows it
// when a layer below it goes.
var animationIds = new Map();
class AnimationLayer {
  constructor(layerKey, ref, serial, asked) {
    Object.defineProperty(this, KEY, { value: { layer: layerKey, ref: ref, serial: serial, asked: asked } });
    nativeLifetimes.set(this, function () {
      return serial >= 0 && n.puppet(layerKey, ref, 'exists', undefined, true) !== 0;
    });
  }
  op(name, value) {
    var st = this[KEY];
    return st.serial < 0 ? undefined : n.puppet(st.layer, st.ref, name, value, true);
  }
  get name() { var st = this[KEY]; return st.serial < 0 ? st.asked : n.puppetName(st.layer, st.ref, true); }
  get fps() { return num(this.op('fps')); }
  get frameCount() { var st = this[KEY]; return st.serial < 0 ? 1 : this.op('frameCount'); }
  get duration() { var fps = this.fps; return fps > 0 ? this.frameCount / fps : 0; }
  get rate() { var st = this[KEY]; return st.serial < 0 ? 1 : this.op('rate'); }
  set rate(v) { if (typeof v === 'number' && isFinite(v)) this.op('setRate', v); }
  get blend() { var st = this[KEY]; return st.serial < 0 ? 1 : this.op('blend'); }
  set blend(v) { if (typeof v === 'number' && isFinite(v)) this.op('setBlend', v); }
  get visible() { var st = this[KEY]; return st.serial < 0 ? true : this.op('visible') !== 0; }
  set visible(v) { this.op('setVisible', v ? 1 : 0); }
  get additive() { var st = this[KEY]; return st.serial < 0 ? false : this.op('additive') !== 0; }
  set additive(v) { this.op('setAdditive', v ? 1 : 0); }
  get blendin() { var st = this[KEY]; return st.serial < 0 ? false : this.op('blendin') !== 0; }
  set blendin(v) { this.op('setBlendIn', v ? 1 : 0); }
  get blendout() { var st = this[KEY]; return st.serial < 0 ? false : this.op('blendout') !== 0; }
  set blendout(v) { this.op('setBlendOut', v ? 1 : 0); }
  get blendtime() { var st = this[KEY]; return st.serial < 0 ? 0.5 : this.op('blendtime'); }
  set blendtime(v) { if (typeof v === 'number' && isFinite(v)) this.op('setBlendTime', v); }
  play() { this.op('play'); }
  pause() { this.op('pause'); }
  stop() { this.op('stop'); }
  isPlaying() { return num(this.op('isPlaying')) !== 0; }
  getFrame() { return num(this.op('frame')); }
  setFrame(f) { if (typeof f === 'number' && isFinite(f)) this.op('setFrame', f); }
  getCurrentTime() { var fps = this.fps; return fps > 0 ? this.getFrame() / fps : 0; }
  addEndedCallback(fn) {
    var st = this[KEY];
    if (st.serial < 0 || typeof fn !== 'function') return;
    var id = st.layer + '\u0001' + st.serial;
    var list = endedListeners.get(id);
    if (list === undefined) {
      list = [];
      endedListeners.set(id, list);
      fileAnimationId(st.layer, id);
    }
    list.push(fn);
  }
  removeEndedCallback(fn) {
    var st = this[KEY];
    var list = endedListeners.get(st.layer + '\u0001' + st.serial);
    if (list === undefined) return;
    var at = list.indexOf(fn);
    if (at >= 0) list.splice(at, 1);
  }
}
Object.defineProperty(AnimationLayer.prototype, 'op', { enumerable: false });

function fileAnimationId(layerKey, id) {
  var ids = animationIds.get(layerKey);
  if (ids === undefined) animationIds.set(layerKey, ids = []);
  if (ids.indexOf(id) < 0) ids.push(id);
}

function animationLayerOf(layerKey, x, bySerial) {
  var ref = String(x);
  var serial = -1;
  if (n.puppet(layerKey, '', 'layerCount') > 0) serial = n.puppet(layerKey, ref, 'serial', undefined, bySerial === true);
  var id = layerKey + (serial >= 0 ? '\u0001' + serial : '\u0002' + ref);
  var found = animationLayers.get(id);
  if (found === undefined) {
    found = new AnimationLayer(layerKey, serial >= 0 ? '#' + serial : ref, serial, ref);
    animationLayers.set(id, found);
    fileAnimationId(layerKey, id);
  }
  return found;
}

// createAnimationLayer 0x14020EA30 takes a name or a config object (its JSON text); the
// second argument is copied over the config. Anything else makes no layer.
function createAnimationLayerOf(layerKey, x, cfg, single) {
  var object = false, text;
  if (typeof x === 'string') text = x;
  else if (x !== null && typeof x === 'object' && !(x instanceof AnimationLayer)) { object = true; text = JSON.stringify(x); }
  if (typeof text !== 'string' || text === '') return null;
  var cfgText = '';
  if (typeof cfg === 'string') cfgText = cfg;
  else if (cfg !== null && typeof cfg === 'object') cfgText = JSON.stringify(cfg);
  var serial = n.puppetCreate(layerKey, object ? 1 : 0, text, cfgText, single ? 1 : 0);
  if (serial < 0) return null;
  // A name asked for before may be the new layer's now.
  var ids = animationIds.get(layerKey);
  if (ids !== undefined) {
    var copy = ids.slice();
    for (var i = 0; i < copy.length; ++i) if (copy[i].indexOf('\u0002') >= 0) forgetAnimationId(layerKey, copy[i]);
  }
  return animationLayerOf(layerKey, '#' + serial, true);
}

// destroyAnimationLayer 0x14020EF80: a name (every layer with it), an index or an
// animation-layer object. The objects and listeners of a layer that went are dropped.
function destroyAnimationLayerOf(layerKey, x) {
  var gone = false;
  if (typeof x === 'string') {
    gone = n.puppet(layerKey, x, 'destroyNamed') !== 0;
  } else if (typeof x === 'number') {
    var serial = n.puppet(layerKey, '', 'serialAt', Math.trunc(x));
    gone = n.puppet(layerKey, '', 'layerCount') > 0 && serial >= 0 &&
           n.puppet(layerKey, '#' + serial, 'destroy', undefined, true) !== 0;
  } else if (x instanceof AnimationLayer) {
    var st = x[KEY];
    gone = st.layer === layerKey && st.serial >= 0 && n.puppet(layerKey, st.ref, 'destroy', undefined, true) !== 0;
  }
  if (gone) forgetGoneAnimationLayers(layerKey);
  return gone;
}

function forgetAnimationId(layerKey, id) {
  animationLayers.delete(id);
  endedListeners.delete(id);
  var ids = animationIds.get(layerKey);
  if (ids === undefined) return;
  var at = ids.indexOf(id);
  if (at >= 0) ids.splice(at, 1);
}

function forgetGoneAnimationLayers(layerKey) {
  var ids = animationIds.get(layerKey);
  if (ids === undefined) return;
  var copy = ids.slice();
  for (var i = 0; i < copy.length; ++i) {
    var at = copy[i].lastIndexOf('\u0001');
    if (at < 0) continue;
    if (n.puppet(layerKey, '#' + copy[i].slice(at + 1), 'index', undefined, true) < 0) forgetAnimationId(layerKey, copy[i]);
  }
}

// `removed`: a playSingleAnimation layer that goes once its listeners ran.
function notifyAnimationLayerEnded(layerKey, serial, removed) {
  var id = layerKey + '\u0001' + serial;
  var list = endedListeners.get(id);
  if (list !== undefined && list.length !== 0) {
    var copy = list.slice();
    var failed = false, failure;
    for (var i = 0; i < copy.length; ++i) {
      // A listener an earlier one removed never fires.
      if (list.indexOf(copy[i]) < 0) continue;
      try { copy[i](); } catch (e) { if (!failed) { failed = true; failure = e; } }
    }
    if (failed) reportError('layer-ended notice', failure);
  }
  if (removed) forgetAnimationId(layerKey, id);
}

class ParticleInstance {
  constructor(layerKey) {
    Object.defineProperty(this, KEY, { value: { key: layerKey } });
    nativeLifetimes.set(this, function () { return n.hasParticles(layerKey); });
  }
}
['alpha', 'size', 'count', 'speed', 'lifetime', 'rate', 'brightness'].forEach(function (name) {
  Object.defineProperty(ParticleInstance.prototype, name, {
    get: function () { return n.particleInstance(this[KEY].key, name); },
    set: function (value) { n.setParticleInstance(this[KEY].key, name, Number(value)); },
    enumerable: true
  });
});
var particleVectors = ['colorn'];
for (var particlePoint = 0; particlePoint < 8; ++particlePoint) {
  particleVectors.push('controlpoint' + particlePoint, 'controlpointangle' + particlePoint);
}
particleVectors.forEach(function (name) {
  Object.defineProperty(ParticleInstance.prototype, name, {
    get: function () {
      var value = n.particleInstance(this[KEY].key, name);
      return value === undefined ? undefined : toVec3(value);
    },
    set: function (value) {
      var lanes = vec3Parts(value);
      n.setParticleInstance(this[KEY].key, name, lanes[0], lanes[1], lanes[2]);
    },
    enumerable: true
  });
});

class Sheet {
  constructor(layerKey) {
    Object.defineProperty(this, KEY, { value: { key: layerKey } });
    nativeLifetimes.set(this, function () { return n.sheet(layerKey, 'exists') !== 0; });
  }
  info(at) { var i = n.sheetInfo(this[KEY].key); return i === undefined ? undefined : i[at]; }
  get name() { var v = this.info(0); return v === undefined ? '' : v; }
  get frameCount() { return num(this.info(1)); }
  get duration() { return num(this.info(2)); }
  get fps() { return num(this.info(3)); }
  get rate() { return n.sheet(this[KEY].key, 'rate'); }
  set rate(v) { n.sheet(this[KEY].key, 'setRate', Number(v)); }
  play() { n.sheet(this[KEY].key, 'play'); }
  pause() { n.sheet(this[KEY].key, 'pause'); }
  stop() { n.sheet(this[KEY].key, 'stop'); }
  isPlaying() { return n.sheet(this[KEY].key, 'isPlaying') !== 0; }
  setFrame(f) { n.sheet(this[KEY].key, 'setFrame', Math.trunc(Number(f))); }
  join() { n.sheet(this[KEY].key, 'join'); }
  getFrame() { return n.sheet(this[KEY].key, 'frame'); }
}
Object.defineProperty(Sheet.prototype, 'info', { enumerable: false });

class Video {
  constructor(layerKey) {
    Object.defineProperty(this, KEY, { value: { key: layerKey } });
    nativeLifetimes.set(this, function () { return n.video(layerKey, 'exists') !== 0; });
  }
  play() { n.video(this[KEY].key, 'play'); }
  pause() { n.video(this[KEY].key, 'pause'); }
  stop() { n.video(this[KEY].key, 'stop'); }
  isPlaying() { return n.video(this[KEY].key, 'isPlaying') !== 0; }
  getCurrentTime() { return n.video(this[KEY].key, 'time'); }
  setCurrentTime(t) { n.video(this[KEY].key, 'setTime', Number(t)); }
  get duration() { return n.video(this[KEY].key, 'duration'); }
  get rate() { return n.video(this[KEY].key, 'rate'); }
  set rate(v) { n.video(this[KEY].key, 'setRate', Number(v)); }
  // we_ss_reg_VideoTexture 0x140214050: `loop` (pushed to the decoder) and the listeners
  // told when a clip that does not loop reaches its end.
  get loop() { return n.video(this[KEY].key, 'loop') !== 0; }
  set loop(v) { n.video(this[KEY].key, 'setLoop', v ? 1 : 0); }
  addEndedCallback(fn) {
    if (typeof fn !== 'function') return;
    var key = this[KEY].key;
    var list = videoEndedListeners.get(key);
    if (list === undefined) videoEndedListeners.set(key, list = []);
    list.push(fn);
  }
}
var videoEndedListeners = new Map();
function notifyVideoEnded(layerKey) {
  var list = videoEndedListeners.get(layerKey);
  if (list === undefined) return;
  var count = list.length;
  for (var i = 0; i < count; ++i) list[i]();
}

// ---- scene API ------------------------------------------------------------
function getLayer(x) {
  if (typeof x === 'number') {
    if (!(Number.isInteger(x) && x >= 0 && x < n.layerCount())) return null;
    return layerFor(n.layerNameAt(x));
  }
  return layerFor(n.resolve(String(x)));
}

// What each forwarded text-layer key is converted to (R58, R129); order is not significant.
var TEXT_KEY_KINDS = {
  font: 'text', horizontalalign: 'text', verticalalign: 'text', anchor: 'text',
  pointsize: 'number', padding: 'number', maxwidth: 'number', maxrows: 'number',
  alpha: 'number', brightness: 'number',
  limitwidth: 'flag', limitrows: 'flag', limituseellipsis: 'flag', perspective: 'flag',
  color: 'vec3', size: 'vec2'
};
var TEXT_CONVERTERS = {
  text: function (v) { return String(v); },
  number: function (v) { var x = Number(v); return isFinite(x) ? x : undefined; },
  flag: function (v) { return !!v; },
  vec3: function (v) { return vec3Parts(v).join(' '); },
  vec2: function (v) { return vec2Parts(v).join(' '); }
};
// A `{ value }` wrapper stands for the value inside it.
function unwrap(v) {
  if (v !== null && typeof v === 'object' && !isVecLike(v) && !Array.isArray(v) && 'value' in v) return v.value;
  return v;
}
function textConfig(cfg) {
  var body = unwrap(cfg.text);
  var out = { visible: true, text: body === undefined || body === null ? '' : String(body) };
  Object.keys(TEXT_KEY_KINDS).forEach(function (key) {
    var raw = unwrap(cfg[key]);
    if (raw === undefined || raw === null) return;
    var converted = TEXT_CONVERTERS[TEXT_KEY_KINDS[key]](raw);
    if (converted !== undefined) out[key] = converted;
  });
  return JSON.stringify(out);
}

// The layer a `parent` option names (a layer object, its name, or an object with a
// name), or undefined.
function parentKeyOf(parent) {
  if (typeof parent === 'string') return n.resolve(parent);
  if (parent === null || typeof parent !== 'object') return undefined;
  if (parent[KEY] !== undefined) return parent[KEY].key;
  return typeof parent.name === 'string' ? n.resolve(parent.name) : undefined;
}
// Options that do not depend on one another: each is the layer member of that name.
// `angles` is not: the configuration is read like an object in scene.json
// (0x1401C1430), so its angles are radians, while the member is in degrees.
var INDEPENDENT_OPTIONS = ['parallaxDepth', 'origin', 'scale', 'color', 'alpha', 'visible',
                           'alignment'];
function applyCreateOptions(layer, cfg) {
  var st = layer[KEY];
  // The parent comes first so placement options are relative to it.
  var parentKey = parentKeyOf(cfg.parent);
  if (parentKey !== undefined && parentKey !== st.key && n.hasNode(parentKey)) n.setParent(st.key, parentKey, -1, false);
  if (cfg.name !== undefined && cfg.name !== null) {
    n.renameLayer(st.key, String(cfg.name));
  }
  if (cfg.size !== undefined && cfg.size !== null) {
    var extent = vec2Parts(cfg.size);
    n.setSize(st.key, extent[0], extent[1]);
  }
  INDEPENDENT_OPTIONS.forEach(function (member) {
    if (cfg[member] !== undefined && cfg[member] !== null) layer[member] = cfg[member];
  });
  if (cfg.angles !== undefined && cfg.angles !== null) {
    var turn = vec3Parts(cfg.angles);
    n.setRotation(st.key, turn[0], turn[1], turn[2]);
  }
  // Recorded once everything else has taken effect.
  layer.originalOrigin = layer.origin;
}

var modelDataKeys = new WeakMap();
var modelDataSecret = {};
function applyModelData(configuration) {
  var token = modelDataKeys.get(this);
  if (token === undefined) throw new TypeError('Invalid ModelData receiver');
  n.modelDataUpdate(token, configuration, false);
}
function replaceModelData(configuration) {
  var token = modelDataKeys.get(this);
  if (token === undefined) throw new TypeError('Invalid ModelData receiver');
  n.modelDataUpdate(token, configuration, true);
}
class IModelData {
  static POSITION = 'position';
  static NORMAL = 'normal';
  static TANGENT_SIGNED = 'tangentSigned';
  static UV = 'uv';
  static COLOR = 'color';
  constructor(token, secret) {
    if (secret !== modelDataSecret) return;
    modelDataKeys.set(this, token);
    Object.defineProperty(this, '__modelDataToken', {value:token});
    Object.defineProperties(this, {
      applyData: {value:applyModelData, enumerable:true, writable:true, configurable:true},
      replaceData: {value:replaceModelData, enumerable:true, writable:true, configurable:true}
    });
  }
  toConfigString() { return this.__modelDataToken; }
}
G.IModelData = IModelData;
function createModelData(configuration) {
  var token = n.modelDataCreate(configuration);
  if (token === undefined) return undefined;
  try { return new IModelData(token, modelDataSecret); }
  catch (error) { n.modelDataDestroy(token); throw error; }
}

function createLayer(cfg, creatorKey, workshopId) {
  var template, key;
  var model;
  var options = {};
  if (cfg !== null && typeof cfg === 'object' && modelDataKeys.has(cfg)) {
    model = modelDataKeys.get(cfg);
  } else if (typeof cfg === 'string') {
    template = cfg;
  } else if (cfg !== null && typeof cfg === 'object') {
    options = cfg;
    if (cfg.model !== undefined && cfg.model !== null) {
      var supplied = cfg.model;
      model = typeof supplied === 'number' ? supplied :
        supplied && typeof supplied.toConfigString === 'function' ? supplied.toConfigString() : undefined;
      if (typeof model !== 'number') throw new Error('Unable to create model layer');
    } else if (cfg.image !== undefined && cfg.image !== null) template = String(cfg.image);
    else if (cfg.text === undefined) throw new Error('Unable to create layer: ');
  } else {
    throw new Error('Unable to create layer: ' + String(cfg));
  }
  if (model !== undefined) {
    key = n.modelDataLayer(model, creatorKey, !!options.perspective,
      options.castshadow === undefined ? true : !!options.castshadow,
      options.solid === undefined ? true : !!options.solid, !!options.disablepropagation,
      options.reflected !== false);
    if (!key) throw new Error('Unable to create model layer');
  } else if (template !== undefined) {
    key = n.createFromTemplate(template, creatorKey, workshopId === undefined ? '' : String(workshopId));
    if (!key) throw new Error('Unable to create layer: ' + template);
  } else {
    key = n.createText(textConfig(options), creatorKey);
    if (!key) throw new Error('Unable to create text layer');
  }
  var layer = layerFor(key);
  if (template !== undefined) layer.template = template;
  applyCreateOptions(layer, options);
  return layer;
}

function destroyLayer(x) {
  var key = keyOf(x);
  var result = n.destroyLayer(key);
  if (!result[0]) return false;
  for (var i = 1; i < result.length; ++i) {
    var gone = result[i];
    layerCache.delete(gone);
    videoEndedListeners.delete(gone);
    var ids = animationIds.get(gone);
    if (ids !== undefined) {
      for (var j = 0; j < ids.length; ++j) { animationLayers.delete(ids[j]); endedListeners.delete(ids[j]); }
      animationIds.delete(gone);
    }
  }
  return true;
}

var sceneApi = {
  getCameraTransforms: function () {
    var c = n.cameraTransforms();
    return c ? {eye:new Vec3(c[0],c[1],c[2]), center:new Vec3(c[3],c[4],c[5]),
                up:new Vec3(c[6],c[7],c[8]), zoom:c[9]} : null;
  },
  setCameraTransforms: function (value) {
    if (value === null || typeof value !== 'object') return;
    var mask = 0, eye = [0,0,0], center = [0,0,0], up = [0,0,0], zoom = 1;
    if (value.eye !== undefined) { mask |= 1; eye = vec3Parts(value.eye); }
    if (value.center !== undefined) { mask |= 2; center = vec3Parts(value.center); }
    if (value.up !== undefined) { mask |= 4; up = vec3Parts(value.up); }
    if (value.zoom !== undefined) { mask |= 8; zoom = Number(value.zoom); }
    var values = eye.concat(center, up, [zoom]);
    if (!values.every(function (x) { return isFinite(x); })) return;
    n.setCameraTransforms(mask, eye[0],eye[1],eye[2],center[0],center[1],center[2],up[0],up[1],up[2],zoom);
  },
  getLayer: getLayer,
  getObject: getLayer,
  getSprite: getLayer,
  getLayerCount: function () { return n.layerCount(); },
  enumerateLayers: function () {
    var out = [];
    var count = n.layerCount();
    for (var i = 0; i < count; ++i) out.push(layerFor(n.layerNameAt(i)));
    return out;
  },
  getLayerByID: function (id) {
    // An id written as text (`String(id)`) finds the layer the number does.
    if (typeof id === 'string' && id.trim() !== '') id = Number(id);
    if (typeof id !== 'number' || !isFinite(id)) return null;
    var key = n.layerById(id);
    return key ? layerFor(key) : null;
  },
  getLayerIndex: function (x) { return n.layerIndex(keyOf(x)); },
  sortLayer: function (x, index) {
    var at = Math.floor(Number(index));
    if (!(at > 0)) at = 0;
    n.sortLayer(keyOf(x), at);
  },
  getInitialLayerConfig: function (x) {
    n.requestConfig();
    var json = n.initialConfig(keyOf(x));
    return json ? JSON.parse(json) : null;
  },
  getAnimation: sceneAnimation,
  createLayer: function (cfg) { return createLayer(cfg, '', ''); },
  createModelData: createModelData,
  destroyModelData: function (model) { n.modelDataDestroy(model); },
  destroyLayer: destroyLayer,
  on: addListener
};
// General members belong to the scene, independently of same-named user properties.
var GENERAL_BOOLS = ['bloom','clearenabled','camerafade','camerashake','cameraparallax',
                     'hdr','fogdistance','fogheight','transparentsorting','customsortorder','windenabled'];
var GENERAL_NUMBERS = ['bloomstrength','bloomthreshold','fov','nearz','farz','camerashakespeed',
                       'camerashakeamplitude','camerashakeroughness','cameraparallaxamount',
                       'cameraparallaxdelay','cameraparallaxmouseinfluence','perspectiveoverridefov','zoom',
                       'bloomhdrstrength','bloomhdrthreshold','bloomhdrscatter','bloomhdrfeather','bloomhdriterations',
                       'fogdistancestart','fogdistanceend','fogdistancestartdensity','fogdistanceenddensity',
                       'fogheightstart','fogheightend','fogheightstartdensity','fogheightenddensity',
                       'windstrength','gravitystrength'];
function generalAccessor(name, kind) {
  Object.defineProperty(sceneApi, name, {
    enumerable: true,
    get: function () {
      var value = n.sceneGeneral(name);
      if (value === undefined) return undefined;
      return kind === 'vec3' ? toVec3(value) : kind === 'bool' ? value[0] !== 0 : value[0];
    },
    set: function (value) {
      if (kind === 'vec3') {
        var a = vec3Parts(value);
        if (a.every(isFinite)) n.setSceneGeneral(name,a[0],a[1],a[2]);
      } else {
        var scalar = kind === 'bool' ? (value ? 1 : 0) : Number(value);
        if (isFinite(scalar)) n.setSceneGeneral(name,scalar);
      }
    }
  });
}
GENERAL_BOOLS.forEach(function (name) { generalAccessor(name, 'bool'); });
GENERAL_NUMBERS.forEach(function (name) { generalAccessor(name, 'number'); });
['clearcolor','ambientcolor','skylightcolor','bloomtint','fogdistancecolor','fogheightcolor',
 'winddirection','gravitydirection'].forEach(
  function (name) { generalAccessor(name, 'vec3'); });

var sceneProxy = new Proxy(sceneApi, {
  get: function (target, prop) {
    if (typeof prop !== 'string' || prop in target) return target[prop];
    return propertyFallback(prop);
  },
  set: function (target, prop, value) { target[prop] = value; return true; }
});

// ---- audio buffers --------------------------------------------------------
var audioBuffers = [];
// The generation every registered buffer holds, or -1 while one of them still waits
// for its first fill: when the analysis has produced nothing new there is nothing to do.
var audioUpToDate = -1;
// Generous for a scene whose layers each register once; each entry costs a few hundred bytes.
var MAX_AUDIO_REGISTRATIONS = 1024;
engine.registerAudioBuffers = function (resolution) {
  var size = resolution >>> 0;
  if (size !== 16 && size !== 32 && size !== 64) size = 64;
  if (audioBuffers.length >= MAX_AUDIO_REGISTRATIONS) throw new RangeError('Too many audio buffer registrations');
  n.audioMark();
  var buffer = { size: size, generation: -1, left: new Float32Array(size), right: new Float32Array(size),
                 average: new Float32Array(size) };
  audioBuffers.push(buffer);
  audioUpToDate = -1;
  tellHost();
  return { left: buffer.left, right: buffer.right, average: buffer.average };
};
function refreshAudio() {
  if (audioBuffers.length === 0) return;
  var generation = n.audioGeneration();
  if (generation === audioUpToDate) return;
  // One snapshot per resolution that needs it, however many buffers share it.
  var snapshot, snapshotSize = 0;
  for (var i = audioBuffers.length - 1; i >= 0; --i) {
    var buffer = audioBuffers[i];
    if (buffer.generation === generation) continue;
    if (snapshotSize !== buffer.size) { snapshot = n.audio(buffer.size); snapshotSize = buffer.size; }
    try {
      buffer.left.set(snapshot[0]);
      buffer.right.set(snapshot[1]);
      buffer.average.set(snapshot[2]);
      buffer.generation = generation;
    } catch (_) {
      audioBuffers.splice(i, 1);
    }
  }
  audioUpToDate = generation;
  if (audioBuffers.length === 0) tellHost();
}

// ---- user shortcuts -------------------------------------------------------
var shortcutBudget = Infinity;
engine.openUserShortcut = function (name) {
  if (typeof name !== 'string') throw new TypeError('openUserShortcut needs the name of a user shortcut property');
  var value = n.shortcutValue(name);
  if (value === undefined) throw new ReferenceError("Unknown user property '" + name + "'");
  if (shortcutBudget < 1) return;
  shortcutBudget -= 1;
  n.requestShortcut(name, value);
};
)JS";

} // namespace wallpaper::script_library
