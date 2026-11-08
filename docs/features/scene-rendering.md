# Scene rendering

How scene wallpapers are drawn and kept cheap: which renderer draws them, the
optimisation and update-only-on-change behaviour, and the renderer-internal memory
and repeated-work reductions. The settings that choose between them are on
**Settings → Performance → Advanced**, described in
[Performance](performance.md#advanced).

## Scene wallpapers

The three scene controls in **Advanced**:

| Setting | Values | Default |
| --- | --- | --- |
| Scene renderer | Compatibility / Native Metal preferred | Native Metal preferred |
| Scene render optimisation | Off / On | **On** |
| Update only when the scene changes | Off / On | Off |

### Scene renderer

Native Metal is the only scene renderer, on the desktop and on the lock screen. A scene
it cannot draw is not drawn by anything else and no effect is dropped to make it fit: it
is held without drawing, and **Drawn by** says why; what the display then shows is in
[when Native Metal cannot draw a scene](#when-native-metal-cannot-draw-a-scene).
Compatibility, the Vulkan-through-MoltenVK renderer, is gone; the `scene_renderer` key
older versions wrote is ignored.

Native Metal replaced it once it drew every scene of the local test library the way
Compatibility did (drawn by both renderers in one harness, the pictures were the same)
and cost less to run. Over 12 of those scenes at 3840×2160 and 60 FPS it took about
21% less process CPU time and 14% less GPU time in its own command buffers (one per
frame instead of three), about 3% less memory footprint, and held 60 FPS where
Compatibility dropped frames; the commands are in the
[verification log](../testing/verification-log.md).

No GPU backend is created until the scene has been parsed, so the row reports one of
three states per scene: **preparing** (no renderer yet), Native Metal drawing it, or
held with the reason it could not be drawn.

Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and rope-trail
particles, 3D models and skyboxes, perspective cameras, scene lights, ordinary
effect chains and scene post-processing, layers that read an image another layer
produced in the same frame, effects that read the previous frame (a motion-blur
trail, a fluid or ripple simulation), images the runtime replaces while the scene
plays, and BGRA or 8-bit NV12 video textures — the latter either converted once per
frame or, with
[**Direct video plane sampling**](performance.md#direct-video-plane-sampling) on,
sampled by the layer's own shader. A 10-bit video texture is converted to SDR, and one
that declares an HDR curve (PQ or HLG) is tone mapped on the way
([10-bit and HDR video textures](#10-bit-and-hdr-video-textures)). A shader that does
not translate for Metal is drawn with Wallpaper Engine's own fallback shader, as Wallpaper
Engine draws one that does not compile. A scene is held instead of drawn when a video
texture is an animated sprite sheet or names no media, a puppet shader is bound to a
mesh without bone weights, or its render graph has a step the native renderer does not
recognise.
A scene with `camerashake` on shakes its camera as Wallpaper Engine does: the eye and
what it looks at move together by `(cos t, sin 1.333t, sin t)` at
`t = camerashakespeed² × time`, its length raised to `camerashakeroughness³`, scaled
by a tenth of `camerashakeamplitude` (and in a 2D scene by a tenth of the canvas
height, in the canvas plane only). The switch and every setting follow their user
properties, and a shaking scene keeps drawing while it shakes.
`input.cursorWorldPosition` is what Wallpaper Engine hands scripts. In a scene drawn
through the 2D canvas camera it is the cursor in canvas units with `z = 0`. In a
perspective scene it is the point where the cursor's ray reaches the camera's far
plane, `farz` in front of the eye and in the same world as layer origins, so a head
script measuring the cursor from its layer's origin turns by the ray's direction (the
projection stores depth reversed, which puts the pointer's unprojection at the far
plane). The camera is read as it stood when the cursor was sampled. Layers are still hit
where the cursor ray meets their own plane, and a particle control point still follows
the cursor in canvas units.

In a 3D scene an image layer with the `perspective` flag is drawn as Wallpaper Engine
draws it: through the scene camera's orientation from 2000 units in front of its
look-at point, the lens scaled by 2000, so the look-at point keeps its framing and
everything near it appears close to orthographically at the scale the scene camera
gives that point (matrices read back from Wallpaper Engine with the eye, look-at
point and field of view varied, probes pcam-a to pcam-f).
In a 2D scene, a particle system, 3D model or image layer with the `perspective` flag
is drawn through a perspective camera seated as Wallpaper Engine seats it (an image
layer's effects still run in its own card; the pass that puts the result onto the
scene is the one seen through it, and a fullscreen layer ignores the flag). This
also applies to a composition layer's closing card, whether it copies the background
or composes children, so a cover laid on a model's face stays on it however a group
turns them. The composition's initial background sample still uses the scene camera;
Wallpaper Engine's perspective flag changes the closing card's projection, not that
sample. Camera parallax
moves a model by its depth as it moves every other layer, a model under a group by the
group's, so the cover stays on its face as the cursor moves too. Its field of view is
the scene's `perspectiveoverridefov` (95 degrees when the file leaves it out, read from
a file of any package version; `fov` belongs to scenes with a perspective projection,
which read it and ignore `perspectiveoverridefov`), its eye is
`(visible canvas height / 2) / tan(fov / 2)` in front of the canvas plane, and its near
plane is 5 units from the eye and its far plane at least 15000 away. The canvas plane
therefore maps exactly as the orthographic view maps it, and what lies off the plane,
such as a flake drifting towards the viewer, is magnified by `D / (D - z)` for a
distance `D`: a narrow field of view puts the eye far away and magnifies little, a wide
one brings it close, and nothing in front of the plane is cut before it is within 5
units of the eye. The distance follows the visible height, so a fill mode, the scene
zoom or a camera layer's zoom moves the eye and leaves the field of view alone. The eye
that those layers' shaders read as `g_EyePosition`, which a particle trail turns its
ribbon by, is a constant of the scene instead: the centre of the view, 2000 units in
front of the canvas plane, whatever distance the field of view gives the camera.

Scripts list the scene's layers through `thisScene`. `getLayer(index)`,
`getLayerCount()`, `enumerateLayers()`, `getLayerIndex()` and `sortLayer()` share
one order, the scene file's object order followed by the layers scripts made, and a
sort moves a layer in it as well as in the draw order among its siblings.
With `customsortorder` enabled, drawing uses ascending `sortorder`, keeping that
layer-list order for ties. Ordinary parent groups share the same sorted draw list;
composition layers keep their children inside their own rendering scope. This
changes drawing without changing script layer indices or inherited opacity.
In a perspective scene, `transparentsorting` takes priority when both flags are
enabled. In a canvas scene, enabling both flags disables custom sorting.
Transparent sorting draws unmarked objects in authored order, followed by marked
objects from back to front using their raw local origin and the camera direction.
Equal depths retain the preceding draw order; fullscreen and projected layers come
last. Composition children keep their private order. An object's effect passes,
snapshots and final draw move together; changing depth or camera direction reorders
prepared passes without rebuilding the graph or allocating GPU resources. Target
loads, mip generation and snapshot lifetimes are replanned only when order changes.
A layer-composite reader before its source uses the previous frame; one after the
source uses the current picture. This also applies to authored order with sorting
disabled. Self-links retain a separate snapshot. A one-shot change propagates through
its delayed readers and then returns to idle; real feedback cycles continue updating.
Shared effect targets that span multiple sorted objects keep bounded storage for
possible overlap, and ordered dependencies can require additional render batches.
Per-object temporary targets still share images when their lifetimes permit it.

A model material that samples `_rt_Reflection` requests a planar scene picture before
the ordinary scene is drawn. It uses the active camera reflected across world
`y = 0`; objects on either side of that plane remain eligible. Images, models,
particles and text participate by default; only literal `reflected: false`
excludes an authored layer. A model sampling the reflection itself is excluded;
an image sampler can consume an activated picture but cannot activate it alone.
A loaded model's active material can enable this picture while the model is hidden.
A declared reflection texture slot retains hidden models for this material check,
including their initial model and material reads. Admission is conservative: a
slot later removed as inactive can still cause this initial loading; it adds no
per-frame model loading. Unused sampler slots and shadow-only material slots do
not enable the GPU reflection phase.
The reflected view mirrors eye/right/up and uses the target's vertical projection
convention, while `g_ViewForward` keeps the ordinary camera direction. HDR display
framing, including zoom and pan, is applied before the target's projection flip.
With transparent sorting, Wallpaper Engine's globally marked objects are drawn
in both phases even when their `reflected` flag is false. Each phase keeps its
effect chains and layer-link timing, and camera or object movement updates the
prepared draws without rebuilding the graph. An image drawn directly into the
reflection target that also samples that same target reads zero in every channel,
matching the native attachment conflict; this does not create a history snapshot.

The reflection picture uses the scene raster resolution and a single-sample depth attachment
and 8-bit RGB colour even in an HDR scene. Its Metal RGBA8 backing keeps alpha
opaque. Disabling reflection quality retains the sampled picture but clears it
to the scene's background colour without allocating its depth attachment.
Scenes without an active reflection sampler
add no reflected draws or GPU target. Sampling scenes pay for that bounded
picture and a second draw of eligible content; geometry storage is shared, and
unchanged pictures return to the normal idle path.

`thisScene.createLayer` reads its configuration like an object in the scene file:
its `angles` are radians, as in `scene.json`, while a layer's `angles` member reads
and writes degrees.

`layer.name` is the name the scene file gives the layer, empty for an unnamed one,
whatever key the engine files it under, from the moment any script can reach the
layer, its own script compiling with it included. A sound object is a layer in that
order like any other, found by its id and played through the object
`enumerateLayers()` hands out; a music widget finds its tracks there by name. Only
layers the parser built are counted: an object the scene file marks statically
invisible, which nothing can show, is never built, so it has no index or id and the
count differs from the object list by those. `destroyLayer` removes the layers a
script made below the layer too.
A scene script's `init` runs once the scene is
built, so it sees all of that. Property scripts start on the scene's first tick:
every one runs `init`, in the scene's order, before any of them is told the user
properties, and that before any `update`, because a widget's options layer may call
from its first `applyUserProperties` what a later layer's `init` set up. Every tick
the scripts' `update`s then run in the scene's order too (layer order; a layer's own
scripts in the order they were made), whatever setting they sit on: a group's `scale`
script that publishes `shared.size` runs before a later layer's script reads it, as in
Wallpaper Engine, which registers each script while it parses the object list and
dispatches `update` down that list (`sub_1401A4DB0`, `sub_140177AD0`). What `init`
returns is the property's value from then on, as what `update` returns is: a drag
handle hides itself there, and a typing text starts empty.
A property script without `update` (an `init` that plays an animation, a click handler)
costs no call into the script runtime on a tick where no timer is due and no audio
buffer is registered: that call would only have run those. Its parameters and the
`engine` values are still refreshed in its place in the order, so a handler, a later
timer or another script's closure sees what it saw before, and a timer that comes due,
or one an earlier script sets for now, runs at the same point of the same tick.
`WALLPAPER_MACHINE_SCRIPT_TICK_SKIP=0` makes every tick call it, for a comparison.
`engine.isObjectValid(value)` checks a native wrapper's current lifetime. Removed
layers, their effects and removed animation layers become invalid; hiding a layer
does not destroy it. Plain objects, vectors and objects inheriting a wrapper do not
gain a native lifetime. Unbacked timeline, sheet and video objects are invalid too.

`thisScene.createModelData()` creates custom triangle geometry from Float32 vertex
buffers and optional Uint16/Uint32 index buffers, including typed-array views with
nonzero byte offsets. The vertex format selects position, normal, signed tangent,
UV and colour components in that canonical order. Coordinates are pixels in a 2D
scene and scene units in a 3D scene; triangles use counter-clockwise winding.
Materials come from registered material assets. A model can be passed directly to
`createLayer` or through its `model` option, and its instances share geometry while
keeping their own transforms, tint and opacity.

`applyData` writes previously dynamic buffers without rebuilding the graph.
Vertex and index buffers have separate update policies, and instances share one
GPU buffer set and one upload of each changed generation per frame slot.
`replaceData` can change the layout, material, buffer sizes or shape list; a null
shape removes it and a null index buffer removes that index stream. It prepares the
replacement before publishing it and is rejected during `update`; use an event
callback such as `applyUserProperties`. Explicit model bounds can cover animated
vertices without rescanning them on every upload.

Geometry the CPU rewrites (particles, text glyphs, script-made models) is copied into a
frame slot's GPU storage only as far as the draw reads it and the slot lacks it. A
particle system copies the quads it drew this frame, not the most it ever held, and its
index pattern, which only ever grows, reaches each frame slot once; indices written over
(a text relayout, `applyData`) are copied whole again. The draw reads the same bytes
either way. `WALLPAPER_MACHINE_PARTICLE_UPLOAD_DELTA=0` copies everything every frame,
for a comparison.

WE 2.8.0.42's ModelData object is a token wrapper: `engine.isObjectValid(data)`
returns false even while its model draws. Its `toConfigString()` returns the numeric
token. Destruction uses `thisScene.destroyModelData(data.toConfigString())`; the
wrapper object itself is ignored by that version's native Uint32 argument check.
A requested destruction keeps data usable while a layer still holds it, then
invalidates the token when the last layer is removed. Outgoing render graphs retain
their geometry until they have released the old draws.

`thisScene.getCameraTransforms()` returns a detached snapshot of the static camera's
`eye`, `center`, `up` and `zoom`; `setCameraTransforms()` accepts partial updates.
Camera positions in a 2D scene are relative to the canvas centre. The zoom changes
the canvas projection; a 3D scene keeps its field of view and only stores that zoom
value. As in WE, startup `init` sees the temporary camera pose; loading the authored
pose before the first `update` replaces an init-written position but keeps an
init-written zoom. Camera paths are outside this static-camera contract (see the
[WE camera API](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/CameraTransforms.html)).
The top-level `camera.paths` list loads the scene camera's legacy path files. The
last file supplies the queue of `duration` / `transforms` segments; these use
timestamped eye, centre, up and zoom values, independently of a camera layer's
animation curves. Each omitted pose vector defaults to zero; omitted zoom is 1.
Interpolation uses half the endpoint difference as its two Hermite tangents.
A frame samples the pose before advancing the clock; the clock, duration and
timestamps use WE's 32-bit float precision. Crossing a timestamp strictly advances
the key, and a cut starts the next segment without carrying overshoot. A visible
camera layer overrides this queue and pauses its clock. Canvas path zoom composes
with the scene's base zoom; handing control to a camera layer restores the original
camera basis, so path rotation, depth and zoom cannot remain on that shot. Only a
canvas with global paths retains this saved pose, and restoration runs on the
handoff frame. Hidden shots leave the global path in sole control of the canvas.
This global queue fades during each segment's first and last half-second when
`camerafade` is enabled (the default); the end ramp wins when both windows overlap
in a short segment. The closing pass blends the project's `schemecolor`, or the
fade shader's default tint `(0.315, 0.135, 0.1125)` when absent, multiplied by 0.7,
after colour correction. The separate border-clear default is black. Camera-layer paths do
not create this fade. Scenes without a global queue or with fading disabled
allocate no fade pass. Opacity updates do not rebuild the render graph, and a
fully transparent fade skips drawing.
The global `requestFeatures` remains absent: WE 2.8.0.42's runtime probe also rejects
that name, so the earlier proposed no-op would introduce an unsupported capability.

`thisScene` exposes native general settings for clearing, camera projection, shake,
parallax, sorting, lighting/fog uniforms and bloom. Flags are booleans, scalar
values are numbers and colours are detached `Vec3` values. These members take
precedence over project properties with the same name. Setters share existing
property/script drivers, so a later property change still reaches the current
consumer. `thisScene.zoom` reads the loaded zoom during `init` and shares subsequent
writes with the static-camera API; perspective zoom does not alter the projection.

Changing `bloom` creates or removes its post-process chain at the next runtime
commit. Changing HDR bloom iterations replaces the chain only when its effective
level count changes. Failed replacements retain the working chain, and retired
passes release their targets and bindings. Scalar bloom parameters and tint update
the current materials without a graph rebuild. Bloom stays before the existing
colour/LUT correction and camera fade, preserving live user options. Disabled
post-processing still draws no bloom, while the script reads its requested flag.
As in WE, changing the raw `hdr`, `fogdistance` or `fogheight` member after loading
does not recompile existing shaders or change their layer-buffer formats.

`applyGeneralSettings({ language })` is always told `en-us`: the host does not
yet pass the interface language on. `parallaxDepth` reads and writes the layer's
own value. Canvas draws use the current outermost parent's depth and origin, so
changing a root moves its descendants without replacing their raw values;
detaching a layer exposes its own depth again. Effect passes follow their logical
owner, while layer-local passes stay still. Starting or stopping effective cursor
following rebuilds the render graph.

`layer.getTransformMatrix()` answers the layer's world transform as a `Mat4`: its
own placement with every ancestor's scale and turn applied, in canvas units with y
up, so `m[12]` and `m[13]` are its x and y on the canvas (scripts compare them with
`engine.canvasSize` to tell which side of the screen a widget is on). It is the
layer's own matrix, not the one it is drawn with: a camera parallax and the identity
a layer drawn through its effects renders from are not in it. A layer anchored to an
edge or a corner (`alignment`) answers the centre of its quad, which its anchor
places, while `layer.origin` still reads the anchor. A layer that ignores its parent's
transform answers its own placement. `layer.getChildren()` answers the direct children
of the layer in scene order, `layer.rotateObjectSpace(angles)` turns the layer about its
own axes by Euler angles in radians, and `layer.getEffectCount()` and
`layer.getEffect(indexOrName)` return the layer's authored effects (built even when
authored hidden in scenes whose scripts call `getEffect`). Name lookup returns the last
matching instance; an unnamed instance stays unnamed and cannot be found by the effect
file's display title. Each effect exposes `name`, `visible`, `getMaterialCount`,
`getMaterial`, `setMaterialProperty` and `executeMaterialFunction`, without inheriting
the layer's transform setters. `getMaterial` accepts an index or the material path as written
in the effect file; an empty string selects the last pass and an unknown name returns null.
`getConstant`/`setConstant`, and properties on the material object, read and write its
constants by material name or uniform; a read answers the value the material holds (the
scene's authored value, or the shader's default until something writes it) as a number or a
`Vec2` to `Vec4` by the constant's width.
`setMaterialProperty` writes every pass declaring the alias, converting displayed degrees
to radians for `conversion: "rad2deg"`. Material constants retain floating-point storage,
including the raw float bits observed by a shader uniform declared as `int`, as in
Wallpaper Engine. `lookAt(target, up)` turns a layer toward a point in its parent's
coordinate space, keeping its origin; `lookAtYaw` first removes the direction's
component along `up` (default `(0,1,0)`). Images and models face along positive Z,
camera layers along negative Z. A direction whose squared length is at most float
epsilon leaves the current angles unchanged.
`setParent` accepts a layer, its name or its scene-list index; `null`, `undefined`
and unresolved names remove the parent. Its boolean second argument adjusts the
transform, or an attachment name/index can precede the adjustment flag. Ordinary
adjustments use WE's separate origin, rotation and axis-length rules; mirrored and
nonuniform parents can consequently change the picture's orientation. An adjusted
attachment snaps local origin and angles to zero while retaining local scale.
Parenting leaves scene-list indices unchanged. Self-parenting unparents the layer
before reporting an error; ancestor cycles are rejected before creating a cycle.
Composition nesting permits three boundaries along a branch. Reparenting counts
the destination's composition ancestors and the deepest composition branch in the
moved subtree; ordinary parents add nothing and sibling depths are not summed.
The model's `passthrough` flag marks a boundary even without a private composition
buffer; an ordinary image's effect camera does not count as one.
Exceeding this limit removes the previous parent and attachment before reporting
an error, preserving the layer's local components even when adjustment was requested.

`getAttachmentIndex` matches names exactly, including an authored empty name.
`getAttachmentMatrix`, `getAttachmentOrigin` and `getAttachmentAngles` read the
current bone pose in world space; an unknown attachment uses the layer's own
transform. Bone writes refresh attached children immediately, and reparenting
removes the previous bone binding. `transformAttachmentToTexture` returns a `Mat3`
with unit texture-space axes and a UV origin, including WE's half-texel offset and
the current source/receiver cameras and transforms. Its parallax offsets are the
values saved by their last scene-view draws: zero before the first draw, held
while hidden, and replaced with zero by a visible zero-depth draw. Shadow and
layer-local work do not replace them, and a projection query only reads them. The
ray intersection uses a normalized world ray and the native float-epsilon
parallel threshold. A singular receiver or a ray that cannot meet its plane
uses a zero local intersection. If both projected samples fail, the query still
returns a `Mat3` with zero axes and the half-texel UV origin; a target exactly on
the camera plane follows this rule as well. Unknown layers and nonpositive
receiver dimensions still return no projection. The
[WE layer reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/ILayer.html)
describes the public overloads; runtime controls establish the edge behavior above.

Script `localStorage` follows Wallpaper Engine's LocalStorageSet/Get (scenescript64.dll
`sub_181658680`/`sub_181658A80`, wallpaper64.exe `sub_14018E3A0`): the key must be a string
("LocalStorageSet key not a string."), `set` stores `JSON.stringify(value)` at the call and
`get` parses a fresh copy each time (a `Vec3` comes back as a plain `{x, y, z}`), an
undefined value deletes, and the location is `LOCATION_GLOBAL` only for the word `global`
(`LOCATION_SCREEN` is the default). A location refuses a set once its values would pass
100,000 bytes, each counted with WE's 8-byte prefix ("LocalStorageSet failed, possibly out of
memory."). `delete` answers whether the key existed, `clear()` empties both locations, and
`remove` stays as our alias. The values persist per wallpaper in
`<support>/SceneStorage/<wallpaper id>/global.json` and `screen-<display key>.json` (the key is
`uuid-<UUID>`, else `edid-<vendor>-<model>-<serial>`, else `display-<id>`; a mirror uses its own
display's key). A desktop scene writes at most every 2 s (temporary file, then rename, merging
only the keys it changed, under one lock per file), and once more when its scripts are torn
down. The preview window reads the same files and never writes; the lock screen reads the copy
published with its revision, taken at publish time, and never writes either. Resetting
properties keeps the storage; deleting the wallpaper deletes its folder; backups include it.

A layer's `origin`, `scale` and `angles`, and an image layer's `color`, can be keyed on
a timeline (`animation`: curves `c0` to `c2` and `options`), and all four play the
same way. Absolute keys are the value; `relative` keys offset the authored one (before
the first key of a relative curve the offset is zero), and a curve the author did not
key keeps the authored value. `loop` wraps the timeline's one clock, which a short
curve holds its last key until, unless the timeline sets `wraploop`: then every curve
is cut at the timeline's `length` and closed there on its first key's value, so a loop
returns to where it began instead of holding and jumping back (this holds for every
animated setting, shader constants and light intensity included); `single` stops at the last key and then stops asking
for frames, so a scene whose only motion it was can go idle. A timeline with
`startpaused` shows its first frame from the first frame of the scene, not the
authored value, until a script plays it, and `getAnimation(name)` finds it by its
`name`. The script of a setting that keeps its timeline beside it (a shader constant)
gets that timeline from `thisObject.getAnimation()` with no name, as Wallpaper
Engine's `IThisPropertyObject` does; it got the layer's first unnamed timeline, which
on a layer that also slides is its origin's, so a cross-fade a new cover restarts
restarted the slide and never faded. When that script exports no `update` (an `init`
or an event handler that only calls `play()`), the timeline stays the constant's value
and the script holds its clock: Wallpaper Engine plays it to the end, and such a script
was dropped, which left a start-paused cover cross-fade on its first key and the
previous cover over the current one. Settings the editor keyed together (`options.parent`: an origin and the angles
that turn with it) are one animation on the first one's clock, so playing or holding
it moves them all. A script or a property bound to the same setting is its only
writer. A colour timeline tints the layer's own material and each of its effect passes
and keeps the layer's alpha; in a scene that renders HDR the layer's brightness
multiplies the timeline's colour as it does the authored or bound one. Not followed: the `mirror` play mode (it plays as
`single`), a timeline on `alpha` being on its parent's clock (it keeps a
clock of its own), and the colour timeline of a text layer or a light
([known limitations](../testing/renderer.md#known-limitations)).

A scene with no player hears no media event, as in Wallpaper Engine: its scripts keep
the state their `init` left them in until a player reports
([media integration](media-integration.md#scene-wallpapers)).

An image layer's `color` that a script decides is that script's value, every frame, as
it is in Wallpaper Engine and on a text layer: the media widgets' colour script returns
black until a cover's colour arrives, so a widget's solid layer is black while nothing
plays, and tints with the cover once one does. The layer holds the scene file's value
until its script has run, on the first tick, and the value reaches the layer's own
material, every effect pass and a compose layer's passthrough, as a colour bound to a
user property does (alpha stays with the alpha bindings). A script whose `update()`
returns nothing leaves the colour as it is, and one that writes `thisLayer.color` sets
it from then on: the next `update(value)` is given it, and a value `update()` returns
replaces it, as for `visible` and `origin`. A write to the colour of a layer that has no
property or script bound to it reaches only the layer's own material, not its effect
passes. A scripted colour costs one script call a frame, as a text layer's does, and
no pass or memory. It is also a script like any other, so a scene whose only script is
an image layer's colour no longer goes idle (it did, while the colour script was never
created); a scene with other scripts did not idle before either.

A number a script hands back for a vector property (a layer's `origin`, `scale` or
`angles`, a colour, a two- to four-component shader constant) is that number on every
component, as a single authored number is, and the property stays a vector, so the next
`update(value)` can read `value.x` again. A hover zoom whose `update(value)` returns
`value.x + (target - value.x) * speed` for `scale` therefore scales evenly; kept as a
bare number, its next call read `.x` off that number and the layer's scale, and with it
its position, went NaN from the second frame, so the layer was never drawn (a clock
widget on by default). A number written to `thisLayer.color` or
`thisLayer.parallaxDepth` now fills every component too, where it was ignored;
`origin`, `scale` and `angles` already took one on every axis. Wallpaper Engine's own
`Vec3` and `Vec2` fill every component from a single number; that its host converts a
returned number the same way is inferred from a default-on widget written to rely on
it, not compared against its frames.

A script that writes `thisLayer.alpha` on a layer whose alpha no timeline, script or
user property owns sets the layer's opacity as the editor's `alpha` does. The layer's
own pass applies it, once, on any layer but a puppet with bones under effects, which
applies it twice. The write reaches that material, the `g_Color4` and `g_Alpha`
each effect pass of the layer is given, as an authored alpha leaves them, and a compose
layer's passthrough, which is where its alpha lands. An effect's own alpha is not the
layer's: Wallpaper Engine's Opacity keeps the `g_UserAlpha` its `alpha` sets, or, when
it sets none, the layer's authored alpha it starts from, so the two multiply, whether
the layer's alpha is authored, bound to a property, keyed on a timeline or written by
a script. A script that reads `thisLayer.alpha` back reads what it wrote, so a fade can
step from it. The media widgets that fade themselves out while nothing plays rely on
it: the write once reached only the pass built last, so a layer under an effect chain
stayed on screen at its authored alpha. The passes that blend the layer onto the
screen, and the passthrough a chain falls back on when a script has switched all its
effects off, draw with white, because the layer's own pass has applied its colour and
alpha already; on a compose layer, whose own pass reads no colour, that passthrough
carries them. A puppet with bones under effects is drawn over its texture sheet by the
layer's own pass and again by the skinned pass its chain ends in, and both carry the
layer's colour and alpha, as an authored alpha always did and a script's write now
does ([known limitations](../testing/renderer.md#known-limitations)).

A scene follows the cursor anywhere on its display, but, as in Wallpaper Engine, a
mouse press counts only where it lands on the desktop: the wallpaper, Finder's icons or
a desktop widget. A click in another app's window, in the menu bar or the Dock, or in
this app's own windows is not a click on the wallpaper, so neither scripts
(`cursorDown`, `cursorClick`, `cursorUp`) nor effects that react to a held button
(cursor ripples, fluid simulations) see it, or its release, even when the pointer is
dragged onto the desktop before the button is let go. A press the wallpaper did get is
always released, wherever the pointer ends up. As in Wallpaper Engine, the press brings
`cursorDown` and the release `cursorUp`, then `cursorClick` only when the pointer is still
over the layer that was pressed: letting go elsewhere cancels the click.

Cursor events include a detached `localPosition` Vec3 in layer pixels, measured
from the image's top-left with y down and z zero. Parent transforms, mirrored
scales and the current canvas parallax offset affect that position and the hit
test together. Leaving the layer keeps the current coordinates outside its
rectangle; they are not clamped to its edges. `worldPosition` remains a separate
world-space vector.

An image puppet's button events can also supply `hitBox`, the name of the
intersected bone box, or the bone's decimal index when its name is empty. Picking
uses the published bone pose and the reverse order of the model's box table; it
does not evaluate animation again. Ordinary hover, a miss, a plain image and a
3D model omit that member. An exported function named `cursorHitTest` does not
override geometry: Wallpaper Engine 2.8.0.42 retains the name in its script table
but does not dispatch it in the cursor walk. Solid-layer and propagation rules
remain in force.

The first frame's cursor events wait for property-script `init` and initial
notices. That frame's sampled button edges are delivered once, before updates;
its clock and pose still advance only once. Replacing the scene discards that
pending input. A newly registered script does not consume its first enter before
it has started.

Both scene renderers share video decoder selection. On macOS, an eligible FFmpeg
default is kept; a software-only default does not rule out another decoder for
the same codec that supports VideoToolbox, as with dav1d and native AV1. A codec
with no VideoToolbox-capable decoder is still rejected, and the first frame must
still decode successfully. This does not enable software-only decoders.


An effect that composes its layer over the screen (refraction among them) reads
that screen the right way up on both renderers. The shader compiler defines `HLSL`
and `HLSL_SM40` as Wallpaper Engine does, so the Direct3D branches of an effect's own
shaders are the ones compiled: the flipped screen coordinate of the compositing
pass, a brace-listed sample kernel, and a light falloff that stays defined beyond a
light's radius.

A vertex shader may assign to its own inputs, as Wallpaper Engine's HLSL lets it (the
Shadow effect's default `a_TexCoord *= atFactor`, a factor of 1 at its default
settings). The input keeps reading the mesh attribute it names on both renderers, so
a text or image layer under such an effect is drawn at its own texture coordinates
and not at the vertex position's, which left a text layer empty and an image layer
sampled at the wrong place.

A model's tangent reaches the shader under the name Wallpaper Engine's model shaders
declare it, `a_Tangent4` (`generic`, `generic2`, `generic3`, `generic4`,
`genericimage3`, `genericimage4`, `chroma4`, `foliage4`, `fur4`; the two `genericimage`
shaders read it for a lit, skinned puppet layer), so a lit, normal-mapped model builds
its tangent frame from the mesh's own tangent and handedness. The model parser used
to name it `a_Tangent`, which left the shader's input unbound: it read the first four
floats of the vertex (the position, and the normal's x in a model without bones), the
perturbed normal came out far longer than one, and a lit roof showed hard-edged
highlight patches and white sparkles where Wallpaper Engine shows a smooth specular
pool.

An effect may mask with an `int` it fills from `step` and multiply a boolean into
(`int bar = step(y, h); bar *= isLeftChannel;`), as Wallpaper Engine's HLSL promotes
the boolean to a number. The shader compiler makes that `int` a float, since `step`
returns one, and every later repair reads it as a float: the boolean becomes `1.0` or
`0.0`, an `int` taken from it is cast, an `if`, `while` or `?:` condition on it
compares with `0.0`, and a `%` on it is a float remainder. The circle and centre
shapes of the workshop Simple Audio Bars effect (without anti-aliasing) need this;
without it the effect failed to compile and its layers lost the bars whatever
played. A number as an operand of `!`, `&&` or `||` is not converted, whether a mask
or not ([Known limitations](../testing/renderer.md#known-limitations)).

Scene lighting works as in Wallpaper Engine, on both renderers. A lit shader
(`genericimage4`, `generic4`, the particle, rope, foliage and fluid shaders) asks for
`#require LightingV1`; the shader compiler writes in a `PerformLighting_V1` with one
uniform array per light kind, sized by the scene's `general.lightconfig`, and calls
the author's own `ComputePBRLightShadow` for every light. Point (`lpoint`), spot
(`lspot`), tube (`ltube`) and directional (`ldirectional`) lights fill those arrays
every frame: colour times intensity with the radius, the world position with the
exponent, a spot's cone cosines and the light's own x axis as the way a spot or
directional light points, a tube's far end its control point carried by the light's
transform. The older `point` light still fills the four packed legacy lights
(`g_LightsPosition`, `g_LightsColorPremultiplied`, `g_LightsColorRadius`): every
light object, hidden or of the newer kinds, takes a slot in file order, and a fifth
light shares slot 0, the later one winning, as in Wallpaper Engine. A light is a node like any layer:
it follows its parent, and its visibility, transform, colour, intensity, radius and
exponent follow user properties, scripts and timelines; a hidden light, or one under
a hidden layer, lights nothing. Each kind lights at most as many lights as the config
names. As in Wallpaper Engine the lights are sorted every frame, of a kind those
casting shadows or using a cookie first, then nearest along the camera's forward axis
(by their own origin), and each kind's array holds its `lightconfig` subsets ahead of
its plain lights: a spot's `spotshadowcookie`, `spotcookie` and `spotshadow` slots, a
point or directional light's shadow slots (`pointshadow`, `directionalshadow`, kept
only while the Shadows setting is on; with it off `spotshadowcookie` counts as
cookies). Shadow subsets sample the model-shadow depth atlas. Cookie spots project the
selected cookie image instead of applying the ordinary inner/outer-cone attenuation.
Each light loads its `cookie` texture, defaulting to `cookie/flashlight1`; as in
Wallpaper Engine, every cookie spot samples the same texture, selected by the last
visible cookie spot inside the packed light budget. Visibility, movement and budget
changes update that selection. The alias reads transparent black outside the image.
Cookie projections also work with shadows disabled or without a caster, and add no
shadow camera, atlas or render pass. With neither a prepared cookie sampler nor a
projection reader, a scene performs no draw-time cookie packing or GPU image import.
A projection-only reader updates its matrices without importing cookie images.
For a texture consumer, candidate images load
once during graph preparation, including a cookie-owning light whose public type
may later switch to spot; selection changes never read files inside a draw.
After simulation and light updates, the renderer packs each light family lazily for the
current draw and shares its exact arrays across lit passes and static-reuse checks.
The retained buffers are bounded by the scene's light budgets; the next draw always
rebuilds their contents, so animation, scripts, visibility and parent transforms stay
live. A reflection phase whose camera points another way repacks the newer light
arrays to preserve their camera-dependent order. Draws with no light readers do no
packing. This removes repeated light sorting and allocation without changing quality,
frame cadence or the light budget; battery savings have not been measured.
A lit pass reuses its last image only while
the lights it reads are unchanged. A lit or reflective image layer with effects is
drawn unlit into its card and lit once, by a closing `PRELIGHTING` pass drawn where
the layer sits. As in Wallpaper Engine, whose image mesh spans the picture's pixels
while the layer's world matrix carries no size, that pass measures lights against the
card squeezed to its texture's size around the layer's origin (`g_AltModelMatrix` is
the layer's world matrix scaled by picture / card size); that pass also takes the scene's fog and the layer's colour blend, as in
Wallpaper Engine. `g_NormalModelMatrix` is each draw's own rotation
and `g_LightSkylightColor` the scene's skylight; `g_Texture<N>Texel` is the step of
the texture a slot samples, as for Wallpaper Engine's morph-target and downsample
shaders. Distance and height fog
(`fogdistance`, `fogheight` with their start, end, densities and colours, Wallpaper
Engine's defaults where they are left out) are compiled into every pass whose `FOG`
combo is on, the material's own or its shader's default, and applied by the
author's `common_fog.h`. A layer that draws through effects is first drawn into a card
of its own, from an ortho camera and with no transform, where a point's distance from
the eye is its place in the card and not the layer's, so fog compiled into that pass
dims the card toward its edge. Wallpaper Engine fogs such a layer where it sits, in the
pass that composites it onto the scene, and so does this renderer: when the layer's own
material takes fog, the layer's first pass and its effects get none, and the chain ends
in Wallpaper Engine's fogging passthrough (`effectpassthrough_4`, the generic image
shader), drawn at the layer's model matrix with the scene's fog, which dims the layer
evenly by its real distance and height. It costs one layer-sized pass per such layer in
a fogged scene, and the second ping-pong target of a chain that was one effect long. On
the one local fogged scene, a 512 x 512 effect layer, a frame went from 9 to 10 passes
and took 1,064,960 bytes (1 MB) more target memory. The CPU time to encode a frame did
not change measurably: 16 interleaved runs of each build gave a median of 0.35 ms for
both, the runs spreading over 0.19-0.45 ms, where one pass of the frame takes about
0.02-0.04 ms to encode. GPU time was not isolated. A scene without fog, and a layer that
draws without effects, are unchanged. The pass is added whenever the layer's own
material takes fog, whether or not the layer's own pass is drawn, so a layer an effect
generates (`copybackground` off) is fogged too, where only an effect pass of its own
with a `FOG` combo fogged it before. That is read from Wallpaper Engine's setup of the
composite, which does not look at `copybackground`, and not seen in a frame: the one
local fogged scene has no such layer. Compose, fullscreen and puppet layers, a layer
that blends onto the screen by colour blend mode, text layers, and a layer whose
material takes no fog keep what they drew.

Height fog is read whenever its JSON fields are present, including older package
containers. Ambient/skylight colours and the height- and distance-fog colours and
ranges that a script or a user property drives are followed every frame, as Wallpaper
Engine evaluates every `general` setting: the shared uniform (`g_LightAmbientColor`,
`g_LightSkylightColor`, `g_FogHeightColor`/`Params`, `g_FogDistanceColor`/`Params`) is
recomputed on a tick in which one of its inputs changed and written into every
material that declares it (`SceneRuntimeContext::RegisterSceneUniform`), so a script
that returns a new ambient colour or a live property edit shows without a reload. A
scene whose settings are literal registers nothing and pays nothing per frame.
Direct `thisScene` colour/range/density setters update the same uniforms; static
overrides collect recipients once on demand, without adding a per-frame polling
binding. Fog shader variants stay as loaded when a script changes the raw
`fogheight` or `fogdistance` flag. SceneScript `rotateObjectSpace(Vec3)` composes a
radians Euler increment around the layer's local axes; the `angles` property
continues to read and write degrees.

An ordinary `sampler2D` can read a 2D depth target's depth channel without a
comparison sampler. The renderer binds that depth texture directly, without a
copy or conversion pass; a 2D colour image still cannot stand in for a comparison
or 3D texture declaration.

Point, spot and directional lights cast model shadows through a depth atlas, gated by
the Shadows quality setting and the visible lights and model casters. Casters write
the atlas with the view's constant depth offset plus a clamped slope-scaled depth bias,
so a surface lit at a grazing angle does not shadow itself in stripes. Spot-cookie
sampling uses the existing lighting pass. Point and spot lights with `castvolumetrics`
draw their volume after the scene and before its post-processing, using the light's
colour, intensity, radius, density and volumetric exponent. Spot cookies and shadow
maps modulate those shafts. A scene-depth reader retains its forward-depth convention
while the shadow atlas uses reversed depth. HDR display framing uses the same raster
projection to draw and reconstruct the light volume. The camera can enter or leave a volume without rebuilding
the graph; light kind, cookie mode, casting and visibility changes rebuild the utility
materials and release the old geometry and targets. A failed utility-material load
rolls back its target declarations and shader-updater registrations.

Volumetrics Off and scenes without an active casting point or spot allocate no volume
targets or draw volume passes. Low and Medium accumulate at one eighth of the render
width and height and apply two blur passes; High and Ultra use one quarter without
those blur passes. Each active light draws its exit depth and either its entry surface
or the fullscreen entry variant. Meshes are retained until the light topology changes,
and a static volume requests no continuous uniform clock. Scene depth is sampled from
the existing depth attachment; MSAA resolves it to one additional full-resolution
32-bit depth image in the same encoder. An ordinary scene
clear also clears that depth when the last occluder is hidden, and cached readers follow
the depth writers' visibility and inputs. Scenes with no depth writers use one far-depth
texel. **Quality in force** reports the selected level only while a volume is active.
Shadow edge filtering is not a pixel-identical match to the reference probes
([known limitations](../testing/renderer.md#known-limitations)).
Both renderers apply a material's depth state and cull mode the same way: a
pass into a depth-attached target (a model, a skybox, a scene with a perspective
camera) takes its material's depth test and depth write, and every other pass draws
in painter's order. Every pass takes its material's cull mode, as Wallpaper Engine
does on a 2D canvas too, with counter-clockwise front faces: a layer's card faces the
camera as authored, whether its shader writes clip coordinates or uses the
model-view-projection matrix, and a `cullmode normal` card mirrored in x (by its
vertices or by a negative layer scale) is culled. The reflected phase keeps the same
front faces, so the mirrored camera reverses which side of a culled card or model is
drawn, as in Wallpaper Engine's reflection controls. A pass
reads these words as Wallpaper Engine does: only `enabled` turns on a depth test or a
depth write and only `nocull` turns culling off, so any other value (`less`,
`inverted`) means no depth test, no depth write or back faces culled; there is no
depth compare to choose. A draw that blends (`translucent`, `additive`) never writes
depth, whatever its material says, and still tests it: Wallpaper Engine's device
chooses its depth state from the material's two words and the draw's blend mode
(`sub_140099F60`), and its frames of a depth probe agree (a nearer translucent card
authored with both enabled, at any alpha, does not hide a farther card drawn after
it; a nearer `normal` one does). So a translucent glare or HUD card drawn before the
labels behind it no longer hides them (3662790108). A `normal` (which `disabled` also
reads as), `alphatocoverage` or unblended draw writes depth as authored, and a pass
that does not depth-test writes none. The last pass of an image layer's effects, the
one that puts the layer into the scene, is drawn with the layer's own blending, depth
test and depth write, not the ones its effect pass authored: Wallpaper Engine's image
layer copies all three from its material onto that pass. A translucent glare layer
authored `depthtest` enabled is hidden by a nearer model whether or not an effect runs
over it, a `normal` layer authored `depthwrite` hides what is drawn behind it
afterwards, and the editor's depth-testing solid and compose layers, image layers too,
test their effects' result against the scene. Text in a perspective scene is depth-tested unless it says `depthtest`
`disabled`, using the depth font material and a depth-tested closing effect pass.
Text in an ortho scene is not depth-tested
([known limitations](../testing/renderer.md#known-limitations)). A target the frame
reads before it writes it keeps its own image from one frame to the next on both
renderers, so the reader sees exactly the previous frame, and transparent black on
the first frame unless the effect supplies a clear colour; a scene with such a loop
is never called still while it runs. An effect's own buffers are made the way
Wallpaper Engine makes them (`sub_1401E7170`, `sub_1401EA500`): each `fbos` entry needs a
`name` and a `format`, or it is left out; the format is its row of the texture format table
(`r8` and `rg88` are one- and two-channel 8-bit targets, `r16f`/`rg1616f`/`rgba16161616f`
float ones, so a fluid simulation's velocity and pressure keep their sign), the two
back-buffer formats follow the scene, and a name the table does not have, `r32f` included,
is 8-bit RGBA; a buffer with its own `width`/`height` or a `fit` has that size, its longer
side shrunk to the `fit` with its aspect kept, before `scale`. A `unique` buffer belongs to
its effect; any other is one target for every effect of the scene that names it at the same
size and scale (by name alone in a passthrough layer), as in Wallpaper Engine; text layers
keep their buffers their own because they follow the card. `uvs: "repeat"` samples the buffer
wrapped. A `clear` colour (`"r g b a"`, or an empty string for black) clears the buffer to it
whenever it is made or resized. For a shared buffer, the last declaration with an explicit
clear supplies that colour; a later declaration without one keeps it. `conditions` on a buffer, a pass or a bind keep it only when
every element of the array holds against the effect instance's own `combos` (each key equal,
or `ge`/`gt`/`le`/`lt` against a `value`; a missing combo reads 0); a dropped pass moves the
later ones up. The runtime retains the effect's `functions` with action `clear` and can
clear the effect's first N buffers, N the names that
resolved, to their own `clear` colours before the next frame (`sub_1401EE3A0`: the counter,
not the listed names, picks the buffers). SceneScript invokes these actions with
`executeMaterialFunction(name)`. An effect's `swap` command exchanges two
buffers where it stands among the effect's passes, so a simulation carries its state from one frame to the
next; when the effect draws into the second buffer before reading it again, one copy
into the first is the whole exchange, otherwise it goes through a temporary buffer.
A layer's colour blend
mode mixes it with the screen behind it through Wallpaper Engine's passthrough
material, the layer's last step; the passthrough takes the layer as its first pass
drew it, colour and alpha included, and does not apply them again. Mode 31 ("add")
has no passthrough: an image layer, or its last effect, is drawn with additive blending
straight onto the scene, so it costs neither the extra pass nor a copy of the screen (a
text layer that goes through a visible effect is the exception, see below). Translating to the
Metal shading language
preserves the shader's own `inverse` functions, as Wallpaper Engine's perspective include defines them, so
the stock perspective, reflection, water, light-shaft and cursor-ripple effects
translate. A step that samples an image nothing in the scene produces (a layer
texture whose layer draws no composite) is skipped on Native Metal exactly as
Compatibility skips it, instead of sending the scene to Compatibility; an image that
exists and does not load still does.

Puppets and rope geometry behave the same on both renderers. A puppet is deformed
by its author's own skinning shader, and its pose comes from the one animation
system the scene already has (animation layers, their play, pause, stop, rate,
blend, visibility, additive mode and `blendin`/`blendout` fades over `blendtime`,
and any script or user property driving them); the renderer only uploads the
resulting bone matrices. A script can add layers to the stack with
`createAnimationLayer` (an animation name, or a config object naming the animation's id, with
the same keys an authored layer has plus `autosort`, which goes below the additive layers on
top, and `index`; a made layer fades in and, when its clip plays once, out, unless told
otherwise) and take them off with `destroyAnimationLayer` (a name, every layer with it; an
index; or the layer object); the layers above move down and their script objects keep
following them. `playSingleAnimation` makes a layer that plays one cycle of its clip, calls
its `addEndedCallback` listeners and is removed after those listeners run. Ordinary looping
and mirrored layers call the same listeners at every wrap or turn and keep playing
(`0x1401FDF90`). Both authored and script-created repeating layers start with `blendout`
cleared (`sub_1401FCC20`); a script can enable it later. The layers are composed as Wallpaper Engine composes them:
in stack order over the reference pose, a whole layer replacing what is below it, a
partial one lerped toward (rotations as a normalised lerp), an additive one adding its
weighted offset from the reference, and a bone outside a clip keeping the value below
it. A puppet whose first mesh is flagged for per-bone alpha (flag-word bit 4) is drawn with
`SKINNING_ALPHA`: each bone's alpha starts at 1 every frame and every layer pulls it toward its
clip's per-bone curve by its weight, and the author's shader fades the bone's vertices by it
(`g_BonesAlpha`). A clip can play another clip's frames from a start frame on (an MDLA clip
record). A 3D model with `rootmotion` set whose clip carries root-motion bits keeps its root bone
where the clip starts on the locked axes, takes the clip's turn about y out of the root, and moves
the model layer itself by what the root would have moved: its origin by the model's world matrix
times the distance, its yaw by the turn, weighted by the layer and by what the layers above leave of
it, continuing across a loop. Every puppet's pose is evaluated before the frame's scripts run, so a
script reads the moved origin and this frame's bones: the bone methods (`getBoneTransform`,
`setBoneTransform`, the local transform, origin and angle calls, bone index and parent) read and
write the evaluated bones, a world write moving that bone and a local write moving the bones below
it too, and a write lasts until the next frame's pose. A bone whose simulation settings (the JSON
after its matrix) turn on rotation or translation with a spring or rigid response is simulated as
Wallpaper Engine 2.8.0.42's puppet composer does, in bone order right after the bone's animated
pose: in the layer's world space, starting from where the bone was drawn last frame, its tip keeps
where it was by the inertia setting, a spring pulls the turn and the offset back to the animated pose,
friction damps the velocity, held axes, angle limits, the turn rate limit and the offset cap apply, and
gravity pulls when it is on; the bone's model matrix takes the result and the bones below follow.
`applyBonePhysicsImpulse` adds to a simulating bone's velocity (world units a second) and turns its
angular velocity by degrees; `resetBonePhysicsSimulation` puts its state back at rest. A script that
drags a bone with `setBoneTransform` leaves it where the simulation starts next frame, so it springs
back when released. A puppet without a simulating bone keeps no spring or rigid-body state.
Visual attachments read the completed pose after the runtime has supplied the layer's
current world transform; registering a child or beginning its frame does not advance
the parent's simulation early. Standalone rendering without a runtime supplies that
world transform from the child's parent before stepping the puppet.

An image puppet's explicit MDLS inverse-kinematics chain is solved at its stored root, after that bone's
animation and simulation. Its position and pole targets follow the same absolute and additive
animation-layer mixing as bones, including source-clip offsets; the driven bones keep the
solution and their other children follow it. The solver uses the stored bone lengths and
neighbour directions, makes at most ten backward/forward sweeps and stops earlier when each
goal's squared distance is at most 0.1. A long chain can therefore stop short of a reachable
target on one frame. `ikce` applies the planar angle limits `ikrminl`/`ikrmaxl` in radians;
these fields do not set segment lengths. Rope links keep Verlet points per instance in world
space, constrain their lengths in model space, and honour the free endpoint and stretch flags.
Their friction is `tf`; `ikrd` controls how the endpoint's orientation follows a distant target.
Chain data and working storage are prepared once. Three-dimensional `model` layers keep
forward kinematics, as Wallpaper Engine's separate model composer does; they allocate no IK
instance state. A puppet without a usable chain or blend-rule consumer allocates no link/IK instance state.
An IK position target can also follow a source bone through an MDLS blend rule.
Flag 1 blends its position alone; flag 0 blends translation, scale and Euler rotation.
Flag 2 projects the target onto the source bone's local X line before blending;
it keeps the target's orientation and scale and takes precedence over flag 1.
This axis rule runs once for each stored segment endpoint matching the target's
owner. The source axis is normalized, so its scale does not multiply the displacement.
The rule names its MDLA weight curve explicitly. Curves use the source clip's frame
offset, ordinary animation layers blend in order, additive layers add their weighted
sample, and the disabled-curve bit keeps the value below. Rules run in the chain's
stored target order before the solve, using the source bone's available model pose.
Only consumed curve indices and their instance weights are prepared; a puppet without
these rules adds no curve-sampling traversal. A constant-weight 0/1 image-puppet
control shows the position-linked limb following its source in Wallpaper Engine and
the native renderer; the zero-weight native picture is unchanged by this support.
A separate axis-rule control shows the limb moving toward the source's X line in
both renderers, with zero-weight native output unchanged. The control retains
existing pose and placement differences; it does not establish general skeletal parity.
A rule with `0x10000` instead uses the source's X axis as a grounding-plane normal.
Its positive displacement is bounded by the chain reach remaining beyond the source;
a source beyond that reach, or a target behind the plane, contributes its position
without replacing the target's rotation and scale. This flag takes precedence over
the ordinary target modes. After the first backward sweep only, joints on the wrong
side of the source normal are reflected before the forward sweep. That correction
uses the rule flag even when its animated blend weight is zero, and has the native
32-attempt bound.

Rules attached to ordinary non-IK image-puppet bones blend their full world transform,
regardless of the IK-only mode bits. They run after the animated parent transform and
before bone simulation and descendants. Earlier source bones supply the current pose;
later source bones supply that instance's previously published pose. Rule and weight
storage is sparse, prepared once, and shared curve sampling retains the same clip,
mask and additive-layer rules. Ordinary-only consumers allocate no per-bone solver
arrays and refresh only the source poses their rules actually read. The separate model
composition remains FK. Five reference controls agree at the observed world positions
of five bones to within 0.0002 canvas units. A consecutive-frame control also confirms
the native alternating first-sweep solution at zero blend; zero blend does not disable
that high-bit rule. The ordinary zero-weight and bit-off pictures remain unchanged.
These bounded controls do not establish general skeletal frame parity; broader
pose/placement differences remain in the
[known limitations](../testing/renderer.md#known-limitations).

Image-rope links consume the scene's `gravitydirection`, `gravitystrength`,
`windenabled`, `winddirection` and `windstrength`, including property bindings and
SceneScript writes. With the end bone's `ge` flag, gravity is the raw scene vector
times its strength and that bone's mass. Wind is independent of the bone's mass:
it takes the positive part of Wallpaper Engine's 2D simplex noise at scene time
and `worldX / canvasWidth * 10`, then multiplies the raw wind vector and strength.
Directions retain their magnitude; the layer's turn and scale do not rotate or
scale these world-space forces. Verlet integration adds the resulting acceleration
times squared seconds. The ordinary spring/rigid bone path retains its authored
`gd`, and particle movement operators retain their own gravity settings.

The force state is shared by a scene's rope consumers and allocated only when a
rope is registered. Static/default settings add no driver, image rasterization or
render pass, and a scene without a force consumer gains no continuous work.
Repeated equal assignments keep the existing state without rebuilding the graph.
As with other script bone controls, a force-value script runs after the current
pose and affects the following simulation step.

Morph targets (`MDMP`, blend shapes) reach the vertex shader through an immutable
`RGBA16Snorm` data texture. Image puppets use their first mesh's four-wide position index
and position/alpha texels; 3D models use a separate texture per mesh with tightly packed
position deltas and, when present, normal deltas. The visible material samples slot 5 and
a model's shadow caster samples slot 1. MDLA version 4 and later stores morph curves per
mesh, sampled with the animation layer's interpolation and source-clip offset. These
curves are independent of the puppet's texture-channel/albedo blending.
Models without bones retain their base geometry even when the material explicitly enables
`MORPHING`, matching the controlled Wallpaper Engine model probe; they allocate no morph
state or delta texture.

`getBlendShapeIndex` resolves a name in the first mesh; `getBlendShapeWeight` and
`setBlendShapeWeight` address those shapes by index or name. Names match ASCII case-insensitively, with the first
duplicate winning; finite script weights keep their sign and are not clamped to 0–1.
An unknown shape's weight is the number zero, not a null value.
Writes survive recomposition at the same scene time and the next animation evaluation
replaces them. A draw takes the first eleven active shapes in index order, then sorts
those entries by signed weight. A complete zero-valued animation layer clears a shape's
active flag without overwriting its earlier weight: a getter can still return that value
while the shader no longer uses it. Image bone-distance modifiers use the inverse of the
current model-space bone, including script bone writes.

Morph textures are registered once per model resource and mesh in a scene and use the
ordinary immutable-image cache across displays. The cache compares source bytes when a
new scene loads, so replacing a model at the same path cannot reuse stale deltas. Playback
updates fixed-size uniform storage; it neither rewrites vertices on the CPU nor uploads
the delta texture every frame. Puppets without shapes keep no morph instance storage.
The remaining scope and reference-frame gaps are listed under
[known limitations](../testing/renderer.md#known-limitations).

A model's vertices are read with Wallpaper Engine's 26-bit vertex table, every stored
stream (second and further texture-coordinate sets, colour, the four-wide morph position, the
second position) reaches the shader under its attribute name, and a shader input reading a
narrower name of a texture-coordinate set (`a_TexCoord` of a lightmap model's
`a_TexCoordVec4`) reads the same bytes. Rope and rope-trail geometry is generated
once by the shared particle simulation, with the rope renderers' *UV scale*, scrolling
and smoothing. A particle's sprite, rope or trail is sized as authored and drawn
through its layer's model matrix, so a particle layer scaled up draws its
particles larger by the same factor, in a 2D canvas as in 3D, as Wallpaper
Engine's particle shader does. A `worldspace` file is the exception: Wallpaper
Engine draws it through none of its layer's matrix, so its particles are in scene
units from the layer's origin and keep the size they were authored with, whatever
the layer's scale or turn (a rope on a layer stretched to 24 times its height is as
wide as the file wrote it, not 24 times as wide). The layer's turn and scale reach
such a system once, at a particle's birth: in the offset an emitter or a control
point places it at and in the velocity the velocity initializers give it, so a layer
stretched along x spreads and launches its particles along x; the emitter's origin
is added after, unscaled, and every force acts in scene units. A control point
pinned to the world (flag 2, never the first) keeps the matrix it was authored
with, so an emitter on it is neither spread nor launched by the layer. A
layer-space file's emitter origin is in the layer's space too and scales with the
layer; only a `worldspace` file adds it unscaled, in world units. A child system's
origin is its offset inside its parent system and scales
the same way, through the parent's matrix, wherever the parent is not `worldspace`:
a row of static children 50 units apart under a layer scaled 1.5 stands 75 apart.
Under a `worldspace` parent, whose particles are in world units, a child hangs at
its authored offset unscaled, and so does a static child whose own file is
`worldspace`, which no reference settles. A puppet model whose animation block the
model parser cannot read is drawn in its bind pose on both, with a log line when it
loads. A puppet's texture channel (a mesh whose material draws with
`puppettexturechannels`, such as an eye-blink frame) paints frames into the
puppet's own picture, its positions being pixels of that picture: it is never drawn
as part of the model on the screen. Each animation stores one weight a frame per
channel (numbered by the order of its records, which the mesh's blend index names),
sampled between frames like the bones; a weight that is not a number counts as 0. The weights of the visible animation layers
are averaged by their blend, so a layer alone counts in full whatever its blend, and
a hidden layer or none paints nothing. The frame is drawn into the layer's picture
where the card puts it into the effect chain's first buffer, before any effect and
with the card's colour, by the shipped shader, which mixes it into the picture by
the weight (`g_BlendMap`). A puppet whose animations weigh a channel in at some frame
is therefore drawn through its effect chain even without effects; the paint pass
itself draws only in frames where a channel weighs more than the 0.001 the shader
discards at, and costs nothing otherwise. A text layer is an ordinary layer: it takes its place in the layer order and
carries its transform, opacity, blend, effect chain, camera and the final
composition, appears in desktop posters, and uses the engine's one text system on
both renderers. Text whose content has not changed is not laid out, its glyph quads
are not rewritten and its atlases are not uploaded again; a script that produces it still runs on its own schedule every
frame. A text script that writes `thisLayer.text` from `update()` and returns nothing
keeps what it wrote, as in Wallpaper Engine (a clock that writes the time once a
minute shows it, not the text the scene file starts with), and its next
`update(value)` is given that string. A string `update()` returns replaces it. That is
the only text write compared with Wallpaper Engine's frames. A write from anything
else, such as another property's script, a scene script, a cursor handler or another
layer's script, is the layer's text until the text property's own value is applied on
the next tick; which script Wallpaper Engine lets win when two write one text is not
established (the one frame that covers it shows the text script's value). Effect and
video output of Native Metal has not been compared against real wallpapers.

A video texture plays against the clock of the layer that shows it, the scene's until a script
moves it, on both renderers. A render graph built again under a playing video (a text layer
whose card changes size in texels, a property that shows or hides a layer, a change of the
render scale on Native Metal) does not close the videos the new graph still shows. Wallpaper Engine resizes a text
card's buffers in place and touches nothing else a scene holds, so its video neither goes back
to the head of its clip nor stops. Here the host asks the renderer to clear the graph *for a
rebuild* (`clearLastRenderGraphForRebuild`), which sets every open video aside (Native Metal:
`MetalVideoTextures::hold`; Compatibility: `TextureCache::ClearForRebuild`); the compile that
follows takes back the ones the new graph binds, by texture, and closes the rest when it ends,
however it ends: a compile that is refused, or a clear that fails, closes them too. A video
taken back is not parsed, so one packaged in the scene is not read, copied and hashed again
(about 7 ms a megabyte: 0.2 to 0.4 s for a 53 MB clip, 1.3 s for a 191 MB one, 2.0 to 2.3 s for
a 319 MB one, which a rebuild paid for every video it opened), and it is not opened, so its
decoder carries on from the frame it had, given the scene's clock as any draw gives it. A
decoder that failed while it waited is opened again like any other. Only the rebuild of the
scene that is drawing keeps videos: a scene that is replaced and a renderer that is destroyed
close them with the graph, as before, and so does a Compatibility surface that is released (a
display change), which clears the texture cache; Native Metal keeps its graph, and the videos
with it, through a surface release. A video whose layer a property shows again was left out of
the graph by the rebuild that hid it, and closed then: it opens at the head of its clip and is
sought to the clock, as any open is (below). Nothing is added to a frame, and no decoder is kept
that was not open already. On the clock wallpaper of the re-test (3326873240: five 4K videos
packaged in one 235 MB scene, a clock under an effect, Native Metal, display size, real-time
pacing), a rebuild opens no video and takes 0.02 to 0.05 s; with the videos closed as they were,
it opens all five again and takes 1.2 to 1.4 s on a quiet machine and 3.4 s on a busy one.
Outside the clock's own box the picture after either rebuild is the picture of a run that did
not rebuild, pixel for pixel: the seeks of this wallpaper's clips land while the later videos
are still opening, so the head of a clip is not seen on it, only the wait.

A video that is opened while the clock is already some way into the clip (a scene that is
rebuilt after a failure) opens at the head of the clip, as any open does, and the first call that gives it the clock seeks it
there. The open waits for no seek, so it costs what opening at the head costs. The head of the
clip is on screen until the seek has landed and the decoder has caught up with the clock, which
kept running while the seek was made: 0.35 to 0.75 s for a 1080p clip and 0.7 to 1.5 s for a
4K one at 30 frames a second with a keyframe every 250 frames (8.3 s), 2.3 to 4.2 s for 4K at
60 frames a second with one every 600 (10 s). An open that waited for the seek would add its
length to the draw that opens it (0.3 to 0.6 s on the 1080p clip, 0.5 to 1.1 s on the 4K one,
1.4 to 1.5 s on the 60 frame one) and fail once it passed the two seconds an open waits for a
first frame, as the 4K 60 frame clip's did at 9.9 s and at 19.9 s.

A clock that jumps, as when a script sets a time, is one seek to the new time. Either way the
frame the video had stays on screen until the seek lands, and no draw waits for it. A jump back
by more than two frames (a script restarting its clip) has the seek's first frame replace that
frame as soon as it is decoded; a draw that waited for it instead held every layer of the scene
still for as long as the seek took, up to two seconds. A seek that is on its way is not made again, because that restarts the decode from the
keyframe and drops what it had decoded: asked for on every draw, a seek that takes longer than a
draw would never land. It is made again only when the clock goes back before its target, or jumps
on past it by more than a second beyond the time the seek has been made for, a clock that only
runs while the seek is made being where it should be. A seek of any length therefore lands, and
the frames after it are decoded on to the clock, at several times the pace the clip plays,
instead of sought to again.

Particle systems follow Wallpaper Engine 2.8's own rules, on both renderers, because
one simulation feeds both. A system is simulated for its file's `starttime` before the
first frame (steps of 0.05 s, or 0.2 s once the file holds 500 or more particles; at most
6000 steps are run, and an even longer start time only advances the system clock), so
it opens populated, run once the scene is assembled so that a layer's parent groups have
a say in where the particles are born; an event child's instance does the same with the
child file's own start time. A `sphererandom` spawn is a uniform point of the unit ball stretched by
`directions` (a flat `directions` fills toward the middle, `cone` narrows it about +x), a
`boxrandom` spawn folds each axis' signed draw onto `distancemin`..`distancemax`, and a
particle born exactly on the centre leaves along a random direction. An emitter's
`delay`, `duration` and periodic windows (`flags` 4 with the four `*periodic*` keys and
`maxtoemitperperiod`) are honoured, `flags` 2 means at most one particle a frame at the
file's rate, and an `instantaneous` burst is paid for out of the rate's account.
SceneScript particle controls use that simulation state. `pause()` suppresses scheduled
emission in the root and its children; existing particles still age and move, while
`isPlaying()` reports false. `stop()` clears particles, trails and event instances and
resets emitter delays, durations, bursts and initializer counters, preserving the pause
flag. `play()` clears pause and, only when the whole tree has no live particles or active
emitters, reopens the finished flags. It does not rewind an expired duration: `stop()`
followed by `play()` starts a fresh cycle. Outside pause, `isPlaying()` includes live or
emitting static and event children. `emitParticles(n)` adds `n` to each root emitter
immediately, within its capacity; zero means one and negative values do nothing. Manual
emission bypasses pause, stop and the ordinary per-frame/window quota, but an active
unpaused stream charges it to its rate balance. It does not multiply the manual count
by the instance count factor or unpause the system. Script emission and clearing rebuild
invalidated geometry before that frame is drawn.

The read-only `instance` object exposes seven numeric factors (`alpha`, `size`, `count`,
`speed`, `lifetime`, `rate`, `brightness`), `colorn`, and control points and angles 0–7.
Vector getters return copies. Writes read back immediately and bind to the simulation
at its next step, so an `emitParticles()` in the same script still uses the previous
binding. That rebind clamps `rate` to at least 0.01 and reopens positive-rate emitters,
even when a script wrote the same value after stopping. Unset colour reads as
`(-1,-1,-1)`; a negative first colour component disables that tint. An unset point or
angle has `FLT_MAX` in its first component; assigning this sentinel leaves the last
effective point or rotation alone. Removing the layer releases its simulation and
invalidates retained instance wrappers. Pending instance storage is allocated only on
a script write and only written layers enter the update queue. The ordinary simulation
walk caches whether particles still need time: an exhausted or stopped system does not
keep the frame clock running, but paused live particles do.
A zero or negative count factor finishes a stream with no pending burst; a burst
waiting behind a zero count remains active and can fire when the count is restored.

`layerimage` emits from the layer named by its `emitterimage` dependency, including a
hidden image, an on-demand quarter image of published text glyphs, and a puppet's UV pieces. It builds one
shared map for that source with the four taps of `downsample_quarter`, keeps texels whose
8-bit alpha is at least 127, and chooses them uniformly. The map is built after the
scene is attached, then rebuilt only when its image size changes or flag `0x20000`
requests the one-second refresh. Flag `0x10000` (on by default) copies the sampled
colour; `0x80000` applies `offsetmin`/`offsetmax` in source space; `0x40000` inherits the
source layer's motion over the unscaled scene timestep, multiplied by `speedmin`/`speedmax`.
The particle's position and inherited velocity exist before the initializer chain runs.
Puppet points read the most recently evaluated skin palette without evaluating or copying
it. Text donors are composed over transparency with material alpha blending, so a solid
glyph at opacity `a` contributes alpha `a*a` before the emission threshold; image donors
read the original texture alpha instead of the layer opacity. Text sampling uses the existing
mesh and atlases, and releases the temporary quarter image after building the map; it
does not shape the text again or keep a full-size bitmap. Layers with no image-emitter
consumer do no emission-map work.
The random initializers take their `exponent`, a lifetime is never below a millisecond, a
`sizerandom` or `alpharandom` scales the size or alpha the particle has so far (as the
colour initializers do, so a second `sizerandom` narrows the first one's draw; only the
lifetime is replaced), and every particle carries one random number of its own that picks
its oscillation phase and frequency, its turbulence speed and phase, and its
`randomframe` sprite (which is never cross-faded with a neighbouring frame). `movement` and
`angularmovement` advance the particle where they stand among the operators, with the
damping `velocity * (1 - drag * dt')`, and nothing else does: a particle file without
them keeps its particles where they were placed, whatever velocity they were given. The
forces act over Wallpaper Engine's second time step `dt' = dt * pow(min(0.025 * fps, 1), 0.7)`
with fps the scene's frame-rate cap (the drags, the pull of `controlpointattract`, and the
`turbulence`, `vortex` and `vortex_v2` speeds and the `boids` steering; positions and gravity still integrate over `dt`), so below
40 frames a second those forces act more weakly per second (at the default 15 frames a
second they act over about half the step), and at a cap of 20 frames a second or less the
operators run twice per frame over half steps, each pass from the particle's birth colour,
alpha and size and at the same system time, while emission, ageing and trail points stay
once per frame. A system's start-time prewarm runs at load, before the scene's frame rate
is known, with full steps. A movement operator with `flags` 1 keeps gravity in screen axes
by multiplying it with the layer's transposed matrix, scale included, in a system that is
not `worldspace` (a `worldspace` system is already in the scene's own axes and takes it as
written); `controlpointattract` pulls hardest at the
control point and not at all at its threshold, and with `flags` 1 removes a particle
whose path over the last step, from where the movement operator found it, came within
`deletethreshold` of the control point; `vortex` swirls about the control point
plus its offset; `turbulence`, the oscillators, `capvelocity`, `angularmovement`,
`controlpointattract`, `reducemovementnearcontrolpoint`, the two maintain-distance
operators, `vortex_v2`, `remapvalue` and `inheritvaluefromevent` take the blend window
(`blendin*`, `blendout*`), the vortex and `boids` do not; `alphafade`
fades in before `fadeintime` and out after `fadeouttime`, and where the two overlap (fade in
ending after fade out starts) multiplies by the two factors' bits ORed together, as Wallpaper
Engine's SIMD kernel does; `turbulence` reads Wallpaper Engine's 3D simplex noise (times 32),
`positionoffsetrandom` a normalised fbm of its 2D simplex, and `turbulentvelocityrandom` turns
`forward` about `right` by its 1D simplex of the system time (plus a random share of the phase
range) times π, `scale` and plus `offset`, so particles born together share a heading; the
override `rate` scales both noise timescales on top of the rate-scaled time, and is held at
0.01 or more (a negative or non-number rate runs the system at a hundredth of its speed); and
`turbulence`, the vortex and `vortex_v2` an
`audioprocessing*` level (the loudest selected band), which makes a scene that has
any of them need audio capture like an audio-driven emitter does. `vortex_v2` swirls
about its control point's axis (`flags` 1 measures from the axis line, 2 holds each
particle at its distance with `centerforce`, 4 swirls about a ring of `ringradius` and
pulls particles within `ringpulldistance` outside its `ringwidth` band toward it);
`boids` steers each particle toward its neighbours' mean velocity and centre and away
from those inside `separationthreshold`, a slice of the particles per step once a file
holds 200 or more, `flags` 1 capping the speed it gives; `remapvalue` (each step) and
`remapinitialvalue` (at birth) map one of twenty particle or system quantities through
an input range, a `sine`, `square`, `saw`, `triangle`, `simplexnoise` or `fbmnoise`
transform and an output range into another (`remap`, `multiply`, `add` or `subtract`,
`flags` 1 and 2 clamping the input and the output; a record without `flags` clamps its
input, as the engine's loader writes 1 when the key is missing). With a control point
as output, `remapvalue` writes that point every step from the first particle of each
group of four (the engine's SIMD kernel broadcasts lane zero), its full translation
and the matrix's w, which takes z; `remapinitialvalue` writes it when a particle is
born and keeps w. A written point keeps its value until the next write, also for
later readers in the same step, and owns its slot over cursor links and parent
copies; and `inheritvaluefromevent` gives an
event child its parent particle's running colour, opacity, velocity, size, rotation or
spin each step, as `inheritinitialvaluefromevent` does once at birth. `capvelocity`,
`reducemovementnearcontrolpoint`, `maintaindistancetocontrolpoint`,
`maintaindistancebetweencontrolpoints`, `collisionplane` and `collisionsphere` work on the
control points' motion and orientation (every particle found inside a collision shape
takes its response, a bounce or a slide, whichever way it is moving; a sphere without an
`origin` is centred 200 below the origin in a pixel scene; with `flags` 1 a sphere is centred
on its control point and a plane passes through it, turned by the control point's
orientation, and neither reads its own `origin` or `distance`; with `flags` 2 every
collision kind also stops the spin of each particle it hits), the collision shapes
`collisionbounds` (four planes round the scene canvas, taken into the layer's frame; the
last plane a particle is behind pushes it back), `collisionquad` (a particle that crossed
the quad's front since the last step, inside its `size`, default 200 × 200, is pushed out
by 1.05 times its depth; `flags` 1 carries the quad with its control point) and
`collisionmodel` (capsules built every step from the linked layer's bone boxes, or from
the box round its vertices for a model without them, through the bones' current pose and
the layer's matrix; the layer is the one the scene object's `dependencies` entry of type
`collisionmodel` and that `index` names), while `collisionbox` does nothing, as in
Wallpaper Engine (`artifacts/we-parity/decompiles/F-D13.md`), and the `hsvcolorrandom`
(its hue steps spaced as the loader spaces them), `colorlist` (its noise a draw over the
entry's value plus and minus the noise, cut off at 0 and 1), `inheritcontrolpointvelocity`,
`positionoffsetrandom`, `mapsequencearoundcontrolpoint`,
`mapsequencebetweencontrolpoints` and `inheritinitialvaluefromevent` initializers are
implemented. A scene object's `instanceoverride` colour re-tints the preset's own colours
by the difference between the override and the preset's representative colour, keeping
their spread. In a scene saved before version 5 (`scene.json`'s `version`, missing counts
as old) it then tints the particle by the override as well (so an orange override on a
fire whose red end the re-tint turns magenta draws it red again, as Wallpaper Engine
does); from version 5 the re-tint alone is the colour, so a dark override is not applied
twice. A preset without colours takes the override as its colour, and an override equal
to the preset's own colour changes nothing; its
`controlpoint0`..`7` and `controlpointangle0`..`7` replace the preset's control points
(a control point flagged 2 is held at its scene position as the layer moves; a file's
control points fill slots 0 to 7 in list order, whatever `id` they carry, take their
`angles` as their orientation), and
`brightness` multiplies the tint in an HDR scene, and each of them follows a user
property while the scene runs, or plays the timeline it is keyed with (`animation`, on the
layer's clock: the stock vortex orb preset turns its control point 1 this way).
`maintaindistancetocontrolpoint` measures the distance in its control point's frame (kernel
0xB, `0x14024198B`): in a world-space system that frame carries the layer's matrix, so a
layer scaled by 0.5 holds its particles half the authored distance away.
Control-point flag 4 copies the registered `parentcontrolpoint` frame into a child's
space, including its orientation and scale; adding flag 8 copies the raw frame.
An authored parent point is available only when an emitter or operator references
that slot or a later one. Cursor-linked points and points owned by a remap output
keep precedence. Event children retain each instance's previous copied positions,
read nested copies from the bound parent instance, and reset that history when a
pool slot is reused or recreated after stopping.
A child's `controlpointstartindex` does not change its emitters' control-point indices.
With child-entry flag 1, the child's points from that index on take the positions of
the parent instance's live particles each step, in particle order, through the
parent's simulation frame into the child's space. A cursor-linked, parent-copied or
remap-written point there stops the feed rather than being skipped; with fewer live
particles than points, the remaining ones keep their last value. A cursor-linked
point takes the cursor's position as its whole translation; its authored offset is
not added.
Each event child uses its own particle file's world-space flag. World particles
retain the origin at which they were emitted when their parent moves, including
rope history and additional renderers. A local child of a world-space parent uses
that parent's simulation frame. World-space remaps read absolute positions and
control points; distance and direction inputs remain relative quantities.
The override's `size` multiplies the size a particle is born with and
every `sizechange` ramp of the file besides, as Wallpaper Engine's loader binds the
override to each size record: a ramp scales the running size by the override times its own
factor, so a particle under two ramps is the override cubed, not the override, unless the
particle file sets the "ignore size override" flag (128), which keeps it out of the draw
and the ramps alike. Its `speed` scales the emitters' and velocity
initializers' speeds, `movement` gravity, `angularmovement` force, the vortex and turbulence
speeds, the pull of `controlpointattract` and the frequency of `oscillateposition`, unless the
particle file sets the "ignore speed override" flag (16). Its `count` scales the emitter
rates (not the spacing of the `mapsequence*` initializers, which a Wallpaper Engine probe
shows unchanged under counts 2 and 0.5), and its `lifetime` scales the
`lifetimerandom` draw only (a file without one keeps its lifetime). File flag 8 keeps the
colour override (and its brightness) away from the colour records, 32 keeps `count` and 64
`lifetime` out. A file that leaves `maxcount` out holds no particles; a child entry without
it allows 10 instances. An `eventdeath` child starts where its particle died, with
its own prewarm, and keeps emitting at its own rate: the death that made it does not
stop it, and it is used again only once its emitters have finished and its particles
are gone. An `eventfollow` child whose bound
particle ends stops emitting but keeps the particles it already emitted until they die.
A file with the `worldspace` flag leaves its live particles where they are in the scene
when the layer moves, and when it turns or is rescaled. A file that lists several `renderer` entries draws the same
particles through a mesh and material for each entry (each entry has its own copy of
the file's material, so a rope entry's shader never reaches a sprite entry, and the
particles stay in birth order for a rope entry in any position); a file whose `renderer`
list is an empty array draws nothing, though the system still runs and still spawns its
children, while a file that leaves the key out gets one sprite renderer. A `rope` renderer
is drawn as `subdivision + 1` pieces per pair of particles in the per-segment (thick) vertex layout,
and a `ropetrail` records `segments` points of its path and draws `subdivision + 1`
pieces between them; the renderers fill the keys a file omits with their own defaults
(rope: subdivision 4; rope trail: length 1, 4 segments, subdivision 1), truncating and
clamping what they read. What a file omits in an operator or initializer takes the
pixel-canvas defaults in a scene drawn with an orthogonal projection of a size (a scene
that names none is drawn as the default canvas) and the scene-unit defaults otherwise.
Each renderer has its own `orientation`, `axis` and `flags`: the exact strings
`screen`, `upright` and `fixed` select the modes; other strings and numeric values
use screen mode. A zero axis becomes `(0,1,0)`. Fixed orientation takes the axis
as forward, while local upright takes it as up. Renderer flag 1 selects worldspace
orientation; worldspace upright uses world Y. The basis follows the current draw
model and camera through WE's model-transpose operations, with up and forward
normalized independently, preserving its nonuniform-scale behavior. A parallel
upright axis has the native non-finite right/forward result. Rope shaders receive
the corresponding `ORIENTATION` combo. These values are produced in the existing
uniform update, independently for renderers that share one particle simulation.
Like Wallpaper Engine on DirectX 11, a rope whose shader has a geometry stage
(`genericropeparticle.geom`) is drawn through it: one record per pair of particles
(or of recorded points), which the stage subdivides into a ribbon of
`4 + 2 * subdivision` vertices centred on its path and facing the eye. Metal has no
geometry stage: the shader layer runs the author's geometry program inside the vertex
stage, once for each vertex of the ribbon. A geometry stage that cannot be translated
leaves the rope on the shader's own vertex-only path, where the pieces are subdivided
on the CPU.
A rope's texture runs once along it for `uvscale` 1: the shader measures its
coordinate against the number of points divided by `uvscale`, as Wallpaper Engine
writes it (so `uvscale` 2 repeats slightly more than twice on a short rope). With
`uvscrolling` the measure is what the rope holds once steady, its file's first
emitter rate times its average lifetime (`lifetimerandom` bounds, lifetime override
included) less one, the rate bounded by the frame-rate cap while the rope holds fewer,
and the texture moves on by one point for each particle that dies, so a growing rope
unrolls it. `uvsmoothing` draws a rope that has not reached that count as without it;
once it holds that count the texture is measured against the count less one and
starts at the newest particle's age over the spacing of births, less one, so it
slides by one point between births instead of jumping. A scrolling rope trail is
drawn by its shader's `TRAILSCROLLALPHA` branch, which fades its ends with the
renderer's `fadealpha` and `fadesize`. A `boxrandom` emitter whose `directions` are
all zero gives its particles a velocity that is not a number, as Wallpaper Engine does
(it divides by the zero length of the spread), so they are never seen.
A rope trail's `fadealpha` and `fadesize` take effect only while its texture scrolls
(`uvscrolling`): each recorded point's opacity or width is weighted by a sine over
its age, so both ends of the trail fade. A rope trail uses the thin vertex layout
unless a sprite trail shares its particles, in which case every renderer of that
file takes the thick layout, and the first rope trail of a file records the
history even when another renderer comes first. A trail records a point on its
first frame and then each time its period (`length / segments`) has run out,
counted in whole frames as Wallpaper Engine counts it: at 15 frames a second a
0.25 s period records every fourth frame. The oldest point stays where it was
recorded, and a prewarm records nothing: afterwards each trail starts from where
its particle is. The other known differences are
listed under [Known limitations](../testing/renderer.md#known-limitations).

Text is set the way Wallpaper Engine 2.8.42 sets it. `pointsize` is a size in
points at 300 dpi, 4.17 pixels to the point, clamped to 1 through 256 and handed to
FreeType as it is, which rounds the em to whole pixels only for the fonts that ask;
text is shaped with HarfBuzz as Wallpaper Engine shapes it (`hb_ft_font_create`,
unhinted advances; `artifacts/we-parity/decompiles/G-F1.md`-`G-F3.md`, `G-F14.md`): each
paragraph is cut into runs of one face (a space, tab or zero-width joiner stays in the run
before it), each run is shaped on its own with the direction and script HarfBuzz guesses
for it, so OpenType and AAT kerning, ligatures and complex scripts apply and a run guessed
right to left is set right to left, but runs keep their logical order (Wallpaper Engine
has no bidi algorithm); a paragraph is shaped once and its rows are cut from the shaped
glyphs, an ellipsis candidate is shaped again with U+2026, and a glyph's advance is the
shaper's advance cut to whole pixels; the line pitch is the font's line height plus the layer's `spacing` y, its x
adds to every glyph's advance, and a row is as wide as its ink and the pen at each
glyph start (the advance after the last glyph is not part of it). Five cards that
Wallpaper Engine saved for text in Arial in the local scenes (with and without
padding, a lone full stop, a run of dashes, a long run of underscores) come out to
the pixel; other fonts and scripts have not been compared with Wallpaper Engine. A system font is opened through FreeType from its file and not read
into memory (PingFang is 78 MB), and the face of a font collection is the one the system
names, by PostScript name, so `PingFang SC` is the Simplified Chinese cut and not the
Hong Kong cut that starts `PingFang.ttc`. The faces stay open for the next layout, at most
eight, the one unused longest dropped first, because a layer lays its text out again for
every change of it, and a face whose file has changed since it was opened (a font replaced
in place) is dropped and opened again, because FreeType reads the file through a mapping.

A text object's `font` is read as Wallpaper Engine reads it: eight
keys, matched as the whole string in lower case, are fonts of the Windows Fonts folder
(`systemfont_arial`, `_calibri`, `_cambria`, `_comicsans`, `_consolas`, `_sansserif`,
`_segoe` and `_verdana`), any other string is the path of a font file the wallpaper ships,
and a font that cannot be loaded, which a family named by its name alone (`Arial`,
`Helvetica`, `systemfont_Helvetica`) is, is drawn in Arial; a text object with no `font`
is in Arial, whose line is 1.15 em (a Helvetica's is 1.0). Arial, Comic Sans MS, Microsoft
Sans Serif and Verdana are on every Mac as the same fonts. Consolas, Cambria, Segoe UI and
Calibri are not: Andale Mono, Charter, PT Sans and PT Sans stand in for them, drawn at the
size that gives the digits the real font's advance (0.916, 0.996, 0.987 and 0.93 of the
point size, which a clock's width is made of) and with their rows set in the real font's
line, the one the cards Wallpaper Engine saved have (1.1709 em for Consolas, 1.170 for
Cambria, 1.331 for Segoe UI, 1.2207 for Calibri); Consolas's digits then stand 0.643 em
tall as in Wallpaper Engine's frame, where Menlo fitted the same way would stand 0.676,
and its ascender is 0.743 em, which puts the digits of a centred clock where Wallpaper
Engine's are. The glyphs of those four are the stand-ins' own. A glyph the font lacks is
drawn from the first face of Wallpaper Engine's list that has it (Arial, Segoe UI's
stand-in, Apple Symbols for Segoe UI Symbol, which is not asked for CJK punctuation and
fullwidth forms (inferred: they go to the next face, so a string does not mix a centred
fullwidth comma with a left-set ideographic one), PingFang SC for Microsoft YaHei, Apple SD
Gothic Neo for Malgun Gothic, and Arial Unicode MS last), each opened only when no face
already held has the glyph, so the list is gone down as far as the text needs, once for
a layout, and a glyph that none has is skipped. That list is Wallpaper Engine's order:
Arial, Apple Color Emoji for Segoe UI Emoji, Segoe UI's stand-in, the wallpaper assets'
`fonts/TwemojiMozilla.ttf` (read once a scene and shared by every layer), Apple Symbols,
PingFang SC, Apple SD Gothic Neo, Arial Unicode MS. A colour glyph (`FT_LOAD_COLOR`; a
bitmap-only face is drawn from the strike nearest the layer's size, scaled to it) comes
from the layer's colour atlas in its own colours, through `basefontrgba`.

The glyphs are drawn as Wallpaper Engine draws them (Appendix G of the parity plan): one
quad per glyph from an atlas, through the shipped `font` shader and its
`materials/fonts/basefont*.json` materials, in a mesh of three parts the text worker
rewrites when the text is laid out again (a background or seed quad, the mono or
distance-field glyphs, then the colour glyphs, `Text/TextGlyphMesh`). A plain layer's glyphs
come from a coverage atlas (one byte a texel) rendered at the layer's size; a layer with
`msdf`, an outline, a blur or a drop shadow takes a distance-field atlas instead
(msdfgen, 32 atlas pixels to the em, a 24-pixel range, 12-pixel margin;
decompiles/G-F4..F6). Runtime glyph atlases use linear, clamp-to-edge sampling; they are
generated images, not file textures with anisotropic sampling. An atlas is kept per font,
size and kind and shared by every layout of it, starting at 512 texels and doubling to
4096, where it is cleared and the text laid out
again once (G-F16), so a clock's digits are rendered once. Nothing of it costs a frame while
the text stays the same: the mesh is an event mesh and Metal grows its storage in place when
a longer text needs more.

A particle emitter whose `emitterimage` names a text layer samples the glyphs, their
outline or shadow and the opaque background, including a hidden layer. It requests a
temporary RGBA map at quarter resolution, bounded at 960 by 540, from the published
mesh and atlases (`RenderTextEmissionImage`). The map is built only when the emitter
first needs it, its source dimensions change, or its timed refresh flag requests it;
the emitter releases it after making its emission table. Other text has no layer
bitmap, and sampling neither shapes the text again nor uploads an image. A hidden
text donor still prepares changed text, fonts and point sizes on the text worker,
so the emitter's next resize or timed refresh sees the new glyphs. This CPU demand
does not make the hidden layer draw a GPU composite; unreferenced hidden text waits
until it is shown. The map
uses the font material's translucent alpha rule: a solid glyph at layer alpha `a`
has alpha `a * a` before the emitter's 127-byte threshold. Wallpaper Engine emits
from plain and MSDF text at 0.75 and 0.80, but not 0.70; image donors do not use this
text-specific opacity rule. Colour glyphs keep their atlas colours; their particle
output has a synthetic test but has not been compared with a valid reference frame.

An
`opaquebackground` fills the card's rectangle with `backgroundcolor` times
`backgroundbrightness`, the brightness only in the HDR pipeline as the text's is, at the
layer's alpha: a layer drawn straight onto the scene draws it as the `fontbackground` quad
before its glyphs, and a composite starts as the fill's colour at the layer's alpha where it
would start as the scene behind the card. The colour and the brightness follow a property or script bound to them.

The card is the text plus `padding` on each axis, and the margin is
there only for a layer that has a visible effect pass, a colour blend, an LED
source or an opaque background, or in a scene that enables distance fog or height
fog (`fogdistance`, `fogheight`): a plain text layer has none, whatever its `padding`
says. Which effects are visible is counted again whenever a script switches one, as
Wallpaper Engine counts it: the card of a layer whose effects a script has all off is
unpadded, and gains its padding, laid out again, while one is on (on the text worker, as for
any change of the text, so the card follows a frame or two after the switch).

`padding` and `spacing` are two numbers, and `padding` is 32 on both axes where
the scene leaves it out, each lane capped at 512 and not floored (a negative padding
takes the card in around the text). A scene's authored `size` is the editor's box and is
ignored, as Wallpaper Engine ignores it: the card is laid out again with every change
of the text, so a clock that gets shorter has a smaller card. The layout is one record,
the ink of the rows and the face's ascender, descender and pitch (the block runs from
the ascender, or the tallest ink above it, down one pitch per row), measured once as
the layer is parsed. A layer's alignment hangs that card from the layer's origin and
never moves the layer: across, the origin sits on the left edge of the text's block,
its middle or its right edge; down, on the first row's ascender line (`top`), halfway
between that line and the last row's baseline (`center`) or on the last row's descender
line (`bottom`), whatever ink rises above the ascender. The padding grows the card
outward from there, so a layer that gains an effect, and with it padding, keeps its
text where it was, and the layers parented to a text layer sit on its origin. The rows
of a block are set within its widest row, each starting at its own pen against its
left edge, centred or against its right edge. The cursor is over the card where it
hangs.

A card's ping-pong buffers and the composite another layer samples are built at the
card's width and height with the fraction cut off, at least 4 texels, whatever the size
of the scene or of the editor's box. A change of the text that changes those dimensions
resizes the targets under the existing render graph. A card that only moves, as when
its alignment flips, or grows by less than a texel needs no target resize. An effect on the text sees
the card as its whole picture: `v_TexCoord` runs 0 to 1 across it and
`g_Texture0Resolution` is its size, so an offset, skew or scroll given as a fraction of
the picture moves by that fraction of the card, as in Wallpaper Engine. A card past
4096 texels on a side is drawn cut off to 4096. An effect's own buffers (`fbos`) that name no
`width`, `height` or `fit` follow the card divided by their `scale` (zero means one),
rounded to a whole texel with a minimum of 4. A buffer with its own width, height or
fit keeps the size resolved at load, including its scale, when the text changes.
Both use the renderer's ordinary internal render scale; a half-size text buffer stays
half the card's raster when that scale changes.

A text layer that draws through a
visible effect, a colour blend other than 0 and 31 (`sub_1401E6F50` sets the composite flag
for those, decompiles/G-colorblend-composite.md), or in a fogged scene is a composite, as in
Wallpaper Engine: the card first holds the scene behind it with no alpha (a seed pass, as
`composelayer_clearalpha`; the opaque background's fill instead when there is one), the
glyphs are blended into it with the font material's translucent blend (`SRC_ALPHA` /
`INV_SRC_ALPHA` on colour, and the composition stream's `Material` rule on alpha, so the
alpha left is the glyph alpha squared), the effects run on that and the last pass goes onto
the scene by the alpha it holds, depth-tested as the layer's font materials are. Black text
of alpha `a` through an `opacity` effect, or a colour blend, therefore stands at `a` cubed
of the way to black (`TextCompositeReach`), where text with no composite stands at `a`. The
last pass of the chain is drawn translucent whatever the colour blend mode, "add" included.
In a fogged scene the chain ends in the fogging passthrough (`effectpassthrough_4`), so text
takes the fog of its place as an image layer does (the WE probe probetext-fog shows it); the
glyph passes themselves are never fogged (decompiles/G-F11.md). A layer whose effects a script
has all switched off, and that nothing else makes a composite, draws its glyphs straight onto
the scene by their alpha, through its own camera, additively for mode 31: the chain is
skipped, as Wallpaper Engine draws a layer with no effect pass. Whether a chain of other
effects stands at the same cube is open for some of them; see
[renderer verification](../testing/renderer.md#known-limitations).

`maxwidth` is the width a row may fill, as authored: padding is never
taken from it, so a padded card can be wider than `maxwidth`. A row wraps before a
glyph whose ink would end past that width, once it holds a glyph: at the last space
or tab before it, where everything before that space stays in the row (a second space
too) and the next row starts at the glyph, or at the glyph itself when the row has
none to break at. A space never starts a wrap. The last row the row limit allows does
not wrap: it is cut before the glyph that did not fit, inside a word if that is where
it falls, and an ellipsis, where asked for, replaces its end by dropping glyphs one at
a time until the marker fits. A line break with nothing after it ends the text
without a row of its own and without an ellipsis. With
`blockalign` on, a row that ended at a wrap, with another row after it, is stretched
to exactly the width by spreading the slack over its spaces and tabs; the last row of
a paragraph, a row a line break ended, a row the row limit cut and a row with no
space are left alone. A text layer's colour blend mode works as an image layer's
does: through the passthrough pass over its seeded composite (above), or for mode 31
additively onto the scene. `outline`, `blur` and `dropshadow` give the glyphs Wallpaper
Engine's signed-distance look through the font shader's own combos (`OUTLINE_ENABLED`,
`BLUR_ENABLED`, `DROP_SHADOW_ENABLED`) and render variables (`g_RenderVar0` = range 24, outline,
blur, shadow sizes in atlas pixels; `g_RenderVar1`/`g_RenderVar2` = outline and shadow colours
with the shadow's offset; `g_RenderVar3.x` = its opacity; `TextStyleRenderVars`, with the caps
and floors of `sub_1401B3B60`, decompiles/G-F5.md). Each glyph is its own quad, so a glyph's
outline is drawn over its neighbour's fill as in Wallpaper Engine, and the card has no room
around it for the style. The switches pick the combos and the atlas kind: a property bound to
one is read once, as the scene loads, with the value the user has chosen, and held at it by a
preview of changed properties (a load-only property). The sizes, opacity and colours are
uniforms. Changes from a user property or a script bound to the setting update them without
layout or a render-graph rebuild. Direct `thisLayer` writes also reach the text layer:

| Members | Work when the value changes |
| --- | --- |
| `font`, `pointsize`, `horizontalalign`, `verticalalign`, `padding`, `spacing`, `maxwidth`, `maxrows`, `limitwidth`, `limitrows`, `limituseellipsis`, `blockalign` | Schedule layout on the text worker; resize existing targets when needed |
| `backgroundcolor`, `backgroundbrightness`, `outlinethickness`, `outlinecolor`, `blursize`, `dropshadowsize`, `dropshadowopacity`, `dropshadowoffset`, `dropshadowcolor` | Update uniforms without layout or a graph rebuild |
| `msdf`, `outline`, `blur`, `dropshadow`, `depthtest`, `opaquebackground` | Change the font material only when its effective variant changes; a different atlas kind also schedules layout, and an opaque background can change padding |
| `anchor` | Update the draw offset |

A write of the value already held does no work. A coverage/MSDF switch keeps drawing the old
glyphs until their replacement atlas is published, then installs its matching material and
requests one graph rebuild. Material objects keep their identity, so existing colour and alpha
bindings continue to reach them. An opaque background first enabled by a script joins the
existing alpha driver and keeps its own colour. Getters return vectors for vector members,
booleans for flags and numbers for sizes; `maxrows` retains its signed integer value.
An unknown enum word selects Wallpaper Engine's first registry entry: horizontal `left`,
vertical `center`, anchor `none` and depth test `disabled`.

`anchor` pins a text
layer to an edge or corner of the area the display shows, on top of its origin and
alignment: where the display's shape differs from the canvas's (Fill crops it, Fit or a
pan adds room), the layer is drawn that far along that edge, and a scene shown whole
moves nothing. The shift is a translation of the drawn layer in the scene's own axes,
whatever the layer's scale and turn: the layer's origin, what a script reads as it
and the layers parented to it stay where they are. The effects of the layer follow the
draw: the matrices that say where the effect lands on the screen
(`g_EffectModelMatrix`, `g_EffectModelViewProjectionMatrix` and the effect texture
projection a pointer effect undoes) are the drawn card's, so a cursor effect finds the cursor
over the text where it is drawn; `g_LayerModelMatrix` is the layer's own.
Camera parallax moves a text layer as it moves an image layer, as Wallpaper Engine's
draw loop adds the offset to every object it draws: by the layer's distance from the
eased cursor point times its `parallaxDepth` and the scene's amount, so a text label
beside a depth-0.06 underline moves with it, and with the cursor centred a layer off the
centre of the canvas already sits that far out. A layer drawn through effects takes the
offset once, on its final pass.
A text object that leaves keys out has Wallpaper Engine's defaults: 32 points,
`maxwidth` 500 and `maxrows` 1, and `horizontalalign` and `verticalalign` `center`.
The two alignment keys are read as Wallpaper Engine reads its enumerations: the words
are `left`, `center` and `right`, and `top`, `center` and `bottom`, matched exactly
(case counts), and a key that is there with anything else, a string that is no
word, a number or `null`, takes the first entry of its registry, which is
`left` horizontally and `center` vertically (an object, such as a `{ "user": ..., "value": ... }`
wrapper, is read the same way, which is inferred: nothing seen shows whether Wallpaper Engine's
loader unwraps one before the enumeration reads it, and no local scene has one). A text object has no `alignment` key, so
one is not read. A text layer's `brightness` multiplies its colour only in a scene that
runs the HDR pipeline (`hdr` with `bloom` and Ultra or Display HDR post-processing,
which also gives it 16-bit targets and the `HDR` combo); in any other scene it is 1,
so a layer authored at brightness 0 is drawn in its colour, and a property or script that drives the brightness changes
nothing there (the script still runs).

A texture slot a material binds to the now-playing cover (a `usertextures` entry of
type `system`, `$mediaThumbnail` or `$mediaPreviousThumbnail`, on an image layer or
on one of its effect passes) keeps the picture its author left in that slot until
the runtime has a cover to put there. Wallpaper Engine hands the cover over as the
value of a property that only exists once a track brings one, so until then the slot
is the material's own texture: a cover layer draws its default art while nothing
plays, then the track's cover, then the art again once the cover is cleared, and a
cross-fade's `$mediaPreviousThumbnail` slot stays on its authored picture until a
track has a predecessor. `ApplySystemUserTextures` binds such a slot through
`RuntimeImageSource::BindCoverSlot`, which hands back a runtime image name that
resolves to the cover while one is published and to the authored picture while it is
not, so both renderers swap it on a version change like any cover, with no graph
rebuild and no per-frame work beyond the version check they already did. The picture
is decoded the first time a renderer asks for it, after the texture budget is known,
and stays resident so a clear costs no decode (one picture per cover name and
authored texture, whatever the number of layers that share them). The native
renderer uploads it as the file holds it, block-compressed and mipmapped, and both
renderers sample it as the file says and a cover clamped, as before. Nothing is
substituted, and the slot stays the transparent texel the cover starts as, when no
texture is authored in it, or when the authored one is a video, a sprite sheet, or a
one- or two-channel picture (a mask or a normal map: the material's shader reads
those through other channels than a cover's). The layer colour stays white on a layer
that binds a cover, as it was, so the art is drawn untinted: whether Wallpaper Engine
tints it with the layer's colour while nothing plays is not established.

Where the texture authored in a cover slot is a render target, another layer's
composite (a default cover a layer of its own draws, which a cover layer, a blurred
background and a cross-fade all sample), the slot keeps sampling that target until a
cover is published, again after the clear, and in the previous-cover slot until a
track has a predecessor; the slot was the transparent texel instead, so a cross-fade
that writes the previous cover's alpha drew nothing at all and a background built on
it was the clear colour. A target is not a picture the image source can hold, so the
material keeps the target in the slot, which keeps the graph drawing it first, and
carries the cover's name beside it (`SceneMaterial::texture_covers`); each renderer
binds the cover's image there instead while the image it uploaded for that frame is a
cover and not the empty texel. Such a pass reads an image the runtime replaces, so it
is never reused as a still target. The slot's size uniforms stay the target's, as a
picture slot's stay its art's.

An image layer's own render targets, the pair its effects run through and the
composite another layer reads, are point-sampled when the layer says
`nointerpolation` or its primary texture's header does (read from the texture's
file, not from what an earlier layer happened to load), wrapped when the layer says
`clampuvs` is off, and clamped and linear otherwise. A texture file whose header asks
for point sampling is also sampled with its mip level picked by point, as the
reference's sampler for that flag does; a texture without the flag, and a render
target, keep the blend of mip levels they always had. What a layer drawn through
effects leaves in that composite is its chain's result as the chain wrote it, the way
every pass of a chain writes into its buffers: the chain's last pass also puts the
layer onto the scene with the layer's own blending, but drawn into the composite it
replaces, so a translucent result keeps its colour instead of coming out multiplied by
its alpha, and a data buffer that keeps numbers in all four channels (an audio widget's
spectrum, which other layers read as bars) keeps them. A layer without effects leaves its
picture in that composite with source-over alpha, `As + Ad(1 - As)`, as Wallpaper
Engine's first chain buffer holds it. Every other translucent draw blends alpha with its
colour's factors, `As * As + Ad(1 - As)`, as Wallpaper Engine 2.8.0.42 does
(`sub_140099F60`), and everything a layer with `copybackground` off draws as its
children, their effects included, keeps the larger alpha, `max(As, Ad)`
(`sub_1401ECB20`). A passthrough layer with effects (a compose layer, or any model marked
`passthrough`) draws its children into its own buffer. Alpha is written into layer and
effect buffers but not into the scene's own colour buffer, unless a material asks with
`alphawriting: enabled` or the draw keeps the larger alpha; `alphawriting: disabled`
keeps it out of a buffer too. A layer whose saved size is 0 on
one axis has a card with no area, which draws nothing on screen; its render targets are
made at the size an invalid axis takes from the scene's canvas, and when it draws into
targets of its own (through effects, or into the composite another layer reads) its card
takes that size too and is drawn only there, so what its effects made reaches the layer
that reads it. A layer only 1 or 2 units thin is not such a card and keeps its size.
Whether the cursor reaches a layer follows Wallpaper
Engine's walk: only image, text and model layers that are `solid` (the default) are
tested, a plain group or a particle layer is not, and a visible layer under the cursor
with `disablepropagation` hides every layer behind it, which hears no enter, leave or
move meanwhile and keeps whatever hover state it had. An image layer is as large as
the size its scene saved; the `width` and `height` a model states (a sprite sheet's
frame) size only a layer that saved none. A project layer
(`models/util/projectlayer.json`) is as large as the scene's canvas, and the
depth-testing composition layer composes like the plain one. A composition layer
no scene object is a child of still composes when scripts may give it children: some
script creates layers and one names it by a quoted name or, with `getLayerByID` in use,
by its id; what a script then parents to it is drawn into its buffer and through its
effects, not straight onto the screen. A pass-through layer
drawn through effects, such as a project layer under a CRT effect, copies the part of
the screen it is drawn over, under the groups it sits in, not at the origin it has
within them, and follows them when a property, a script or a timeline moves them while
the scene runs. Camera parallax moves
what a composition layer holds along with its card, as Wallpaper Engine's draw loop gives
every pass of a layer the same offset: the screen its first pass reads is the place its last
pass draws it, so a layer that only copies what is behind it shows a continuous scene, not
the scene displaced by the layer's own offset. A fullscreen layer
(`fullscreen` in its model) is laid over the whole screen whichever group it sits in:
the group decides whether it shows, never where, how large or how turned, so its
effects, its result and camera parallax all treat it as the outermost layer of its own
tree. Nor does camera parallax move the layer itself: its depth is zero whatever the file
saves, so the screen it copies is drawn back over the whole screen wherever the cursor is.
With the default depth, the result of its effects was a second, shifted copy of the whole
scene over the first, with the scene underneath showing along two edges. The layers saved
below it are another matter: they are placed from the transform the scene saved for the
fullscreen layer (none saved, none added, so a post-processing
layer with no origin holds its children at canvas coordinates), under the groups it sits
in, and not from the screen centre it is drawn at; and a fullscreen layer with effects
holds those children in its own picture and runs its effects over them and over the
screen behind, as a composition layer does over its children. The children are then drawn
into the layer's screen-sized target in place of onto the scene; that cost was not
measured, and it falls only on a fullscreen layer that has both effects and children (two
local scenes have one). They are drawn there through the scene camera, as they would be
drawn on screen: a composition layer frames its children with a camera of its own, but a
fullscreen layer has none, so its children are zoomed, shaken and framed by camera shots
with the rest of the scene. A `shape` object, the quad the editor's light-shaft effect is drawn on, is a quad
as tall as the canvas on both axes, or the one `point0` to `point3` of its first effect
make; it has no texture, and its last effect, with `DIRECTDRAW` forced on, is drawn additively
straight onto the scene as the layer's own geometry, so it keeps a layer's transform,
parents, visibility and scripts. An effect of more than one pass is left out.

Desktop posters work on both backends and need no setting: each re-draws its final
composition — fit, zoom, flip and position included — into an image of its own only
when a poster is requested, including while the scene is idle or paused. The
Compatibility drawable is therefore only ever rendered to, never read back.

Where the picture sits is one layout shared by both backends, the pointer mapping and
the posters. The scaling mode and the scale factor decide how large the picture is;
whatever room that leaves around it (bars for Fit, Original size or a factor below 1,
filled by a blurred copy [under Fit with blurred backdrop](#fit-with-blurred-backdrop))
or whatever it overflows by (Fill, or a factor above 1) is split by a position, a
fraction per axis: 0 puts the picture's left or top edge on the display's, 1 its right
or bottom edge, and 0.5, the default, centres it as every wallpaper was before the
position existed. An axis with no room, such as Stretch at a factor of 1, does not
move. The engine takes the position as a live setting
(`owe_scene_wallpaper_set_framing`): nothing is rebuilt, a held video keeps its frame,
the next frame is presented once, and the position survives a surface rebuild and a
change of renderer. The Rust engine carries it with a scene's other settings
(`SceneFraming`, refused unless both fractions are between 0 and 1): it stays with the
same wallpaper across a rebuild, and a different wallpaper takes the position of its
own descriptor. The wallpaper config keeps it per display as `framing` (`pan_x` and
`pan_y`) in that display's `monitors` entry, beside the scaling mode and factor, and the
bridge hands it to the scene it builds for that display. The key is left out while the
display is centred, so an older build ignores it and a file nobody positioned is
unchanged. A hand-edited value never costs the file its other settings: a fraction
outside 0 to 1 is clamped, and anything that is not a number reads as the centre. A
mirror display is always centred, because it has its own display settings and a live
change to its source's position never reaches it. The native video player ignores the
position. The bridge moves a wallpaper on one display (`set_display_position`, an axis
passed as nothing keeps its saved value): it refuses a fraction outside 0 to 1 or not a
number instead of clamping it, saves the position at once and moves the scene that runs
on that display without rebuilding it. Like the scaling mode, and unlike the scale factor,
a position is not part of the options draft, so Apply does not wait for it, Cancel does
not undo it and Apply reopens no scene because of it. Saying the position it already has
writes nothing and tells the renderer nothing (unless a drag showed that scene at another
position first, see below), and a renderer that refuses the move leaves the position saved
for the next time the scene is built. While a slider is dragged the app calls
`preview_display_position` for the newest value: the running scene follows through
`SceneRuntime::preview_framing`, which moves the renderer but leaves the runtime, its
descriptor and the stored template as they were, so nothing is saved, no snapshot or
generation changes, the lock-screen export stays at the saved position and a drag that is
abandoned halfway leaves nothing for the next reconcile to rebuild. The bridge remembers
the scenes it previewed, so a release at the saved position still tells the scene that
position once; a display that is gone or that no engine scene draws is not an error. The bridge reports the
position to the app in each display's row of the wallpaper options (a moved display also
offers Restore defaults) and in the lock-screen and screen-saver export, which comes from
the saved configuration and so never holds a draft. The export carries it for a scene and
for a video the desktop plays natively; a web page and a mirror display are exported
centred. The inspector's Displays section offers it for scenes and videos
([display position](wallpaper-properties.md#display-position)). The lock-screen and
screen-saver extension draws a scene or video at the exported position
([lock screen](lock-screen.md#where-the-picture-sits)).

Compiled work is reused across launches where it can be. A scene's translated Metal
shaders, their reflection and their binding plans are stored in that scene's shader
cache, including the optional direct-plane program, which is prepared in the
background. Alongside them, the render pipelines Metal built are kept in a binary
archive in the same directory and handed back to Metal the next time the same
pipeline is created, so each wallpaper has its own store even when two displays
show different ones. Each of these is a separate saving and none removes the
others: a stored shader means no translation ran, a stored pipeline means Metal did
not have to produce that pipeline's compiled form again, and the first use of a
program in a process still costs some compilation whatever is cached. An archive
that cannot be read, is from another machine, or is missing is not a failure — the
pipeline is compiled as before and the wallpaper loads. All of it is regenerable and
is removed by **Clear shader cache** in Storage; nothing you imported is stored
there. The archive is written in the app's temporary folder and moved into the cache
only once it is complete, so clearing the cache while a write is due costs that
write and nothing else.

Compatibility keeps no compiled Metal code of its own. MoltenVK's pipeline cache
(`vk-pipeline-cache.bin`, beside the same scene's shaders) stores the Metal source
MoltenVK generated, which saves translating it again but not compiling it; the
compiled forms come from macOS's own Metal shader cache. That cache survives
relaunching the app, rebuilding it, a new version number and a bundle replaced at
the same path, but it keeps compiled Metal source per app location: a second copy of
the app at another path — an installed copy beside a development build, say —
compiles each wallpaper's shaders again the first time that copy loads it, once.
Compiled pipelines are shared between copies. The native backend's binary archive
stores pipelines, so it covers the smaller part. Method and what recompiles:
[renderer testing](../testing/renderer.md#metal-compile-across-processes).

### 10-bit and HDR video textures

A 10-bit video texture (HEVC Main 10, 10-bit VP9 or AV1) stays in the scene and is shown
as an SDR picture. The decoder is asked for 10-bit biplanar 4:2:0 (`x420`); the two planes
are imported as 16-bit images without a copy, and one conversion per new frame turns them
into the same BGRA image an 8-bit video produces, which every layer that samples the video
then reads. What the conversion does depends on the transfer function the stream declares,
which the decoder attaches to each frame:

- **PQ (SMPTE ST 2084) and HLG (BT.2100)**, the two HDR curves, are tone mapped. The picture
  is converted from YCbCr with the BT.2020 matrix (or whichever the stream states), brought
  to light in nits (PQ directly, HLG through its inverse OETF and the OOTF of a 1000-nit
  display), compressed with the BT.2390 EETF in linear light, rotated from the stream's
  primaries (BT.2020, or P3-D65 when it says so) into BT.709, and encoded with the sRGB
  curve. Linear light is scaled so that 203 nits, the reference white of BT.2408, is 1.0,
  and the EETF maps the stream's peak to that SDR white: the peak is the stream's maximum
  content light level, else its mastering display's maximum luminance, else 1000 nits, and
  never more than the 10000 nits the curves can express. The compression acts on the
  brightest channel of each pixel, so the ratio between channels survives it. A colour that
  falls outside BT.709 is desaturated towards its own luminance just far enough that no
  channel is negative, and scaled down if a channel exceeds one, rather than cut off per
  channel.
- **Anything else** (BT.709, BT.601, an unstated transfer) is display-referred 10-bit
  video and is not tone mapped: the codes are converted with their matrix and written as
  they decode, exactly as an 8-bit frame is. If such a stream names BT.2020 or P3-D65
  primaries, its linear light (with a 2.4 power law standing for the display) is rotated
  into BT.709 and encoded back with the same law, so mid-tones stay where they were.

A stream that declares PQ or HLG without naming primaries or a matrix is taken to be
BT.2020. The peak comes from the decoded frame's own attachments; the content light level
and mastering display boxes of an MP4 are not forwarded to the decoder, so a stream that
carries them only there is tone mapped from 1000 nits
([container readers](../container-readers.md)).

A 10-bit frame has no direct-plane path: its planes are 16-bit and belong to the
conversion, so a material that could sample 8-bit planes reads the converted image
instead, whatever [**Direct video plane sampling**](performance.md#direct-video-plane-sampling)
says, and the scene reports its video path as `yuv10_converted`. The conversion kernel is
compiled when a scene whose video is 10-bit is prepared, not before: an 8-bit video never
compiles it. The constants are in `Renderer/Engine/src/Video/VideoColorConversion.hpp` and
the kernel in `VideoConversionMetal.hpp`; `metal_video_texture_test` checks it against the
CPU reference `Renderer/Testing/hdr_reference.hpp`.

### When Native Metal cannot draw a scene

A scene Native Metal cannot draw is not drawn by anything else, and no layer, effect or
pass is dropped to make it fit. The scene is **held** instead, and the failure is said
once, with its reason, in the log and in the panel. Five things can stop a scene, each a
stage the host words in the user's language with the engine's own English explanation
beside it:

| Stage | What happened | Where the engine found out |
|---|---|---|
| `unsupported` | The admission check refused the scene (a video texture it cannot import, an unrecognised render-graph step, ...) | `SelectSceneBackend`, before any renderer exists |
| `prepare` | The renderer could not be created on the surface (also a surface with no Metal layer, such as an offscreen probe) | `createMetal` |
| `compile` | The scene's shaders or pipelines did not compile for Metal | `compileRenderGraph` |
| `frame` | A frame failed after the scene was running | `drawFrame` |
| `surface` | The renderer could not take the replacement surface after a display change | `resetSurface` |

What a held scene leaves on the display:

- **A layer that has drawn keeps its last frame.** The engine stops the frame clock and
  never touches the layer again: no drawable is acquired, nothing is cleared, nothing is
  presented over it. A scene refused while another scene was drawing (a wallpaper switch)
  also releases the outgoing scene's renderer, so a later surface rebuild cannot draw the
  refused scene on it; the layer still holds the outgoing last frame. The host's
  [recovery ladder](#recovery) still runs after a frame that fails once the scene had
  shown one.
- **A layer that has drawn nothing shows the project's preview picture.** The engine finds
  it (the `preview` key of `project.json`, else `preview.jpg`, `preview.jpeg`,
  `preview.png` or `preview.gif`, always inside the project's own folder and under 32 MB),
  decodes it once with ImageIO and lays it over the layer as a plain Core Animation
  sublayer, scaled to fill: no GPU pipeline, no per-frame work (`Renderer/Surface`,
  `StillPreview`). The first real frame that is later presented takes it away. A project
  with no preview picture shows nothing made up: the layer stays as it was, and the
  failure is still reported.
- **The host is told a first picture exists.** Its activation waits for one for up to 90
  seconds and then puts the previous wallpaper back; a held scene settles that wait at
  once, so the wallpaper stays assigned, failed and visible, instead of being rolled back
  with a message that names no cause.

The failure is published as the scene's `failure_stage` and `failure_reason` in the
bridge's `scene_renderers` row, with `backend` `unknown` (nothing is drawing it). The
engine's log line, at error level and once per failure, is
`scene cannot be drawn with native Metal (<stage>): <reason>; holding the last frame|preview picture`.
**Drawn by** words it as "not drawn — <stage in the user's language> (reason: …). Showing
its last picture.", the scene is in **Updating now** as "stopped after a rendering
failure" with **Retry**, and the diagnostics report and a library issue report name the
stage and reason. The reason itself stays English. **Retry**, or the host's recovery,
asks the native renderer again: the engine does not remember a failure against the scene.
`scene_failure_policy_test` forces each fault on a layer no window owns and checks the
failure is logged once, the frame loop stops without presenting again, and the last frame
or the preview stays in place.

### Fit with blurred backdrop

`FIT_BLURRED` (the C ABI's scaling mode 4, `fit_blurred` in a display's `monitors` entry,
`MatchBlurred` across the bridge) lays the picture out exactly as Fit does, position,
scale factor and pointer mapping included, and fills the room around it with a blurred,
darker copy of the same live picture instead of the clear colour
([user-facing behaviour](wallpaper-properties.md#fit-with-blurred-backdrop)). The layout
(`ComputeWallpaperScalingLayout`) adds `backdrop_px`, the picture as Fill at a factor of 1
places it, centred whatever the position, and `backdrop`, whether the picture leaves room:
a gap of one pixel, the most rounding leaves when the shapes match, is none. The copy is
drawn only into that room (`ComputeWallpaperBackdropBands`), so the picture's pixels are
Fit's byte for byte. Both backends build the copy the same way
(`Presentation/WallpaperBackdrop.hpp`, `MetalWallpaperBackdrop`, `WallpaperBackdropPass`):
the scene's output is reduced to an image 128 texels on its longer side, a picture longer
than 1024 texels first to an eighth of its size in an 8-bit image, with bilinear taps at
most four texels apart; HDR linear output keeps that first reduction half-float so
highlights are not clipped. That uses four additional bytes per first-reduction texel
but no extra reduction or blur pass. The image is blurred by a separable Gaussian of 3 texels, then
stretched over the room through a cubic B-spline, darkened to 70% and dithered by one
8-bit step. A quarter of the source texels is read: reading all of them cost about three
times the GPU time on a 6880-wide raster (below), and the copy is blurred over about 160
source texels, so by estimate a one-pixel line moving in and out of the taps changes it by less
than one 8-bit step (not measured with a moving fixture). The posters draw it too, since
they compose the same picture again. A scale factor or a position change moves the
picture and not the copy.

Nothing of it exists in any other mode: the pipelines are built when the mode is chosen,
between frames (a pipeline built inside a frame would hold it on the shader compiler),
and the images (two half-float ones and, for a large picture, the 8-bit one) exist only
while a composition has room to fill and go on the first frame that has none. The present
key carries the copy's rectangle, so switching between Fit and this mode presents again,
and a frame that repeats the picture still repeats the copy and is skipped as before.
On Compatibility, a plain video keeps presenting straight from its decoded frame
(`CustomShaderPass::recordPresentation`): that frame is texel for texel the scene output
the copy would otherwise be made from, so the copy is made from it and drawn first. A
mirrored picture takes the copy path as before. The native video player has no copy and
shows Fit's black bars. `SceneWallpaper` ignores a scaling-mode value it has no mode for,
instead of casting it into an unscaled layout. An app that predates the mode reads
`fit_blurred` as Fill.

Cost, measured headlessly on an M3 Max (macOS 27.2) with
`UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly` and `WE_TEST_ENERGY_SCALING`
([renderer testing](../testing/renderer.md)), three or four alternating 15-second rounds
per case at 60 FPS, while another copy of the app was drawing the desktop and other apps
used the GPU (medians of the GPU time of the process's own command buffers per 60 Hz
tick, Fit against this mode):

| Wallpaper, surface | Renderer | Fit | Fit with blurred backdrop |
| --- | --- | --- | --- |
| 3840x2160 scene, display resolution, 6880x2880 @2 | Native Metal | 5.96 ms | 6.50 ms |
| the same, 4112x2658 @2 | Native Metal | 5.17 ms | 5.04 ms (within the noise) |
| the same, 6880x2880 @2 | Compatibility | 5.81 ms | 6.11 ms |
| the same, 4112x2658 @2 | Compatibility | 4.90 ms | 5.35 ms |
| 3840x2160 30 FPS HEVC clip, 6880x2880 @2 | Compatibility | 0.25 ms | 0.54 ms |
| the same, 4112x2658 @2 | Compatibility | 0.26 ms | 0.32 ms |

The clip presents on every other tick, so a presented frame costs about twice its share
here. Every run kept its frame rate. In the quietest rounds the GPU as a whole drew 0.1
to 0.2 W more and the process's CPU about 8 mW more. These figures are coarse: one case
measured up to twice as long from one run to the next, so differences under about half a
millisecond are not resolved, and on Compatibility the time also counts waiting for a
drawable. The images hold about 2.0 MB on the ultrawide's 6880x3870 display raster,
1.2 MB on the panel's 4726x2658 one and 0.86 MB for a 4K clip, on either renderer. With
Fit, the composition records exactly the commands it recorded before the mode existed,
plus two words of presentation key; a Metal System Trace shows the same 37 render passes
a frame for the Compatibility scene, before and after. The native time goes to the first
reduction (about 0.3 ms on the 6880-wide raster), the second step and the two blurs (about
0.15 ms together) and the bands (about 0.05 ms); on Compatibility each of the small passes
costs 0.1 to 0.17 ms. Earlier versions show what the design avoids: one pass straight to
the small image, reading every texel, took about 3.4 ms for the clip, and a first
reduction reading every texel took about 0.95 ms on the 6880-wide raster against 0.3 ms.

### Wallpaper Engine's per-wallpaper options

Wallpaper Engine adds its own options to every wallpaper's properties (wallpaper64.exe
`sub_140104B60` builds them; `sub_140181F30` and `sub_140115280` apply them to a scene;
the decompiles are in `artifacts/we-parity/decompiles/H-P0-2.md` and `D-14.md`). The
renderer takes them through `owe_scene_wallpaper_set_user_options`:

- **Colour options** (`wec_e`, brightness, contrast, saturation, hue shift, sliders 0–100
  with 50 unchanged) and the **image filter** (`wcc_v`, a LUT under `materials/lut`, with
  its strength `wcc_amt`, default 100) are WE's `materials/util/ccsimple.json` pass, drawn
  after bloom and its combine. Its `params` are `(pow(brs/50, 2), pow(con/50, .5),
  pow(sa/50, .5), hue/100 − .5)` and `lutparams` is the strength / 100. As in Wallpaper
  Engine the pass is not built at all while every slider is at 50 or the colour switch is
  off, and while no filter is chosen or its strength is 0, so an untouched wallpaper costs
  nothing. A LUT is a volume `.tex`, sampled in three dimensions.
- **Flip horizontally** mirrors the presented picture and the pointer through the same
  path as the `horizontal_flip` property.
- **Mouse parallax** off holds cursor-driven camera parallax in the centre
  (`g_ParallaxPosition` reads 0.5, 0.5 and no draw moves with the pointer); the scene's
  own parallax settings are kept for when it is on again.
- **Playback rate** (10–200 %, default 100) is offered for scenes too: Wallpaper Engine
  runs a scene's clock at `max(rate / 100, 0.1)`, which the renderer applies as its speed.

Set before a load, the options are in force for the first frame. On a running scene a
change of a value, the flip, the rate or the parallax switch is applied without loading
again; turning the colour pass or the filter on or off, or picking another filter, loads
the scene again because the pass is built when the scene is parsed. A parallax change
builds the render graph again once.

The bars a fitted picture leaves (Fit, Original size, a scale below 1) take the project's
`schemecolor` property, followed live, and stay black without one; the blurred backdrop
fills its bars itself. Wallpaper Engine also clears the scene's own canvas with that
colour for those alignments; here the scene keeps its authored clear colour inside the
canvas, because Fit, Original size and scale keep this app's meaning.

The inspector's [**Wallpaper Engine options**](wallpaper-properties.md#wallpaper-engine-options)
section edits them per wallpaper; a scene loads with the saved ones
(`WallpaperConfig.engine_options`), and Apply changes loads it again when they change. While
an edit is pending a scene follows it live through `preview_user_options`, the options'
counterpart of the live property edits below: the engine skips options a scene already shows
and a reload shows the saved ones.

Compared with Wallpaper Engine 2.8.0.42 on 3662790108 with brightness 60 set through
WE's `-control applyProperties` (`artifacts/we-parity/compare-10.1`): the median
brightness ratio of the solar system's lit pixels is 1.435 in Wallpaper Engine and 1.439
here (1.44 expected), and the region means move from 12.2 to 17.6 and 17.5.

### Live property edits

The renderer can take a whole property document on a running scene instead of
loading the scene again. The document is the project's declared defaults with
exactly the given values over them, so a property it leaves out is back at the
declared default whatever the scene loaded with. It adds no per-frame work.
[Wallpaper Engine's per-wallpaper options](#wallpaper-engines-per-wallpaper-options)
follow an edit the same way, sent beside the document (`preview_user_options`).

Nearly every property is a live binding and follows on the next tick: layer
visibility, alpha, colour, origin, scale and angles, camera, clear colour, bloom
strength, threshold and tint, parallax delay, the scene zoom, camera shake,
shader constants, rope and particle values, text, puppets, and the values a
script reads and reacts to. A few readers decide once, while the scene loads, and
are **load-only**: a material slot that a `scenetexture` property picks, an
effect an on/off or combo property builds or leaves out (every hidden effect
would otherwise cost passes and memory), and the scene's bloom switch and its
parallax switch, amount and cursor influence, which decide whether the bloom
passes exist and which passes follow the cursor. A scene setting bound to a
property loads with the property's current value, saved choices included. A preview of a document holds a
load-only property at the value the scene read, for every layer that uses it, and
reports it as deferred; only loading the scene applies it. An effect whose
`visible` a script decides is different: it is built with its layer and
follows the script, as Wallpaper Engine's effect object does. That script's
`thisObject` is the effect: writing `thisObject.visible`, from an event handler
as from `init` or `update`, switches the effect and leaves its layer as it is (it
showed or hid the whole layer, over a property that had hidden it). A switch resolves
the layer's effect chain again over the effects that run and rebuilds the render
graph before the next frame, so nothing is paid per frame. While a script has
every effect of a layer off, the chain ends in a passthrough: Wallpaper Engine
draws such a layer as one without effects, so that state costs one layer-sized
pass more here, and a text layer is then plain text, without its effect padding and with its
glyphs going straight onto the scene by their alpha. A text layer whose every effect is off
in the scene file, or by a property as the scene loads, is drawn as plain text,
as Wallpaper Engine draws it: an effect that is off builds no chain. A sound layer's volume
is live too: a slider bound to it sets the stream's volume when the slider moves,
and nothing else does, so a volume a script set stays until its own slider moves.

A flag bound to a string property reads the string as a flag. The case that
matters is a layer or effect `visible` that names a combo property with no
condition (`{"user": "mode", "value": true}`, which is what a toggle the author
later turned into a combo leaves behind): it gets the choice as a string, and a
string is a true flag when it is `true` in any case or `1`, the reading every
string project property already has; any other choice is false. The rule belongs
to the flag, not to the layer. Every bool a setting binds to a property by name
reads a combo, text input, file, directory or texture property so (a layer's or
effect's `visible`, a puppet animation layer's, the camera shake's and the
load-only bloom and camera-parallax switches, a rope's `uvscrolling` and
`uvsmoothing`, a text layer's outline, blur and shadow switches), so a bare flag
bound to a text input whose text is `1` or `true` is on. A string a script returns
for a flag is read the same way on every tick it runs, by a comparison in place
that makes no copy. A binding that names a condition compares the choice with it
instead, so `{"user": {"name": "mode", "condition": "2"}}` is on exactly when the
choice is `2` and never by the rule above. The bound value is then a flag, not the
choice: a script property bound this way reads `true` or `false`. It used to read the
choice itself, a string such as `"2"` that is true in JavaScript whatever it says, so
a clock offering its date formats as three flags over one combo (conditions `0`, `1`,
`2`) always took the first one it tested. A shader constant bound with a condition
now reads 1 or 0 as well, where it read the choice as a number; no wallpaper is known
to bind one so. Wallpaper Engine draws a layer bound
this way at the combo's default `1`; what it does with another choice is not
established, so those follow the rule. A number bound to a choice without a
condition still reads 0, because nothing shows that Wallpaper Engine converts a
choice to one.

A combo whose `project.json` `value` is a number reaches the scene as a number, so
a flag bound to it is on for any whole number but 0, `2` included, for as long as
the combo keeps its authored value. A choice the app sends is the option's key, a
string, and `2` is off then; the two differ only for choices other than 0 and 1.

A running scene takes the document through the wallpaper property
`project_property_preview_json`, one flat JSON object holding the whole state. The
main looper parses it (anything that is not a JSON object is logged and changes
nothing) and stages it in a latest-wins slot; the render thread, the only thread that
ticks the runtime, shows it with `PreviewProjectPropertyOverride`. A burst of
documents therefore costs one update: while the render thread is busy only the
newest is kept, and one command is queued behind the one it waits for. Like every
command except the draw, it asks for a frame, so an idle scene draws one and a
paused one shows the change when it resumes; it registers no time-advancing work, so
the idle analysis is unchanged. A layer the document reveals that the render graph
left out is shown by that frame's tick, which asks for one new graph before the frame
is drawn, as a script showing the layer does (new pipelines may compile, so that
frame can take longer); a layer it hides again keeps its passes until the next graph
is built, which leaves it out once more.

A preview is transient. It never reaches the saved override, so a scene that is
loaded again for any reason (Apply, a display change, waking, a wallpaper switch)
shows the saved look, and nothing is replayed to the scene that replaces it: a
document is for the scene running when it is shown, and a document that arrives
before the first scene exists is dropped. The lock-screen and Mission Control
pictures are not involved. Properties held at their loaded value are logged once,
as a set, when it changes.

The Rust engine sends the document with `WallpaperEngine::preview_property_override`,
the property counterpart of the framing drag preview. It parses and flattens the
document with the code `set_property_override` uses, so a document that is not a JSON
object, has an array leaf or is not JSON is refused before the actor is asked and never
reaches the renderer, and it then sets the preview property through
`SceneRuntime::preview_property_override_json`. Unlike `set_property_override` it asks
for no shader refresh and loads nothing, and it records nothing in the runtime: the
runtime's saved override, its descriptor, the stored scene template and the published
snapshot stay as they were, so the next reconcile still compares the saved configuration,
an edit that is abandoned leaves nothing to rebuild, and a rebuilt renderer shows the saved
look. `set_property_override` and `reset_property_override` keep their meaning, a reload that
remembers (or forgets) the override.

The call names the project file of the wallpaper the document was made for, and returns
`PropertyPreview::Shown` or `PropertyPreview::OtherWallpaper`. A handle names a display's
scene, not a wallpaper: a reconcile that is still under way (an Apply, a playlist or schedule
switch, a mirror change) replaces the renderer inside the same `SceneRuntime`, keeps the
handle, and commits the bridge's configuration only after it finishes, so for that long the
bridge can still find the first wallpaper's handle on a display that already runs the second.
The engine handles the call after that reconcile, not before, so it compares the scene's
`scene_path` then (`preview_on_scene_of`) and leaves a scene that draws another wallpaper
alone. This is what keeps the invariant above: the document of one wallpaper cannot reach
another by sharing property names, however the bridge's picture of the displays lags.

The engine also keeps what each scene was last shown. `OweScene` records the document it
took from a preview and drops the record when the scene is loaded again through
`set_property_override` or `reset_property_override`; a replaced renderer is a new object and
starts without one. Nothing else needs to remember to forget it, so every path that rebuilds a
scene is covered (a descriptor change, a shader cache clear, the wake check's repair, the
engine's own recovery of a failed frame), including the ones the bridge never sees. A scene
that already shows the document is not sent it again, and a refused update leaves no record,
so asking again sends it.

The bridge sends it with `preview_wallpaper_properties(wallpaper_id, show, pending)`. The
document is built from the whole draft, so a property the draft restored is back at its authored
default, by the function that builds a scene descriptor's document: it is byte for byte
what Apply would load, except that a texture, a file and a folder stay at their saved
value (a texture is read only while a scene loads, and a file or folder is saved the
moment it is picked). It goes to every scene that draws the wallpaper, mirrors included
(they run a scene of their own), and to nothing for a video, a web page or a wallpaper
no display shows. It saves nothing and leaves the draft alone, and it advances no
generation and builds no snapshot, so a reconcile that is already under way is not made
stale; the lock-screen export follows the saved configuration, and the app keeps the
Mission Control picture at the saved look by not taking it from a display that may be showing
an edit and by taking it again when the edit ends
([desktop picture](desktop-picture.md#when-a-poster-is-taken)). A wallpaper that is not being
previewed and whose saved look is asked for sends the engine nothing, and a scene that already
shows the document is not told again, which the engine decides, not the bridge: the bridge
keeps no copy of what a scene shows, because anything that loads a scene again would leave the
copy wrong, and most of those never pass through the bridge. It keeps only which wallpapers it
showed an edit on (`previewed_properties`) so that **Revert** (`cancel_wallpaper_options`) puts
the saved look back on those scenes before the draft is cancelled, and asks again if the engine
refused: a refusal leaves the draft dirty. `show` false does the same restore without
cancelling anything. **Apply** forgets the mark, because it loads the scene again from the
saved configuration. A scene the engine declines because it now draws another wallpaper is
skipped, not an error: there is nothing of this wallpaper on it to show or to put back, and
when no scene is left the mark goes too. Anything that loads a scene again (a display change,
waking, a shader cache clear, a recovery) shows the saved look, and the next edit shows the
draft again, even one that leaves the document as it was.

`pending` holds the values of sliders and colours the person is still dragging. Each is
checked by the function `edit_property` uses and made to a copy of the draft, in order,
for the document of that call alone (`WallpaperOptionsDraft::with_edits`), so the scenes
follow the drag while the draft, the dirty state and the saved options never hear of it,
and a call that does not name the value shows the draft again. One the property does not
accept refuses the whole call before any scene is told anything. `wallpaper_preview`
takes the same list for the preview window's export.

The app asks for it from `BridgeStore` after each property edit while [the Settings
switch](wallpaper-properties.md#showing-edits-on-the-desktop) is on; the preview window
has its own scene and follows the draft whatever that switch says.

### Scene render optimisation

The only scene control that ships on. It reuses the result of scene subgraphs whose
inputs have not changed and removes render passes proven redundant, inside the scene
renderer's own render graph. It is not a quality tier: the same pixels are
produced, and resolution, frame rate and animation speed are untouched. It reaches
the wallpapers the scene engine draws, which are scenes only: video and web
wallpapers have players of their own and do not go through it. It is on the
[Performance page](performance.md#advanced) so it can be turned off and on for an
A/B comparison without an environment variable.

Its row reports the saved preference: the renderer publishes no query for
it. The engine applies a change to a running scene in place, on that scene's next
frame in either direction — the copy plan, the targets it governs and the reuse
table are rebuilt over the graph that is already compiled, without reparsing the
project, reopening a video or resetting a timeline — so nothing restarts and no
wallpaper reloads. The **In force now** row beneath the switch reports what each
running scene is actually under, so a preference that has not reached a scene yet is
visible as such.

A pass that samples a scene video is reusable like any other while the video
shows the frame the pass drew: which import of the video it samples (a new frame,
or the same one taken again for a consumer that changed what it reads), and whether
it reads it through its plane variant, are part of what decides it. A clip slower
than the frame rate, or a paused one, therefore leaves its chain and everything
downstream that nothing else moves undrawn on the frames it repeats; a playing video
still keeps the scene's clock running.

A pass that reads the audio spectrum is reusable in the same way while the spectrum
arrays its shader binds (`g_AudioSpectrum16Left` to `g_AudioSpectrum64Right`) hold the
bands it drew: the frame's one spectrum, as its uniforms are given it, is part of what
decides it, every band of every array it binds and no array it does not bind. Silence
is a spectrum of zeros, so an audio visualizer and everything downstream that nothing
else moves stays undrawn while nothing plays (or audio response is off), and so does a
spectrum that repeats; any band changing redraws it on that frame. A frame drawn before
the host's first frame, when two reads may see two analyses, redraws it. An
audio-reactive shader still keeps the scene's clock running. A material slot the shader
never samples was already left empty when the scene was parsed, so an effect that
declares the layer's picture and draws without it (a visualizer built from the spectrum
alone) does not depend on the buffer named there either. Being reusable, such a pass keeps
its buffer to itself instead of sharing it with other targets, inside the same reuse memory
budget as any other reused pass (on 3784370784, two 768x768 buffers, about 2.4 MB); while
music plays it is redrawn on most frames all the same.

A layer's own picture and its effects up to the last are drawn into the layer's own
buffers, through a camera local to the layer, so where the layer sits and where the
scene camera looks reach them only through the uniforms that say so: the effect
matrices (`g_EffectModelViewProjectionMatrix` and its kind), the eye and view axes,
lights, puppet bones and the cursor. Such a pass is reused while the layer moves (an
animated parent, a bone it is attached to, a script) or the camera shakes, unless its
shader reads one of those uniforms. What it reads is what the shader compiler proved
can reach the picture, not what it declares: Wallpaper Engine's image shader computes
a view direction from `g_EyePosition` in every variant but uses it only when lit. The
last pass, which puts the layer on the scene, follows the layer and the camera and is
drawn again either way, and so is a composition layer's first pass, which reads the
screen behind the layer. The reused buffers hold the same pixels, but the frame is not
always byte for byte the same: in a scene sorted by depth (sorted transparency), and in
any scene whose objects are drawn in their own order with
[render pass merging](#draws-into-one-image-share-a-render-pass) switched off, a layer's buffers
sit between two draws into the scene's image, and leaving them out lets those draws share
one render pass that drawing them splits in two. An Apple GPU can then blend a later draw
one level apart in a texel: an M5 Pro did in two pixels of a few frames of 3808922316 at
3456x2234@2, where the reuse leaves out 17 passes a frame (about 8 % of its GPU time).
That difference is accepted for the saving; `WALLPAPER_MACHINE_LAYER_LOCAL_SIGNATURES=0`
draws such passes again whenever the layer or the camera moves, for comparison.

Reuse needs a target that is both cacheable and holding a pinned allocation,
because the render-target pool may otherwise hand that image to another key.
Pinning is bounded by a memory budget; when a graph's targets do not fit at the
current output size nothing is pinned, and the per-frame sampling and signature walk
that decide what to reuse are skipped outright, since their only reachable answer is
"draw everything". The budget itself is unchanged; a target that cannot be pinned
still redraws.

### Draws into one image share a render pass

Native Metal draws consecutive passes into one image in one render pass. Every further
render pass on the scene's image stores the whole picture and loads it back: at
3456x2234@2 with Fill, a 3972x2234 image, 35.5 MB each way per frame (less what the
GPU's lossless compression saves). Of the 91 installed scenes of the development
library, measured at that size, 66 drew the scene's image in more than one render pass,
351 splits in all. 292 of them are real dependencies and stay: a layer's effect or a
composition layer samples the scene's image as the layers before it left it (158), or a
draw samples the image it draws into, which reads a copy made between the two render
passes (134). The other 59 were not, and two rules remove all but one of them (a layer
drawn into a picture that an earlier layer reads from the previous frame can still land
between two draws into the scene's image):

- **The objects' own order.** In a scene whose layers sample another layer's picture
  (or with a planar reflection), every pass of one object used to run before the next
  object's first, so a layer's own effect buffers sat between the draws into the scene's
  image before and after it, and each such layer split the scene's render pass (37
  splits, in 9 scenes). Unless the scene sorts transparency by depth, which moves whole
  objects while the scene runs, the passes are now ordered by what they read and write,
  as every other scene's are, and the scheduler draws a layer's buffers ahead of the
  draws into the scene's image. A layer that samples another layer's picture still sees
  this frame's picture of an earlier layer and the previous frame's of a later one, and a
  layer that samples the scene's image still runs between the draws it reads.
- **The depth attachment.** A render pass has one depth attachment or none, so a draw
  that does not depth-test between two draws into the same image that do (a flat layer
  or text between two 3D models) ended the render pass on both sides, and the image's
  colour and depth were stored and loaded back each time (22 splits, in 2 scenes). Such
  a draw now takes that image's depth attachment, with depth testing off. That holds only
  for an image all of whose draws are single-sample, and only for a draw between the
  image's first and last depth-tested draw that reaches one of them through draws into the
  same image alone: the flat layers before a scene's first model or after its last take no
  depth attachment, and neither does one that passes on other images cut off from both models,
  which would only load and store the depth. A scene that sorts transparency by depth
  puts its objects in a new order as it runs, so its draws keep their own render passes.

Sharing the depth attachment leaves the picture byte for byte the same. Drawing a layer's
buffers ahead joins draws into the scene's image that the object order kept in separate
render passes, and an Apple GPU can then blend a later draw one level apart in a few
texels, the same effect the [layer-local reuse](#scene-render-optimisation) accepts; the
synthetic scene `MetalSceneDraw.AMovingLayerBetweenTwoCardsIsReusedAndJoinsTheCardsRenderPasses`
draws allows at most that against the old order. On real wallpapers no difference was
found: `perf_bench.py identity` matched a build without the change on every compared frame
of 3808922316, 3662790108, 3226487183, 3624257712, 3521337568, 3255418892 and 3610485014
(3784370784, 3589454154 and 3276911872 differ between two runs of the same build and were
not comparable). Per frame, at 3456x2234@2:

| Scene | Render passes on the scene's image | Loading their target | MB loaded |
|---|---|---|---|
| 3808922316 | 32 → 11 | 27 → 6 | 958 → 213 |
| 3662790108 | 27 → 4 | 26 → 3 | 804 → 93 |
| 3226487183 | 11 → 7 | 13 → 6 | 455 → 213 |
| 3784370784 | 21 → 19 | 20 → 18 | 946 → 852 |
| 3624257712 | 7 → 4 | 6 → 3 | 213 → 107 |
| 3521337568 | 8 → 6 | 5 → 3 | 178 → 107 |
| 3255418892 | 6 → 4 | 13 → 11 | 143 → 72 |
| 3276911872, 3610485014, 3589454154 | one fewer | one fewer | 35.5 or 31 less |

3662790108 also stores its depth 3 times a frame instead of 14. Paced at 60 fps on the
built-in panel's surface alone (`perf_bench.py cost`, a build without the change against
one with it, 5 pairs in ABBA order on an M5 Pro, the app's own coalition), the GPU drew the
same frames for less power: 3808922316 from 4.36 to 3.84 W (-12 %, every pair, the 95 %
interval -0.56 to -0.50 W) in the same 6.7 ms a frame; 3226487183 from 7.96 to 7.24 W
(-9 %) and 3662790108 from 27.5 to 26.0 W (-6 %), each in every pair taken but with pairs
lost to the machine leaving nominal thermal state, so short of the three-pair verdict.
3624257712 (-0.6 W) and 3521337568 (-0.07 W) moved within their spread. Where the GPU time
does not move, the saving is memory traffic: the GPU spends as long but reads and writes
far less. The back-to-back GPU time of the changed scenes moved within the
harness's run-to-run spread, which on scenes the change does not touch was -16 % to
+18 % during the measurement; every one of the 91 scenes still draws. Drawing a layer's
buffers ahead keeps them alive across the draws they now precede, so buffers that took
turns on one image no longer can: the render targets take 62 MB more on 3808922316 (516
to 578 MB), 28 MB more on 3226487183 (396 to 424 MB), 2.7 to 4.3 MB more on 3662790108,
3610485014 and 3784370784 and the same elsewhere, never more than the targets take
without sharing (`WALLPAPER_MACHINE_METAL_TARGET_SHARING=0`).
`WALLPAPER_MACHINE_SCENE_PASS_MERGE=0` restores the order and the attachments as they were
([A/B switches](../testing/power-benchmark.md#ab-comparison-entry-points)).

What still splits the scene's image is mostly a draw that reads it: a blend mode or a lens
that samples the picture under it through a copy. Where such a draw reads only its own
pixel, an Apple GPU could read the destination inside the same render pass (programmable
blending) with no copy and no split, once the shader compiler can prove the read is of
the fragment's own texel.

### 2D scene resolution

A scene with an authored canvas is rasterized at the size it is presented at on the
display by default (**Display resolution**), or at the canvas's own size (**Canvas
size**), and the internal render scale divides whichever is chosen. Both renderers
size their render targets from one shared function
(`ResolveScreenBoundRenderTargetSizes`): the default target and every target that
follows the screen come from the raster, a target the author sized keeps scaling
with the render scale alone, and the canvas stays the source extent of layout,
cursor mapping and scripts. SDR uses the Fill layout of the canvas over the
output in whole points, at the display's backing scale, and draws that whole
canvas-cover raster. With the experimental SDR display framing on
([**Draw only the visible part of cropped scenes**](performance.md#draw-only-the-visible-part-of-cropped-scenes),
`scene_display_framing`; off by default), an SDR scene draws only the window of that
raster the composition reads (`SceneRasterWindow`): the
bilinear pairs under the output's pixels, rounded out to whole texels of the cover
raster and to the grid of every screen-sized target the graph names at a fraction
of it (a quarter-size buffer needs a window cut at multiples of 4). The window is
drawn at the cover raster's pitch and phase and the composition lays it where its
texels sit in that raster, so the visible picture is the whole raster's except
within a screen-space effect's reach of the window's edge, which then clamps there
as Wallpaper Engine's window-sized frame does. It is not byte-identical: the GPU
does not rasterize a translated projection to the same sub-pixel positions, which
leaves single-level differences on a fraction of a percent of pixels at content
edges in some frames, and more on thin geometry. A cover raster that is not a multiple
of that grid, a mip-mapped screen-sized target, a capped raster, a zoom below 1, Fit,
Stretch, original size showing the whole canvas, Fit with blurred backdrop and a scene
MetalFX upscales (render scale below 1 with MetalFX upscaling on: it would upscale the
window on another grid and its filter reads across the window's edge) draw the whole
cover raster. The window is sized for a
zoom of 1, so the Zoom slider moves it without a resize; the first move of the
picture off the centre sizes it once with room for any position, and a layout it no
longer holds, the switch turned on or off, or MetalFX taking or leaving the upscale
sizes the targets again before the next draw (`ResizeRenderTargets` semantics, no
graph rebuild); a poster is not composed from a window the layout no longer holds.
With the switch off a draw only reads the switch (the compile still notes the
window's grid), and the frames are byte-identical to those of a build without the
window (`perf_bench.py identity`).
`WALLPAPER_MACHINE_SDR_FRAMING=1` or `=0` overrides the setting either way, read once
at launch. Native HDR Display output
uses the physical output rectangle: placement and clipping happen before bloom,
so its edge samples see the same boundary as Wallpaper Engine. Fit with blurred
backdrop keeps the full canvas-cover raster that the backdrop samples. Canvas size
keeps the authored raster. The device's largest texture caps these extents. A
perspective scene and a plain video do not read this resolution choice.

The HDR placement uses a lazily cached shader projection for each camera that needs
one; script coordinates and cursor queries keep the authored camera. Local effect
buffers stay local, while scene-sampling matrices and their inverses use the framed
projection. Pass-through layers whose shader samples the screen at their texture
coordinates also update those baked scene UVs when placement changes: moving cards
use their existing geometry upload, fixed cards request the existing graph rebuild.
A compose layer's card (`composelayer`, such as a project layer over the whole
canvas) finds the screen position it samples through the framed projection, and its
texture coordinates only place it in its own buffer, so they are left as they are.
These updates run at layout events; idle frames add no card scan or relayout. Crossing into or out of Fit with blurred backdrop rebuilds the
raster before the next draw. The change adds no rendering pass or target and usually
reduces the HDR framebuffer area compared with the canvas-cover raster.

The choice is process-wide, like [scene render optimisation](#scene-render-optimisation):
a scene takes it when its render graph is built, and the host hands every open scene
its render scale again when the choice changes, so a running scene resizes its
targets in place (`ApplyRenderScale`), on the render thread and without a reparse.
The resize is skipped for a scene that has no canvas to rasterize, so a perspective
scene or a video does not pay a graph rebuild for it. A surface that is replaced (a
display change) rebuilds the graph and with it the raster. What it costs, and why a
bloom scene pays more than one with author-sized buffers, is under
[Performance](performance.md#2d-scene-resolution).

### Frames that would repeat the picture

With scene render optimisation on, a frame that would put back exactly the picture
already on screen is not drawn, submitted or presented, and the surface keeps
showing the last frame. That is a scene whose every pass was reused from the
previous frame or drew nothing, with nothing else to encode, leaving only the final
composition to redo. A frame that imports a video frame never qualifies; one whose
videos all show the frame they showed before (a 24 or 30 fps clip on a 60 Hz clock,
a paused video) can, since the passes that sample them are reused too.

The frame clock still ticks at the configured rate, and the scene still runs its
scripts, timeline, sound and events on every tick; only drawing an identical
picture is left out. This is not updating only when the scene changes, and no
drawable is held to keep the picture. A resize, fill, scaling,
position or flip change, a render-scale or scene-optimisation change, a rebuilt graph or
surface, a resumed wallpaper, a failed frame or a poster request makes the next
frame present. The renderer counters report these frames as
`presents_skipped_unchanged`, apart from dropped draws and present requests. Native
Metal takes a drawable only after the scene's passes are encoded, so a frame that
repeats the picture takes none.

### Update only when the scene changes

Off by default, because stopping a wallpaper's clock changes what the user sees
happen. When a scene can be shown to have nothing that advances on its own, its
frame clock stops entirely instead of ticking at the configured rate: the last
frame stays on screen and events restart it. This is not a frame-rate setting and it
lowers no quality. It is also not the same question as scene render optimisation,
which asks whether a render target's pixels can be reused; this asks whether the
whole runtime can sleep. A scene whose image happens to be still may still be
running scripts, sound and timelines, so both analyses must agree before anything
stops.

A scene keeps its clock if any of these is present: a script or scripted property,
an animation, a particle emitter, a playing video texture, an audio-reactive
shader, a time uniform, an animated sprite, geometry rebuilt every frame, a puppet,
a feedback pass, a text layer whose content is computed every tick, a sound layer,
a node transform or material constant driven by a script or an animation, text
whose new layout has not reached a frame yet, or any input the renderer could not
account for. That last one is reported as **an input the renderer could not account
for**, and it is the answer when a wallpaper does not go idle. The list turns on
what *is* changing rather than what *can* change: a text layer's card is rewritten
when the text is re-laid out, and a layer's visibility is a binding whether or not
anything ever moves it, neither of which means the scene has work to do. A static
caption, a caption the user's own property supplies, an image replaced only when a
resource arrives, and any of those under a supported effect chain all stop their
clocks; the same layer driven by a script does not.

Pointer-reactive scenes do sleep, and pointer movement wakes them. Property
changes, resizes, display reconfiguration, resource updates, poster requests and
visibility changes all wake the scene, as does a text layout finishing on its own
thread; a wallpaper the user paused is never woken by any of them. Writing a
caption the layer already has is not a change and wakes nothing, which keeps a
script that returns the same string from defeating the feature.

Waking is not a licence to draw. The configured frame rate is a ceiling on every
path into a frame, not only on the periodic one: a request, a one-shot appointment
and an appointment already past all wait until one frame period after the last
frame, so a burst of pointer samples coalesces into one frame per period. After a
quiet stretch longer than that period the first event draws immediately. Content
pacing can make the *cadence* longer than the ceiling and an event may cut that wait
short, but only as far as the ceiling. A request is never discarded to enforce any
of that: it stays outstanding until a draw consumes it, so a tick dropped because a
draw was still in flight loses the tick and not the update, and the end of that draw
re-arms the clock — one wake at that edge, not a retry per frame period.

The frame period is the configured rate's to the nanosecond, rounded up so the clock never
runs faster than asked (16 666 667 ns at 60), and never shorter than the period of the
display the scene is on, read from the display's current mode. A 59.94 Hz display is a 60 Hz
one wherever a whole number of hertz is wanted, including its rate ceiling, so frames at 60 a
second would outrun it; they come at its own 59.94. Whole microseconds (16 666 µs) made 60.0024
frames a second, one more than a 60 Hz display shows every seven minutes. Either way the
drawable queue ahead of the display then filled and stayed full, adding two frames of latency
and a wait for a drawable to every frame (`FrameTimerTest.TheCadenceIsTheExactPeriodOfTheRequiredFps`,
`.TheCadenceNeverOutrunsTheDisplay`).

A frame rate below the display's reaches it an even number of refreshes apart. The frame clock
is not driven by the display, so a 60 fps cadence on a 120 Hz panel can sit within a
millisecond or two of a refresh boundary for minutes, and the render time's jitter then shows
neighbouring frames one and three refreshes apart instead of two and two: a stutter on slow
pans, parallax and drifting particles. When the frame period spans two or more refreshes,
Native Metal presents each frame with `presentDrawable:afterMinimumDuration:` and a hold of
those whole refreshes less a quarter refresh (14.58 ms at 60 on 120 Hz): the frame shows no
sooner than the refresh the cadence aims at, on a fixed-rate panel and on a ProMotion one, which
can also refresh at the half-steps between. A frame that is late still shows at the next
refresh, and the frames after it are held from it, so one late frame costs one longer gap
instead of a run of uneven ones. The hold counts whole refreshes rounding down, so frames never
reach the display more slowly than the clock makes them: a ceiling at or above the display's
rate (one refresh or less), a display of unknown or variable rate, and a frame period just
short of two refreshes (30 fps on 59.94 Hz) present at the next refresh as before. The pixels of
every frame are the same either way; what changes is when a frame is shown, and a frame that
would have been shown a refresh early is shown a refresh later, which can add up to one refresh
of latency to a pointer-reactive scene. Content pacing and events do not lengthen the hold: it
follows the ceiling. `WALLPAPER_MACHINE_VSYNC_PACING=0` presents every frame at the next refresh
(`PresentPacingTest.*`, `MetalSceneDraw.APresentHoldsTheFrameOnlyWhilePacing`).

Both renderers implement this. The status line reports what each running scene is
doing right now — updating continuously and why, waiting for events, paused by you,
suspended by the system, stopped after a rendering failure, or that the state could
not be read. A scene that is running but cannot be read says so; it is never shown as
updating normally.

### A scene that stops drawing

When a frame fails after the graph was built (an acquire or present that the
swapchain refuses, a submit that errors), or the render graph or its backend cannot be
built or released, the scene stops drawing and stays on its last picture. That used to
look like a pause from the outside, because the renderer's failure counter only
counts while a diagnostic session has counting switched on.

Each scene surface now carries a small health reading that is always on. It is a few
atomics written once per frame and read when asked; it starts no thread, timer or log
output, and it does not depend on renderer counting.

| Field | Meaning |
|---|---|
| `frames_completed` | Frames the render loop ran to the end, whether or not they reached the display |
| `frames_presented` | Frames that reached the surface |
| `failed_frames` | Frames lost to a failure in the draw itself; never reset |
| `last_present_age` | Time since the last present, or none before the first |
| stop | Not stopped, `FrameFailed` (the draw failed) or `GraphFailed` (the graph or backend could not be built or released) |

Liveness is `frames_completed` moving, never a present: with
[scene render optimisation](#frames-that-would-repeat-the-picture) a frame that would
repeat the picture completes without presenting, so a healthy, still scene stands
at the same `frames_presented` and a growing `last_present_age`. A reading built on
presents would call it stalled. Host-initiated stops, such as a surface being rebuilt
for a display change, are not failures and never set the stop. It clears when a
wallpaper is applied, a surface is installed or the graph rebuilds.

The reading is shown in two places, both as the mode `stopped_after_failure`:
**Settings → Performance → Live diagnostics → Updating now** says "stopped after a
rendering failure", and the `running scene:` lines of the
[diagnostics report](diagnostics.md#diagnostics-report) end with `mode …`. A pause the
user chose, or a display the app suspended, outranks it, and it shows again the moment
that is lifted; a reading the renderer could not take stays `unknown` and is never
reported as stopped or as running.

#### Recovery

A scene that had already shown a frame and then fails one calls the app back once (the
renderer's render-failure callback: no payload, never replayed on install). The app
then heals it with a small ladder inside a rolling minute. It is event-driven, and a
healthy scene costs nothing. The one exception is the look at a renderer that recovery
just rebuilt, described below, which lasts until that renderer has drawn.

| Attempt | Waits | Does |
|---|---|---|
| 1 | 0.5 s | Rebuilds the surface and swapchain in place; the compiled scene stays |
| 2 | 2 s | Opens a new renderer for the same wallpaper and closes the old one |
| 3 | 8 s | The same rebuild again |

An in-place rebuild that fails goes straight to the renderer rebuild instead of
waiting for the next rung. Attempts older than a minute stop counting, so a failure
after a quiet minute starts again at the first rung; a fourth failure inside one
minute gives up with one line in the log, "display N stopped drawing; recovery gave up
after 3 attempts in 60 s", and the scene stays stopped, shown as above, until
[Retry](#retry) or a different wallpaper loads on that display. A pause (the user's, or
a covered display's) is kept across every attempt, so recovery never plays what was
paused. The internal [render scale](performance.md#quality) is kept the same way: a
renderer the engine opens itself starts at full size, so the rebuild hands it the scale in force
before it draws, and a wallpaper turned down to 50% does not come back at four times the pixels.
An attempt that finds the surface drawing again, because a display change
rebuilt it in the meantime, does nothing. The wallpaper window shows its placeholder
for a moment while the surface is rebuilt, and the engine waits for the render thread
meanwhile, up to the 10 s swapchain acquire timeout in the worst case, as it does for a
display change.

A failure before the first frame is not retried: the app is still inside its first-frame
wait, which has its own timeout and rollback, and a retry of its own would race it. The
failure is still counted in the health reading.

A renderer that recovery itself rebuilt is a new renderer with no first frame yet, so
it too would call nobody back if its first frame failed, and the ladder would end there
with the scene stopped and no further rung tried. The engine therefore looks at a
rebuilt renderer itself, once a second, until it has presented a frame. The attempt stays
under way meanwhile, so a stall check or a second failure starts nothing beside it. A
renderer that stopped before it drew counts as the failure it is: the next rung is
scheduled, or, after the third, the scene gives up with the usual line. A renderer that
neither draws nor stops within 30 seconds is reported in the log and left as it is,
because a scene with a great deal to load is not a failure and rebuilding it again would
only interrupt the load.

A caller that knows something the renderer does not can ask the engine for the next
rung directly with `WallpaperEngine::recover_surface`. It spends the same budget the
failures do, so a liveness check cannot buy back a spent one within the minute;
[Retry](#retry) gets a fresh budget by loading the wallpaper afresh, which opens a new
renderer. The
[check after the Mac wakes](performance.md#playback) is such a caller: it finds a scene
that stopped itself, or one still counted as running whose `frames_completed` stood
still for three seconds, and asks for a repair as `Stalled`. That covers a scene the
failure callback never reported (one that failed before its first frame) and a surface
that stopped drawing without any failed frame. A scene whose minute of attempts is already spent
stays stopped, the check says so in the log, and **Retry** is still the way back.

Each step is logged under the load it belongs to: "display N stopped drawing after a
failed frame; trying a surface reconfigure in 500ms (attempt 1/3)", then "display N
renderer recovered by a surface reconfigure (attempt 1/3)" or the error. A rebuild gives
the scene a new load number and the budget carries over to it; it is logged as "renderer
rebuilt (attempt 2/3); waiting for it to draw", and then either "renderer recovered by a
renderer rebuild (attempt 2/3)" once it has presented a frame, or "renderer rebuilt
(attempt 2/3) stopped before it drew" followed by the next rung.

A real MoltenVK or Metal presentation failure has not been reproduced on a desktop. The
tests inject the failure into the renderer's own failure routine and exercise everything
after it there, the ladder with injected instants, and the relay that carries the report
to the engine. The engine's reaction to a report on a live scene needs a real window and
is not covered by an automated test, so whether a genuine failure is healed by the first
rung or needs a rebuild is unverified.

#### Retry

A scene that reads stopped has a **Retry** button on its row in **Settings → Performance
→ Live diagnostics → Updating now**. That covers a scene recovery gave up on and one
that failed before its first frame, which recovery leaves alone. Retry takes the
wallpaper off that display and applies it again, so a new renderer opens with a fresh
recovery budget. Applying the wallpaper again from the Library (double-clicking its tile
or choosing it in Recently used) cannot do this: a wallpaper a display already shows is
left as it is, and so is its stopped scene. The inspector's **Reapply wallpaper** takes
the wallpaper off the display and loads it afresh, so it restarts a stopped scene too
([control panel](control-panel.md#selection-versus-apply)); Retry does the same from the
row that reports the fault, and unlike Reapply it does not count as the user choosing the
wallpaper.

- Only the display on the row reloads. Another display showing the same wallpaper is
  not touched, and the wallpaper's files are not counted as changed, which only a
  Workshop update does. The exception is a display that mirrors another: it presents a
  scene of its own but has no wallpaper of its own to take off, so its Retry reloads the
  display it mirrors, which opens a new scene on that display and on the mirror.
- It is queued in that display's slot, like a switch. It waits for the command that is
  running, a newer choice on the display replaces a retry that is still waiting, and a
  retry that waited behind a switch finds another wallpaper on the display and does
  nothing. While it runs the button is disabled, like every control that waits on that
  queue.
- Nothing retries by itself. A scene that stops again reads stopped again, with the
  recovery ladder above starting afresh, until Retry is pressed once more.
- If the reload fails, the error shows as for any apply and the display has no
  wallpaper, because it was taken off first, rather than a frozen picture.

The button appears for the stopped reading only: a pause, a suspension and a scene
still starting are not faults to retry. The tests drive the page, the dispatcher and
the store against a stand-in engine; the button's placement, a reload of a genuinely
stopped scene on a real display, and whether reloading a display's source opens a new
scene on its mirror have not been checked on a desktop.

## Renderer memory

On Apple platforms, the Compatibility renderer grows its Vulkan allocator in 8 MiB
preferred blocks rather than the library's 256 MiB default. This reduces unused
reservations in unified memory; it is not a cap on wallpaper size, and larger
resources still allocate normally. The offscreen probe prints allocator reserved and
used bytes separately from process memory.

For scenes with an authored 2D canvas, both backends load packaged mip chains to
match the physical display: a leading mip is skipped only while the next one is still
at least as long as the display's longest edge, so the level kept always covers the
display (a 3024×1964 display uses the authored 4K mip of an 8K source, and a 4240 px
picture on a 3456 px display keeps its full-size level, the one Wallpaper Engine
samples, instead of a 2120 px one stretched to fill the screen). A texture shorter
than the display keeps its own largest level. The rule favours picture quality over
the smallest footprint: a texture longer than the display's longest edge but shorter
than twice it keeps its full-size chain, roughly four times the memory of its next
level, instead of being cut to a level that would be magnified. Skipped
levels are never decoded or uploaded. Layout metadata, render-target resolution, frame rate and effects stay
unchanged, but source detail can differ for a layer drawn larger than the display,
such as a zoomed image.
Display-surface replacement rebuilds the textures for the new display size.
Perspective scenes without an authored canvas retain the source mip chain: a model
or skybox can magnify a small UV region, so display dimensions alone cannot
establish which source detail is safe to discard. The policy uses available
authored mips; a single-level image or an incomplete chain may remain above the
limit, and loose images, videos, sprite atlases, multi-slot images and unknown
encoded containers keep their original loading behavior. It is a texture-residency
reduction, not a fixed ceiling on total process memory.

When **Native Metal** draws one scene on several displays, each display reads and
decodes the scene's pictures itself but uploads none that another display already
holds: displays keeping the same mip levels of a picture (and the same sheet of a
sprite atlas) on the same GPU bind one texture between them. A texture is handed to
another display only when its pixels equal what that display just read, so a file
that changed between two loads, or another wallpaper's picture of the same name,
gets its own, and so does a display that keeps a different mip range (above). The
cache holds the textures weakly: a picture is freed when the last display showing it
unloads. Confirming a match reads the shared texture back once while the scene
loads; nothing is added per frame. Render targets, pictures a script writes and
video frames stay per display.

A picture is written into its texture by the CPU, in a layout the GPU reads uncompressed;
on Apple GPUs only a texture laid out by the GPU itself is losslessly compressed. So every
newly uploaded plain 2D picture (not a block-compressed one, which is compressed already, and
not one a script rewrites) is rearranged for sampling once, by one blit queued ahead of the
first frame that samples it (`optimizeContentsForGPUAccess`). The values sampled do not
change, and a display that compares its own bytes with the texture (above) waits for the
blit and reads back the bytes written. Sampling an illustrated 4068x1979 layer at three
quarters of its size took 0.042 instead of 0.125 ms of GPU time on an M5 Pro, a picture of
random noise, which does not compress, the same either way; a scene loading 65 pictures
costs 65 such blits once, and nothing per frame. `WALLPAPER_MACHINE_OPTIMIZE_IMAGES=0`
leaves pictures as written, for an A/B ([power benchmarking](../testing/power-benchmark.md#ab-comparison-entry-points));
`MetalImageLevels.ANewUploadIsOptimizedForSamplingOnceAndStillComparesEqual`,
`.OnlyAPlainPictureUploadedWithAQueueAndTheSwitchOnIsOptimized` and
`SharedPictures.AnOptimizedPictureDrawsTheSameBytesAsOneLeftAsWritten` cover it.

An authored `hdr` scene with bloom on selects the HDR path on either scene backend
when post-processing is Ultra or Display HDR: overbright color is preserved in
half-float targets and bloom is HDR. Enabled uses LDR bloom and Disabled draws none;
other scenes, an `hdr` scene loaded with bloom off included, keep the 8-bit path.
The HDR combine produces linear color before color correction and camera fade. Native
Metal presents that color through an sRGB SDR surface, or an extended-linear sRGB
RGBA16Float surface when Display HDR is selected and the identified display supports
EDR. The host supplies the physical display ID during creation, window moves and surface
replacement; an unknown display stays SDR. Current headroom is refreshed on display
notifications, with no screen lookup or polling in the frame loop. Potential headroom
allows the EDR surface to start while current headroom is still 1. The existing frame
clock coalesces updates and keeps paused scenes paused. A surface that returns to SDR
does not change the saved processing quality. Previews follow their own window's display;
the lock-screen extension independently restricts its output to SDR. Posters always use
an 8-bit SDR composition, including for an EDR desktop. This surface contract has
headless coverage, and was checked once on a built-in XDR panel (M3 Max, macOS 27.2,
headroom 8 of a potential 16) with corpus scene 3662790108 (`hdr` and `bloom`): a
ScreenCaptureKit HDR capture of the desktop shows Ultra peaking at 1.0 and Display HDR
at about 53 in extended linear Display P3, on 0.035 % of the pixels (the sun's core),
while the median and the 99.9th percentile stay the same, so only overbright detail
leaves SDR. That run checked radiance, not perceived brightness against Wallpaper
Engine, which has no HDR output in the reference VM.

An HDR scene that later disables bloom keeps the linear output contract through
`combine_srgb` before color correction, fade and presentation filtering. This currently
adds one full-raster conversion draw, one copy and one RGBA16F target (eight bytes per
pixel) compared with omitting conversion; changing only the final sampler does not
preserve nonlinear filtering or blending. These resources retire on unload and repeated
bloom toggles do not grow residency. The already-required HDR bloom combine changes its
shader without adding passes. An EDR surface's drawable storage is also half-float;
those system-managed drawables are outside the scene target byte counter.
An image layer's `brightness` multiplies its colour into the `g_Color4` the
layer is drawn with in that path only, as in Wallpaper Engine, where every other scene
counts it as 1; the layer's brightness is not also the `g_Brightness` of a shader that
declares one, which stays that material's own constant. A brightness bound
to a user property or a script follows it while the scene runs, beside the layer's colour
and alpha. A scene that leaves `bloom` out has it on, at strength 2 above 0.65, as
Wallpaper Engine has it. Half-float targets cost eight rather than four bytes per
pixel, and the cache accounts for that actual size; an eight-level bloom pyramid
starting at half-resolution holds under a third of a full-size target's pixels. This
is real post-processing work, not a free brightness adjustment or supersampling, and
increasing FPS alone cannot substitute for it: the High preset controls only frame
rate and render scale ([Quality](performance.md#quality)). The pyramid's level count
follows the physical scene raster after the resolution choice and internal render
scale. Crossing a size boundary replaces the chain and recomputes extraction strength;
shrinking retires excess levels and growing can restore them, within the same eight-level
cap. Sizes that keep the level count retain the existing materials. This happens while
configuring render targets, without additional steady-state frame work. The HDR bloom's
sampling and weights are Wallpaper Engine's: level targets use integer division
with a two-pixel minimum, while sample offsets use the full-raster reciprocal times
the level's power of two, before allocation rounding or clamping. Ordinary effect
buffers retain their nearest-integer allocation and four-pixel minimum ([scene
regressions](../testing/scene-regressions.md)).

On both backends, a layer hidden by its authored visibility or by one of the
wallpaper's own properties, itself or through a parent, is left out of the render
graph. Applying a property change reloads the scene, so until then only a script,
or a property edit shown on the running scene ([live property
edits](#live-property-edits)), can show it. Customizable wallpapers ship every
theme, language and date format as a layer, and those hidden layers no longer hold
effect images, load textures or clear targets every frame. When a script shows one,
a graph that draws it is built before that frame is drawn; this happens once per
layer, because a layer whose visibility a script has written stays in the graph from
then on. A previewed property shows it the same way, but a preview owns nothing: a
layer it hides again keeps its passes only until the next graph is built, and
showing it afterwards asks for one more graph. The graph can therefore hold the
layers a preview showed since it was last built, never more than the wallpaper
ships, and is back to what a fresh load with the current values holds the next
time one is built. A hidden layer another layer samples keeps drawing into its
composite.

A layer the scene file hides outright (`"visible": false`, no property or script
deciding it) is built, hidden, only when something can need it: another layer
samples it, it carries a script of its own, or a script spells out its name.
Wallpaper Engine builds every layer, so a hidden layer's scripts run there (a
hidden controller layer often works out what the others show, a day/night switch
for one) and any script can find it and show it; a name a script computes is not
seen here. Every other hidden layer is not built at all. Sound and light objects
are never kept hidden: neither reads its visibility, so a kept one would play or
shine.

Native Metal allocates render targets only when the compiled graph writes or samples
them, plus the final output. Parser-provided shadow, mipmapped-frame and bloom
buffers are metadata until a pass needs them. References from hidden passes left in
the graph (a script decides their visibility) and elided copies still count, so
animation and live optimization toggles retain the targets they can use, and the
same filter applies when a toggle reallocates targets.
This applies to scenes drawn with **Native Metal preferred**; the Compatibility
backend already requests its targets from the cache as passes prepare them.

Native Metal also lets targets that are never alive at the same time share one
image, as Compatibility's cache pools them. A target qualifies when its first touch
in every frame is a clear that really happens, nothing copies into or out of it,
and it is not carried into the next frame, pinned for reuse, mip-mapped,
depth-attached or the scene output; targets of one shape whose spans of passes do
not overlap then take turns on an image. Copies of the picture so far that a layer
reads (a lens, a blend mode over the screen) are traded rather than blitted, and the
traded copies of one source share a small set of images: each copy takes one when it
runs and gives it back once its last reader has drawn, so a scene with forty such
copies keeps two or three images instead of forty-one, with no extra blit. A scene
that draws over the whole screen many times holds about a quarter of the target
memory it did. `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` gives every target its own
image again, for comparison or to read each target's own pixels after a frame.

The lock-screen extension keeps its renderer paused while unlocked or asleep to
avoid a cold reload on wake; see [lock-screen memory tradeoff](lock-screen.md#how-the-surface-behaves).
The desktop renderer still needs the textures and render targets of the active
wallpaper. An idle control-panel benchmark cannot establish its playback memory
usage, and the extension must be measured separately from the app coalition. Its
Metal layer remains nonopaque so a missing drawable reveals the retained frame
below it; that gives up the layer's opaque-compositing guarantee, and the
WindowServer blending and energy cost has not been measured.

Closing the control panel releases its window's controller and everything the panel
held, rather than keeping a hidden panel alive, and a hidden or minimized panel does no
work of its own. Reopening builds a fresh panel over the same stores; see
[panel lifecycle](control-panel.md#pages-and-settings).

The app records macOS memory-pressure events together with its process footprint and
the scenes it is presenting ([diagnostics](diagnostics.md#memory-pressure)). It does
not unload, pause or stop a wallpaper on them: the footprint is for the whole process,
so a scene cannot be singled out, and no threshold has been measured.

## Repeated-work reduction

These renderer-internal optimizations do not change any setting, target frame rate,
render scale, animation speed or audio-response subscription:

- Per-frame uniform writes borrow their writer only for the synchronous update and
  match shader values to their uniform slots through a per-pass table built once;
  every value is still written every frame and no camera, bone, script or effect
  result is cached by this path.
- On Compatibility, a hidden layer's first-use clear is left out when nothing can
  see its target, the first draw into a composite just cleared to transparent opens
  with that clear, and a plain video wallpaper whose decoded frame is exactly the
  scene's size draws straight through the final composition instead of copying into
  a video-sized image. Each new video frame's colour conversion is queued ahead of
  the frame on the renderer's own GPU queue: one submission per new frame.
- A hidden particle layer keeps its simulation and rebuilds its mesh on the first
  frame it is shown again, or while something samples it.
- The audio-analysis queue advances a logical read position instead of moving its
  tail after every 1,600-frame window; every window is still processed, 30 a
  second. A video demuxer discards packets of streams it does not decode.
- Repeated system-media artwork skips redundant input conversion while still
  consuming every media-state message ([media integration](media-integration.md)).
- Bridge snapshot bursts reuse one shader-cache size measurement for up to two
  seconds instead of walking its directory for every property or playback update;
  explicit settings-snapshot requests and cache clearing force a fresh
  measurement. This affects storage statistics only.
- On Native Metal, a render pass opened by a draw that provably writes every texel of
  its target clears the target instead of loading it from memory. Effect passes
  alternate between two buffers, so every effect but a layer's first and last (and
  a multi-pass effect writing its own buffer again) used to read its whole buffer
  back before drawing over all of it. The proof is
  general: the shader compiler reports that the fragment shader never discards and
  that the vertex position is the mesh's own position, as given or through one
  matrix uniform; the draw's two triangles, through this frame's matrix, must cover
  the whole target with a quarter-texel margin, with nothing culled or depth-tested,
  every channel written and blending that replaces the texel (an 8-bit target when it
  is `One`/`Zero` rather than off). A traded copy's reader that passes the same test
  also skips the copy it opened with. Anything unproven keeps its load, and the clear
  is to transparent black, so the picture is the same byte for byte. Depth and
  multisampled colour attachments are no longer stored after the last render pass of
  the frame that uses them (each frame's first one clears them). The switches are in
  [power benchmarking](../testing/power-benchmark.md#ab-comparison-entry-points).
- On Native Metal, a copy whose source is afterwards only read until it is drawn
  afresh is no longer made: the two images trade names once the source's last reader
  is encoded. That is a motion blur's copy of its accumulation into its history every
  frame, and bloom's and the colour options' result copied back into the scene's
  image, each a full-size blit per frame (14 of them, 17 MB written, in a scene with 14
  blurred layers at 4K and render scale 0.75). The source then holds a stale image
  until its next writer replaces it: later in the frame (a load that cannot be proven
  to overwrite opens with the copy, as a traded feedback copy's reader does), or as the
  next frame's first pass on it. When that pass may leave the image alone (a hidden
  layer), the image is copied back from the copy's name first, so the picture is the
  same byte for byte; a sorted scene keeps its copies.
- On Native Metal, a draw that leaves its image exactly as it was is left out. Wallpaper
  Engine's common intro is a black screen that fades out and then sits at alpha 0 for
  the rest of the run, and it was drawn over the whole screen every frame. The shader
  compiler proves which channels of a shader's colour are a product of uniforms and
  constants (a solid layer's `vec4(g_Color, g_Alpha)`); a frame whose values make the
  alpha 0 and every factor finite, under a blend that keeps the destination there
  (source over or additive, not a replace or a multiply), into an 8-bit linear image,
  with no depth written and one sample, changes no texel, so its draw is not made.
  Anything unproven is drawn, and the frame the alpha is no longer 0 draws it again.
- On Native Metal, as on Compatibility, a clear only hidden passes would read is left
  out. A layer a script hides stays in the graph, and its effect buffers were still
  cleared every frame, each in a render pass of its own, and the copy a hidden lens
  reads was still made. A clear (or a copy made for draws after it alone) is left out
  while none of the passes that read what it leaves draws this frame, up to the next
  pass that clears the image again; the next frame's passes ahead of it may read none
  of it, whatever they draw then. A copy nothing samples at all stays the copy plan's to
  remove, so with scene optimisation off it is still made. Images another name holds,
  trades or pins, the scene output, depth, multisampled and mip-mapped images are left
  alone, and a sorted scene keeps them. An image a left-out clear left as it was is given that clear's colour
  before another plan or graph takes it over, so the frame a layer is shown again, and
  the first frame of a new graph, are the same byte for byte. Both switches are in
  [power benchmarking](../testing/power-benchmark.md#ab-comparison-entry-points).

The contracts and tests behind each item are in
[renderer verification](../testing/runtime-regressions.md#continuous-playback-work-contracts).
Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not displayed
FPS; a power claim still requires the matched conditions in
[power benchmarking](../testing/power-benchmark.md).
