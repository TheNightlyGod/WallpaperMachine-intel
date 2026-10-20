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

Which renderer scene wallpapers prefer. **Native Metal preferred**, the default,
asks for the native Metal backend; a scene it cannot draw runs on Compatibility as a
whole (an effect is never dropped to keep a scene native) and the status line says
why. **Compatibility** is the Vulkan-through-MoltenVK path for every scene.
Lock-screen playback always uses Compatibility.

Native Metal became the default once it drew every scene of the local test library
the way Compatibility does (drawn by both renderers in one harness, the pictures
were the same) and cost less to run. Over 12 of those scenes at 3840×2160 and 60
FPS it took about 21% less process CPU time and 14% less GPU time in its own command
buffers (one per frame instead of three), about 3% less memory footprint, and held
60 FPS where Compatibility dropped frames; the commands are in the
[verification log](../testing/verification-log.md). A configuration saved before
then holds `compatibility` whether or not anyone chose it, so it moves to Native
Metal preferred once, when this version first loads it, and records that it did
(`native_metal_default_applied`); choosing Compatibility afterwards is kept.

No GPU backend is created until the scene has been parsed and a backend chosen, so
the row reports one of three states per scene: **preparing** (no backend yet), the
backend actually in use, or Compatibility with the reason native was not used. It
never shows the preference in place of the outcome.

Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and rope-trail
particles, 3D models and skyboxes, perspective cameras, scene lights, ordinary
effect chains and scene post-processing, layers that read an image another layer
produced in the same frame, effects that read the previous frame (a motion-blur
trail, a fluid or ripple simulation), images the runtime replaces while the scene
plays, and BGRA or 8-bit NV12 video textures — the latter either converted once per
frame or, with
[**Direct video plane sampling**](performance.md#direct-video-plane-sampling) on,
sampled by the layer's own shader. A scene falls back as a whole for HDR or 10-bit
video, a plain video wallpaper, a shader that does not translate, particle geometry
in a layout it does not recognise (lit particles among them), a multisampled target,
an effect that samples a depth buffer, or a layer that reads its own previous frame (its `_b` composite, bound anywhere but its
own effects).
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

In a 2D scene, a particle system or 3D model with the `perspective` flag is drawn
through a perspective camera seated as Wallpaper Engine seats it. Its field of view is
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
`layer.name` is the name the scene file gives the layer, empty for an unnamed one,
whatever key the engine files it under, from the moment any script can reach the
layer, its own script compiling with it included. A sound object is a layer in that
order like any other, found by its id and played through the object
`enumerateLayers()` hands out; a music widget finds its tracks there by name. Only
layers the parser built are counted: an object the scene file marks statically
invisible, which nothing can show, is never built, so it has no index or id and the
count differs from the object list by those. `destroyLayer` removes the layers a
script made below the layer too. A scene script's `init` runs once the scene is
built, so it sees all of that. Property scripts start on the scene's first tick:
every one runs `init`, in the scene's order, before any of them is told the user
properties, and that before any `update`, because a widget's options layer may call
from its first `applyUserProperties` what a later layer's `init` set up. What `init`
returns is the property's value from then on, as what `update` returns is: a drag
handle hides itself there, and a typing text starts empty.
`applyGeneralSettings({ language })` is always told `en-us`: the host does not
yet pass the interface language on. `parallaxDepth` set on a layer reaches the
layer, its effect passes and the layers below it (a layer drawn through effects
holds it on its effect passes alone, so its first pass, which draws into the
layer's own target, stays where it is), and one that starts or stops following the
cursor rebuilds the render graph.

`layer.getTransformMatrix()` answers the layer's world transform as a `Mat4`: its
own placement with every ancestor's scale and turn applied, in canvas units with y
up, so `m[12]` and `m[13]` are its x and y on the canvas (scripts compare them with
`engine.canvasSize` to tell which side of the screen a widget is on). It is the
layer's own matrix, not the one it is drawn with: a camera parallax and the identity
a layer drawn through its effects renders from are not in it. A layer anchored to an
edge or a corner (`alignment`) answers the centre of its quad, which its anchor
places, while `layer.origin` still reads the anchor. A layer that ignores its parent's
transform answers its own placement. The other layer transform calls
(`getChildren`, `setParent`, `rotateObjectSpace`, `lookAt`, `lookAtYaw` and
`getAttachment*`) do not exist yet: a script that calls one stops at that line.

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
restarted the slide and never faded. Settings the editor keyed together (`options.parent`: an origin and the angles
that turn with it) are one animation on the first one's clock, so playing or holding
it moves them all. A script or a property bound to the same setting is its only
writer. A colour timeline tints the layer's own material and each of its effect passes
and keeps the layer's alpha; in a scene that renders HDR the layer's brightness
multiplies the timeline's colour as it does the authored or bound one. Not followed: the `mirror` play mode (it plays as
`single`), a timeline on `alpha` being on its parent's clock (it keeps a
clock of its own), and the colour timeline of a text layer or a light
([known limitations](../testing/renderer.md#known-limitations)).

A scene starts as a desktop with no player. On its first tick, after every script has
started and before anything is drawn, its scripts are told `mediaPropertiesChanged`
with no track and `mediaPlaybackChanged` with `PLAYBACK_STOPPED`, once, whether or not
media integration is on. Wallpaper Engine's media widgets are authored
visible (a group layer, a cover, a mascot parented to it) and hide themselves on
`PLAYBACK_STOPPED`, so a scene that was never told would show them on every start for
anyone not playing music. The state names no one's music, so it does not wait for the
consent that real events do. A real event that reached the scene first (the replay to
a scene that has just attached) is not repeated as idle, per event type, and a real
one after it is delivered as usual ([media integration](media-integration.md#scene-wallpapers)).

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
always released, wherever the pointer ends up.

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
(`g_LightsPosition`, `g_LightsColorPremultiplied`). A light is a node like any layer:
it follows its parent, and its visibility, transform, colour, intensity, radius and
exponent follow user properties, scripts and timelines; a hidden light, or one under
a hidden layer, lights nothing. Each kind lights at most as many lights as the config
names, the first ones in scene order. A lit pass reuses its last image only while
the lights it reads are unchanged. `g_NormalModelMatrix` is each draw's own rotation
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
containers. Ambient/skylight colours and height-fog settings resolve user-property
values at scene load; preview edits are deferred to the existing apply/reload path
rather than adding per-frame uniform work. SceneScript `rotateObjectSpace(Vec3)` composes a
radians Euler increment around the layer's local axes; the `angles` property
continues to read and write degrees.

Shadow maps, spot cookies and
volumetric light shafts are not drawn: a light that casts a shadow lights as if
nothing did, which is also what Wallpaper Engine shows when nothing in the scene
casts one. Both renderers apply a material's depth state and cull mode the same way: a
pass into a depth-attached target (a model, a skybox, a scene with a perspective
camera) takes its material's depth test, depth write and cull mode, against the same
front faces, and every other pass draws in painter's order and culls nothing. A pass
reads these words as Wallpaper Engine does: only `enabled` turns on a depth test or a
depth write and only `nocull` turns culling off, so any other value (`less`,
`inverted`) means no depth test, no depth write or back faces culled; there is no
depth compare to choose. A material writes depth as authored whatever its blending,
as Wallpaper Engine's own translucent depth-tested font materials expect, so a
translucent or additive layer that asks to write depth hides what is drawn behind it
afterwards, its transparent texels included; a pass that does not depth-test writes
none. The last pass of an image layer's effects, the one that puts the layer into the
scene, is drawn with the layer's own blending and depth test, not the ones its effect
pass authored, and with its depth write unless the layer is one Wallpaper Engine
sorts: Wallpaper Engine's image layer copies all three from its material onto that
pass, but a scene that turns `transparentsorting` on draws the layers whose material
blends (`translucent`, `additive`) back to front after the others, where the write
hides nothing that comes after it, and this engine draws in scene order, where the
write would cut the layer's whole card, transparent texels included, out of every
farther layer drawn later (another star's glow, a HUD ring). A layer whose material is
`normal` (which `disabled` also reads as) or `alphatocoverage` stays in the scene-order
set drawn first and keeps its write, which hides the farther layers drawn after it.
A translucent glare layer authored `depthtest` enabled is hidden by a nearer model
whether or not an effect runs over it, a layer authored `depthwrite` hides what is
drawn behind it afterwards unless the scene sorts it, and the editor's depth-testing
solid and compose layers, image layers too, test their effects' result against the
scene. A text layer drawn through effects keeps its last pass's depth state, and a
plain translucent layer that writes depth still hides farther layers drawn after it
in a scene that sorts
([known limitations](../testing/renderer.md#known-limitations)). A target the frame
reads before it writes it keeps its own image from one frame to the next on both
renderers, so the reader sees exactly the previous frame, and transparent black on
the first frame, since both renderers clear every new target; a scene with such a loop
is never called still while it runs. An effect's own buffers are made the way
Wallpaper Engine makes them: a float format (`r16f`, `rg1616f`) is a float target,
so a fluid simulation's velocity and pressure keep their sign; an explicit 8-bit
format stays 8-bit and the back-buffer formats follow the scene; a buffer with its
own `width`/`height` or a `fit` has that size, its longer side shrunk to the `fit`
with its aspect kept, before `scale`. An effect's `swap` command exchanges two
buffers where it stands among the effect's passes, so a simulation carries its state from one frame to the
next; when the effect draws into the second buffer before reading it again, one copy
into the first is the whole exchange, otherwise it goes through a temporary buffer.
A buffer's `clear` colour and `conditions` are not read: buffers start cleared to
zero and are made whether or not the effect's combos use them. A layer's colour blend
mode mixes it with the screen behind it through Wallpaper Engine's passthrough
material, the layer's last step; the passthrough takes the layer as its first pass
drew it, colour and alpha included, and does not apply them again. Mode 31 ("add")
has no passthrough: an image layer, or its last effect, is drawn with additive blending
straight onto the scene, so it costs neither the extra pass nor a copy of the screen (a
text layer that goes through a visible effect is the exception, see below). Translating to the
Metal shading language
turns GLSL's `inverse`, which Metal has no built-in for, into helper functions, so
the stock perspective, reflection, water, light-shaft and cursor-ripple effects
translate. A step that samples an image nothing in the scene produces (a layer
texture whose layer draws no composite) is skipped on Native Metal exactly as
Compatibility skips it, instead of sending the scene to Compatibility; an image that
exists and does not load still does.

Puppets and rope geometry behave the same on both renderers. A puppet is deformed
by its author's own skinning shader, and its pose comes from the one animation
system the scene already has (animation layers, their play, pause, stop, rate,
blend and visibility, and any script or user property driving them); the renderer
only uploads the resulting bone matrices. Rope and rope-trail geometry is generated
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
loads. A text layer is an ordinary layer: it takes its place in the layer order and
carries its transform, opacity, blend, effect chain, camera and the final
composition, appears in desktop posters, and uses the engine's one text system on
both renderers. Text whose content has not changed is not laid out, rasterised or
uploaded again; a script that produces it still runs on its own schedule every
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

A video that is opened while the clock is already some way into the clip (a scene that falls
back to the other renderer, a surface split off a shared decoder with shared decode on) opens
at the head of the clip, as any open does, and the first call that gives it the clock seeks it
there. The open waits for no seek, so it costs what opening at the head costs. The head of the
clip is on screen until the seek has landed and the decoder has caught up with the clock, which
kept running while the seek was made: 0.35 to 0.75 s for a 1080p clip and 0.7 to 1.5 s for a
4K one at 30 frames a second with a keyframe every 250 frames (8.3 s), 2.3 to 4.2 s for 4K at
60 frames a second with one every 600 (10 s). An open that waited for the seek would add its
length to the draw that opens it (0.3 to 0.6 s on the 1080p clip, 0.5 to 1.1 s on the 4K one,
1.4 to 1.5 s on the 60 frame one) and fail once it passed the two seconds an open waits for a
first frame, as the 4K 60 frame clip's did at 9.9 s and at 19.9 s.

A clock that jumps, as when a script sets a time, is one seek to the new time. A jump forward
leaves the frame the video had on screen until the seek lands; a jump back by more than two
frames clears it, and the draw that follows waits, for two seconds at most, for the seek's first
frame. A seek that is on its way is not made again, because that restarts the decode from the
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
file's rate, and an `instantaneous` burst is paid for out of the rate's account. The
random initializers take their `exponent`, a lifetime is never below a millisecond, a
`sizerandom` or `alpharandom` scales the size or alpha the particle has so far (as the
colour initializers do, so a second `sizerandom` narrows the first one's draw; only the
lifetime is replaced), and every particle carries one random number of its own that picks
its oscillation phase and frequency, its turbulence speed and phase, and its
`randomframe` sprite (which is never cross-faded with a neighbouring frame). `movement` and
`angularmovement` advance the particle where they stand among the operators, with the
damping `velocity * (1 - drag * dt)`, and nothing else does: a particle file without
them keeps its particles where they were placed, whatever velocity they were given (a
movement operator with `flags` 1 keeps gravity in screen axes by multiplying it with the
layer's transposed matrix, scale included, in a system that is not `worldspace`; a
`worldspace` system is already in the scene's own axes and takes it as written); `controlpointattract` pulls hardest at the
control point and not at all at its threshold, and with `flags` 1 removes a particle
whose path over the last step, from where the movement operator found it, came within
`deletethreshold` of the control point; `vortex` swirls about the control point
plus its offset; `turbulence`, the oscillators, the vortex and `capvelocity` take the
blend window (`blendin*`, `blendout*`), and `turbulence` and the vortex an
`audioprocessing*` level (the loudest selected band), which makes a scene that has
either of them need audio capture like an audio-driven emitter does. `capvelocity`,
`reducemovementnearcontrolpoint`, `maintaindistancetocontrolpoint`,
`maintaindistancebetweencontrolpoints`, `collisionplane` and `collisionsphere` work on the
control points' motion and orientation (every particle found inside a collision shape
takes its response, a bounce or a slide, whichever way it is moving; a sphere without an
`origin` is centred 200 below the origin in a pixel scene; with `flags` 1 a sphere is centred
on its control point and a plane passes through it, turned by the control point's
orientation, and neither reads its own `origin` or `distance`), and the `hsvcolorrandom`
(its hue steps spaced as the loader spaces them), `colorlist` (its noise a draw over the
entry's value plus and minus the noise, cut off at 0 and 1), `inheritcontrolpointvelocity`,
`positionoffsetrandom`, `mapsequencearoundcontrolpoint`,
`mapsequencebetweencontrolpoints` and `inheritinitialvaluefromevent` initializers are
implemented. A scene object's `instanceoverride` colour re-tints the preset's own colours
by the difference between the override and the preset's representative colour, keeping
their spread, and is a plain tint only for a preset without colours; its
`controlpoint0`..`7` and `controlpointangle0`..`7` replace the preset's control points
(a control point flagged 2 is held at its scene position as the layer moves), and
`brightness` multiplies the tint in an HDR scene, and each of them follows a user
property while the scene runs. Its `size` multiplies the size a particle is born with and
every `sizechange` ramp of the file besides, as Wallpaper Engine's loader binds the
override to each size record: a ramp scales the running size by the override times its own
factor, so a particle under two ramps is the override cubed, not the override, unless the
particle file sets the "ignore size override" flag (128), which keeps it out of the draw
and the ramps alike. Its `speed` scales the emitters' and velocity
initializers' speeds, `movement` gravity, `angularmovement` force, the vortex and turbulence
speeds, the pull of `controlpointattract` and the frequency of `oscillateposition`, unless the
particle file sets the "ignore speed override" flag (16). An `eventfollow` child whose bound
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
The known differences, among them the operators
(`vortex_v2`, `boids`, `remapvalue`) and the renderer `orientation`, `fadealpha` and
`fadesize` keys that are not implemented, are listed under
[Known limitations](../testing/renderer.md#known-limitations).

Text is set the way Wallpaper Engine 2.8.42 sets it. `pointsize` is a size in
points at 300 dpi, 4.17 pixels to the point, clamped to 1 through 256 and handed to
FreeType as it is, which rounds the em to whole pixels only for the fonts that ask;
a glyph's advance is its unhinted advance, kerned against the next glyph of the
same face from the font's `kern` table and cut to whole pixels (Wallpaper Engine's
shaper also reads OpenType kerning, ligatures and complex scripts, which this does
not); the line pitch is the font's line height plus the layer's `spacing` y, its x
adds to every glyph's advance, and a row is as wide as its ink and the pen at each
glyph start (the advance after the last glyph is not part of it). Five cards that
Wallpaper Engine saved for text in Arial in the local scenes (with and without
padding, a lone full stop, a run of dashes, a long run of underscores) come out to
the pixel; other fonts, scripts and the OpenType-only kerning of many fonts have not
been compared. A system font is opened through FreeType from its file and not read
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
a layout, and a glyph that none has is skipped; colour emoji have no face.

An
`opaquebackground` fills the card's rectangle (not the room a style needs around it) with
`backgroundcolor` times `backgroundbrightness`, the brightness only in the HDR pipeline as
the text's is, at the layer's alpha: a layer drawn straight onto the scene draws the fill and
the glyphs over it as the two quads Wallpaper Engine draws one after the other, and a
composite starts as the fill's colour at the layer's alpha where it would start as the scene
behind the card. The colour and the brightness follow a property or script bound to them.

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

Every buffer of a card, an effect's or the composite another layer
samples, is built at the card's width and height with the fraction cut off, at least 4
texels, whatever the size of the scene or of the editor's box, as the scene loads and
again whenever a change of the text gives the card another size in texels (one rebuild
of the render graph for that change; none while the card only moves, as when its
alignment flips, or grows by less than a texel; a rebuild is about 0.5 ms of lowering and
the compile of every pass, 0.6 to 0.9 ms in all on a scene of one layer and 39 to 45 ms on
a scene of 72 passes, and it drops every uploaded image; a video playing in the scene stays open
through it, as described under video textures above; a text with a visible effect whose
card changes in texels every second, proportional digits or a typewriter, makes a heavy
scene hitch for a few frames once per change). An effect on the text therefore sees
the card as its whole picture: `v_TexCoord` runs 0 to 1 across it and
`g_Texture0Resolution` is its size, so an offset, skew or scroll given as a fraction of
the picture moves by that fraction of the card, as in Wallpaper Engine. A card past
4096 texels on a side is drawn cut off to 4096. An effect's own buffers (`fbos`) that name no
`width`, `height` or `fit` are the card's size whatever their `scale`; one that names its own
size keeps that fixed size, as for an image layer, and is not resized with the card.

A text layer that draws through a
visible effect is a composite, as in Wallpaper Engine: the card first holds the scene behind
it with no alpha, the glyphs are blended into it by their alpha on colour and on alpha, the
effects run on that and the last pass goes onto the scene by the alpha it holds, so
black text of alpha `a` through an `opacity` effect stands at `a` cubed of the way to black
(the glyph pass leaves the alpha squared, `kTextCompositeAlphaExponent`), where text with
no effect stands at `a`. The card seeds and blends in its own pass, sampling the scene at
its fragment's screen position, and the last pass of the chain is drawn translucent
whatever the colour blend mode, "add" included. A layer whose effects a script has all
switched off is plain text: its glyphs go onto the scene by their alpha alone, drawn
additively for mode 31, through the passthrough that ends the chain, which is given
a white colour because the card already carries the layer's colour and alpha. A layer with
a colour blend keeps the single alpha even with an effect running (the blend's passthrough
is not known to treat a seeded card as Wallpaper Engine's does). Whether a chain of other
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
does, through the passthrough pass or, for mode 31, additively onto the scene while no
effect of the layer is running (with one running the layer is a composite, above).
The glyphs' colour is in every texel of the card's texture, the clear ones included, with
the coverage as the alpha, as Wallpaper Engine draws its glyphs in one colour at their
coverage: a layer scaled up past its raster, a small pixel font enlarged, samples the
texture between texels, and an edge then fades from the text's colour to the scene by
alpha alone. A clear texel left black would dim the colour toward black as the alpha
falls, and draw a dark ring round every stroke. (The masks of a styled layer, below, are
coverage and not colour, and are clear outside the glyph.) Two colour blends look at no
alpha: the shipped `ApplyBlending` makes Darker Color (5) and Lighter Color (10) the
per-channel min and max of the screen and the card's colour. If Wallpaper Engine draws
a text through its effects, the colour blend's passthrough among them, from a composite
seeded with the scene (inferred, not checked against its frames), the card is the screen
where no glyph is drawn and the blend leaves it alone. The card here is written without
that seed, so for those two modes its shader mixes the colour it writes with white (5)
or black (10) by the alpha (the layer's included, as the reference's glyph pass writes
it), which is what min and max pass the screen by. A card that wrote the text's colour
there, as the clear texels of the raster hold it, drew a solid box of that colour over
the whole card in mode 10 and a dark box in mode 5. The other modes mix by alpha and
need nothing. An edge of those two is therefore the glyph's colour weighed by its alpha
toward white or black before the min or max, where a seeded composite would weigh it
toward the screen: at a layer alpha of 1 the stems match a seeded composite, while a
layer alpha below 1 makes Darker Color text fade out faster (orange at 0.5 over navy
leaves the scene unchanged) and Lighter Color text slightly darker than one.
`outline`, `blur` and `dropshadow` give the glyphs Wallpaper Engine's signed-distance
look: sizes, offsets and the shadow's softness are pixels of the finished text,
capped as the shader's glyph atlas caps them, the outline and shadow keep their own
colours while the glyph takes the layer's (with no outline the glyph is the layer's
colour at every edge; an outline colour is mixed in only for a layer that has an
outline), and the raster, and the card drawn from it,
grow by what the style reaches so nothing is cut off at the layout box (the layer's
size, which places it and answers the cursor, does not change). `msdf` alone only picks
how that shader rebuilds glyph edges and changes nothing here. The outline and
shadow colours follow a property or script bound to them while the scene runs. The
switches, sizes and opacity are baked into the card's pixels, so a property bound to
one is read once, as the scene loads, with the value the user has chosen, and is held
at it by a preview of changed properties (a load-only property); a script or a
timeline on one of them is not followed. `anchor` pins a text
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
runs the HDR pipeline (`hdr` with `bloom`, the one that also gives it 16-bit targets
and the `HDR` combo); in any other scene it is 1, so a layer authored at brightness 0
is drawn in its colour, and a property or script that drives the brightness changes
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
spectrum, which other layers read as bars) keeps them. A layer whose saved size is 0 on
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
depth-testing composition layer composes like the plain one. A pass-through layer
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
whatever room that leaves around it (bars for Fit, Original size or a factor below 1)
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

### Live property edits

The renderer can take a whole property document on a running scene instead of
loading the scene again. The document is the project's declared defaults with
exactly the given values over them, so a property it leaves out is back at the
declared default whatever the scene loaded with. It adds no per-frame work.

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
wallpapers the scene engine draws — scenes on either renderer, and video wallpapers
on Compatibility, which the engine draws as a one-texture scene; native video and
web wallpapers do not go through it. It is on the
[Performance page](performance.md#advanced) so it can be turned off and on for an
A/B comparison without an environment variable.

Unlike [content pacing and shared video decode](performance.md#experimental-switches),
which are read back from the renderer, its row reports the saved preference: the renderer publishes no query for
it. The engine applies a change to a running scene in place, on that scene's next
frame in either direction — the copy plan, the targets it governs and the reuse
table are rebuilt over the graph that is already compiled, without reparsing the
project, reopening a video or resetting a timeline — so nothing restarts and no
wallpaper reloads. The **In force now** row beneath the switch reports what each
running scene is actually under, so a preference that has not reached a scene yet is
visible as such.

Reuse needs a target that is both cacheable and holding a pinned allocation,
because the render-target pool may otherwise hand that image to another key.
Pinning is bounded by a memory budget; when a graph's targets do not fit at the
current output size nothing is pinned, and the per-frame sampling and signature walk
that decide what to reuse are skipped outright, since their only reachable answer is
"draw everything". The budget itself is unchanged; a target that cannot be pinned
still redraws.

### 2D scene resolution

A scene with an authored canvas is rasterized at the size it is presented at on the
display by default (**Display resolution**), or at the canvas's own size (**Canvas
size**), and the internal render scale divides whichever is chosen. Both renderers
size their render targets from one shared function
(`ResolveScreenBoundRenderTargetSizes`): the default target and every target that
follows the screen come from the raster, a target the author sized keeps scaling
with the render scale alone, and the canvas stays the source extent of layout,
cursor mapping and scripts. The raster is the Fill layout of the canvas over the
output in whole points, at the display's backing scale, capped at the device's
largest texture (Native Metal reads Apple's published limit for the GPU family,
Compatibility the Vulkan device's `maxImageDimension2D`). A perspective scene and a
plain video do not read it.

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
showing the last frame. Two cases qualify:

- a Compatibility video wallpaper whose playback clock selected the same decoded
  frame as the last present, which is most ticks of a 24 or 30 fps clip under a 60
  or 120 fps limit;
- a scene, on either renderer, whose every pass was reused from the previous frame,
  leaving only the final composition to redo.

The frame clock still ticks at the configured rate, and the scene still runs its
scripts, timeline, sound and events on every tick; only drawing an identical
picture is left out. A newly decoded video frame is presented on the tick that
selects it, so this is neither content pacing (an
[experimental switch](performance.md#experimental-switches)) nor updating only when
the scene changes, and no drawable is held to keep the picture. A resize, fill, scaling,
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

An authored `hdr` scene with its bloom on selects the HDR path on either scene
backend, as in Wallpaper Engine: overbright color is preserved in half-float targets
and bloom is HDR, while other scenes, an `hdr` scene with bloom off included, keep the
8-bit path. An image layer's `brightness` multiplies its colour into the `g_Color4` the
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
rate and render scale ([Quality](performance.md#quality)). The HDR bloom's levels,
sampling and weights are Wallpaper Engine's ([scene
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

The contracts and tests behind each item are in
[renderer verification](../testing/runtime-regressions.md#continuous-playback-work-contracts).
Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not displayed
FPS; a power claim still requires the matched conditions in
[power benchmarking](../testing/power-benchmark.md).
