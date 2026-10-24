# Scene regressions

Regression areas for what a scene looks like and does: cameras and cursor
mapping, scripts and bindings, layers and compositing, text, animation and the
shader pipeline. Each bullet names the test that guards a behavior and the
invariant or trap it protects; keep them covered when touching that area.
The commands, probes and by-hand test binaries are in
[renderer.md](renderer.md), which also holds the rules that apply to every
entry ([Regression areas that must stay covered](renderer.md#regression-areas-that-must-stay-covered)).
Playback, backend, host and startup areas are in
[runtime-regressions.md](runtime-regressions.md).

## Cameras, parallax and cursor mapping

- **LDR bloom** — `BloomLdr.TheChainIsBuiltFromTheUtilityMaterialsAndTakesTheScenesSettings`:
  the horizontal blur writes an eighth-size image of its own, as Wallpaper
  Engine's does, and the combine reads it.
- **Scene settings bound to user properties** — `BoundSceneSettings.LoadOnlySettingsReadOnceAndTheRestFollowTheirPropertiesLive`:
  a scene loads with its bound bloom switch, parallax switch and amount at the
  properties' current values and reports those properties as load-only; bloom
  strength and tint, parallax delay and zoom follow a property change while it
  runs. `SceneSchema.SceneSettingsLeftOutTakeWallpaperEnginesDefaults`: a scene
  that leaves them out gets parallax amount 0.5, delay 0.1 and influence 0.5,
  black ambient and sky light, and Wallpaper Engine's HDR bloom defaults.
- **Camera shake** — `CameraShake.TheSceneCameraShakesWhileItsPropertyIsOn` and
  `.ADoubledAmplitudeDoublesTheOffset` check Wallpaper Engine's offset for a 2D scene, that it moves the view, that the
  scene asks for frames while it shakes, and that its user property stops it.
- **Camera zoom** — `scene_schema_part10_test --gtest_filter='*SceneZoom*'`.
  Scene `general.zoom` may hold an authored scalar animation, not only a fixed
  camera scale.
- **Camera layers in 2D scenes** — in `scene_schema_part01_test`:
  `PerspectiveCameras.ACameraObjectDoesNotTakeACanvasSceneOffItsCanvas` next to
  `.ADefaultCameraObjectBecomesTheActivePerspectiveCamera` and
  `ShotFieldOfView.ShotsTakeTheirOwnFovElseTheSceneFov`; in `scene_schema_part02_test`:
  `CanvasShots.ACameraTimelineGlidesFromItsFirstShotToWhereItRests`,
  `.TheLastVisibleShotFramesTheViewAndIsDecidedAgainEveryTick` and
  `.AScriptedShotOriginCountsOnlyOnceATickHasAppliedIt`.
  - `orthogonalprojection` decides what a scene is. When present, the canvas
    projects the scene (`ParseCamera` makes `cameras["global"]` the active
    orthographic camera) and every 2D layer's size, `origin` and `alignment` is
    authored in canvas space; a `camera` layer there is parsed, bound and
    scriptable like any node but never touches `scene.activeCamera`. When it is
    null, a camera projects the scene and a `camera` layer is the shot it plays.
  - The shot still frames the canvas it does not own: at the end of each tick,
    after every script and visibility/origin writer, `ApplyCameraShots` passes
    the last visible shot (authored order) to `Scene::FrameCanvas`. Its `zoom`
    narrows the orthographic view about the view centre, and its origin `x`/`y` is
    that centre's offset from the canvas centre, not a canvas coordinate. The
    perspective camera keeps its field of view, takes the same centre and moves its
    eye to the distance that field of view gives for the visible height. With no
    visible shot the whole canvas shows, and nothing is reframed while zoom and
    offset stay the same.
  - A script-bound origin is pending until the first tick has applied it (the
    view stays on the canvas centre until then); the editor's static `value`
    beside such a script is never drawn. A relative origin curve offsets the
    authored origin; zoom and origin keyed together share the zoom's clock. A
    single-play timeline that has ended stops counting as animation demand, so
    an otherwise still scene can go idle after its intro.
  - Perspective shots with an omitted or nonpositive `fov` inherit the scene's
    resolved FOV (`fov`, then 50; `perspectiveoverridefov` is the lens of a 2D
    scene's perspective layers and is ignored here); a positive shot FOV
    overrides. Resolve it from authored scene settings, never from a shared
    camera an earlier visible shot may have changed.
  - Framing moves no node and rebuilds no graph, so a fullscreen layer's last
    pass uses the `fullscreen` camera (always the canvas), a layer sampled as
    `_rt_imageLayerComposite_<id>` is drawn through a layer-local camera
    (`LayerCompositeCameraKey`) that ignores placement, view and parallax, compose
    cameras are not layer-local (children draw through them at their place inside
    the layer), and the static-result cache folds each pass's camera and the
    active camera into its sample (`FoldPassCameras` in `RenderCommon/SceneRaster.hpp`).
- **Camera-object zoom in 2D scenes** — `CanvasShots.ZoomTightensTheOrthographicFrustumWithoutChangingTheAuthoredExtent`
  and `ZoomOutsideTheUsableRange.FramesTheWholeCanvas` in
  `scene_schema_part02_test`, `MouseInput.HitTestingFollowsACameraObjectZoomAcrossAResize`
  in `mouse_input_test`. `zoom` is applied when the ortho projection is built,
  not by writing camera width and height, because `ApplyCameraFillMode` rewrites
  those from the authored canvas whenever a fill mode is applied. Pointer mapping
  must read `SceneCamera::VisibleWidth/VisibleHeight` (the extent the projection
  uses), not `Width()`/`Height()`, or clicks and mouse-linked particles stay on
  the unzoomed image. The authored extent the render targets are sized from must
  not move with zoom.
- **The camera perspective layers of a 2D scene draw through** — in
  `scene_schema_part10_test`: `FlatSceneEye.ThePerspectiveCameraSitsWhereTheFieldOfViewPutsIt`
  (field of view `perspectiveoverridefov`, 95 when absent whatever `fov` says; eye
  at `(H / 2) / tan(fov / 2)`, near 5, far `max(D + 1000, 15000)`; the canvas plane
  maps as the orthographic view maps it; a point `z` out is magnified by
  `D / (D - z)` and stays in view up to the near plane, past 1000 units or not),
  `SceneSchema.TheFieldOfViewOfA2DScenesPerspectiveCameraIsReadFromAnyPackageVersion`
  (`scene_schema_tests`) and, in `scene_schema_part06_test`,
  `CanvasCamera.ATimelineOnTheSceneZoomFramesTheCanvasWithoutResizingTheTargets` (the zoom
  moves the eye, not the field of view); in `layer_texture_reference_test`:
  `CameraFraming.APerspectiveCameraKeepsItsLensAndFollowsEveryWayTheCanvasIsFramed`
  (every fill mode, `FrameCanvas`); in `metal_scene_draw_smoke`:
  `MetalSceneDraw.APerspectiveLayerIsSeenFromTheEyeDistanceOfTheScenesFieldOfView`
  (a card 500, 1100 and 1400 units out is the width the eye distance gives on both
  renderers) and, in `perspective_image_layer_test`,
  `PerspectiveImage.ACardWithTheFlagIsEnlargedByItsDistanceFromTheCameraPlane` and
  `.ACardWithEffectsIsSeenThroughTheCameraByThePassThatPutsItOnTheScene`
  (the card's own `perspective` flag, drawn as it is and through an effect, on both
  renderers: it was drawn flat, 30 pixels where the camera gives 44.5, and a cover
  laid on a model's face slid off it once a group turned them). The eye sat at 1000 units with a field of view derived from it, so a
  particle 500 units out was twice its size and one past 1000 units was cut; the
  distance is the scene's own, in one helper (`FitCanvasPerspective`) that the
  parser, `Scene::FrameCanvas`, the scene zoom and `ApplyCameraFillMode` share.
  The camera's distance is not the eye the shaders read: `g_EyePosition` of a
  perspective particle or model stays over the view's centre 2000 units out
  whatever the field of view or the framing (`Renderers.APerspectiveParticleReadsTheEyeTwoThousandUnitsOutWhateverTheLens`
  in `particle_parity_test`, `CanvasCamera.AShaderEyeSitsAtTheViewCentreTwoThousandUnitsOutWhateverTheLens`
  in `scene_schema_part06_test`), or a particle trail would turn its ribbon by an eye
  that moves with the lens. `perspectiveoverridefov` is a 2D scene's lens only: a
  scene with a perspective projection keeps `fov`
  (`ShotFieldOfView.ShotsTakeTheirOwnFovElseTheSceneFov` in `scene_schema_part01_test`).
- **Perspective camera shots and paths** — in `scene_schema_part01_test`:
  `PerspectiveCameras.TheLastVisibleShotPosesTheCamera`,
  `.CameraPathsSampleQueueAndCarryTheirOvershoot` and
  `.ACameraPathAndALayerTimelineShareOneClock`; in `scene_schema_tests`:
  `SceneSchema.RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup`,
  `.CameraPathsPreserveSteepAndRolledLookAtOrientation` (near-vertical and Euler
  singularities) and
  `.PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly`. The last
  effectively visible shot for a camera owns its pose and FOV; hidden presets
  cannot reattach that shared camera; with no visible shot the editor pose
  returns. Packaged eye/center/up/FOV curves share the path clock, with
  sequential or random queuing and bounded catch-up; only selected paths advance,
  hidden paths add no animation demand, and curves are parsed once. Camera-path
  zoom, path events and camera-cut fades are not implemented.
- **Camera parallax** — `ShaderValueUpdaterCompat.CameraParallaxMovesEachLayerTreeByItsRootsDistanceFromTheCursor`,
  `.ZeroParallaxDelayFollowsTheCursorAtOnce` and
  `.ParallaxLayersAreReportedAsFollowingTheCursor` in `script_runtime_compat_test`;
  `ScriptRuntimeCompat.AComposeLayersFirstPassReadsTheScreenWhereParallaxDrawsItsCard`
  in `script_runtime_compat_test`;
  `PuppetParallax.TheLayersDepthReachesEverySlotNotJustTheFirst` in
  `scene_schema_part06_test`; `ModelParallax.AModelUnderAGroupMovesByTheGroupsDepthNotItsOwnStaleZero`
  in `model_parallax_test`; `TextObjectRuntime.CameraParallaxMovesAPlainTextLayerByItsDepth`
  and `.ATextLayerUnderAGroupRidesTheGroupsParallax` in `text_object_runtime_test`;
  `MetalSceneDraw.CameraParallaxMovesATextLayerAsItMovesAnImage` and
  `.AComposeLayerHoldsWhatIsBehindWhereParallaxDrawsIt` in
  `metal_scene_draw_smoke`.
  - In a 2D scene, as in Wallpaper Engine, parallax moves each layer tree by its
    outermost layer's distance from the eased cursor point, times that layer's
    `parallaxDepth` and `cameraparallaxamount`. The point rests at the view centre
    and moves with the cursor by `cameraparallaxmouseinfluence`, so with the cursor
    centred a layer off the centre already sits further out, by
    `(origin - centre) x amount x depth`. Every layer of a tree, and every effect
    pass of a layer, takes the outermost layer's current origin; a layer that
    leaves `parallaxDepth` out has depth (1, 1). A layer under a depth-0 group does
    not move. 3D scenes use each layer's own distance from the camera.
  - A pass parallax moves is reported as following the cursor (`kParallax`),
    judged for the camera the pass draws through: static reuse redraws its
    target, and an on-demand scene wakes for the pointer. A layer drawn into a
    composite through its layer-local camera is not moved, so that composite stays
    reusable (`LayerTextureReference.AReferencedLayerIsItsCardWhereverTheSceneShowsIt`
    in `layer_texture_reference_test`). What this costs is under
    [Known limitations](renderer.md#known-limitations).
  - A text layer is a parallax layer like any other: Wallpaper Engine's draw loop
    adds the offset to every object it draws, text included. A text layer its own
    card draws straight onto the scene (no effects, so no pass carries its depth)
    gets the value updater record that holds its `parallaxDepth`, as an image layer
    without effects does. Without it the layer stayed on its origin however the
    cursor moved, out of step with the layers around it at the same depth, which
    sit `(origin - centre) x amount x depth` off theirs even at rest. The unit tests
    read the model matrix of the text pass at rest and with the cursor at the edge,
    its `kParallax` report, and a text under a group riding the group's depth and
    anchor; the Metal test draws a text and a 64 pixel square at the same distance
    from the centre and measures how far their ink moves against
    the same scene at depth 0, with the cursor centred and away from the centre, and
    for a text drawn through a copy effect (moved once, not twice).
  - A model is a parallax layer too, and its value updater record holds its
    `parallaxDepth`; under a group it rides the group's depth and anchor, as text
    does. Without it the model stood still while the image layers laid on its
    faces, under the same group, moved, so a cover slid off the box it sits on and
    the box showed as a dark slab beside it. The unit test reads the model's
    matrix with the cursor centred and at the edge, and its `kParallax` report.
  - A compose layer with effects holds the screen behind the place its card is
    drawn. Its first pass maps the card onto the screen through the layer's
    model-view-projection (`composelayer.vert`) and its last pass draws the card,
    and Wallpaper Engine's draw loop gives both the same parallax offset. The
    layer's own node holds no depth (a layer drawn through effects has it on its
    effect passes), so the first pass was not moved: it read the screen at the
    unshifted place and the card showed the scene displaced by its own offset, a
    hard-edged slab wherever the effect keeps the copy (an audio-bar layer that
    draws nothing in silence). A pass that reads the screen now takes its depth
    from `NodeParallaxDepth`, which asks the effect passes first, and measures
    the offset from the scene camera its matrix is built with. That matters for a
    layer without children, which frames its effects, and so draws its first
    pass, with a camera at the origin; a layer with children is drawn through the
    scene camera already (the render graph names it) and lacked only the depth.
    `FrameVaryingUniforms` reports `kParallax` for the pass by the same rule. An
    ordinary effect layer's first pass draws into its own target and is still not
    moved, nor is a compose layer drawn into a composite through a layer-local
    camera. A depth a script writes reaches the layer's effect passes and not the
    record of its own node, so it moves the card and what a compose layer reads,
    leaves an ordinary effect layer's first pass where it is, and asks for a new
    render graph only when a layer starts or stops following the cursor. The unit
    test compares the first pass's model-view-projection with its card's, for a
    layer with children and one without, with the cursor centred and away from the
    centre and again after a script writes a depth; the Metal test puts a compose
    layer, alone and over a child, through an effect that inverts red in a depth-2
    group over an asymmetric backdrop and requires the backdrop with red inverted
    where the layer is drawn and nothing changed outside it.
  - `cameraparallaxdelay` of zero means no easing. Dividing by it makes the eased
    cursor NaN, which reaches every parallax layer's model matrix and leaves only
    the clear color.
  - `ShaderValueUpdaterCompat.ParallaxEasesAsWallpaperEngineWhileShadersSeeTheCursor`:
    parallax closes `(1 - delay / 3) * 10 * frametime` of the way to the cursor
    (clamped to the window) each frame, while `g_PointerPosition` is the cursor
    itself, not the eased one.
- **Parallax inheritance** — in `scene_schema_tests`:
  `SceneSchema.ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder`
  (nesting, zero/default depth, missing/duplicate parents, cycles),
  `.ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers`,
  `.ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds` and
  `ParentedPuppet.AGroupsOutermostDepthAndOriginDecideTheShiftWhateverTheDeclarationOrder`
  (`scene_schema_part06_test`); and
  `MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses` in
  `metal_scene_draw_smoke`. Parented layers take the outermost parent's
  `parallaxDepth`, including a zero one or an omitted one, which is (1, 1) (Wallpaper Engine's
  [release notes](https://steamcommunity.com/app/431960/allnews/) confirm that
  the parent controls parallax on child layers). `ResolveLayerParallax`
  resolves it once at parse time, independent of declaration order and before
  materials are built, with no per-frame ancestor walk. Missing or ambiguous
  parents supply no depth, cycles stay unresolved, and IDs and parent references
  must be integers in the signed 32-bit range (wider JSON numbers are ignored,
  never truncated into another layer's identity).
- **Fullscreen layers** — `CameraFraming.AFullscreenLayerCoversTheScreenWhateverTheShot`,
  `.AFullscreenEffectCoversAPerspectiveScene` (independent of the perspective
  FOV) and `.MovingTheCameraChangesTheStaticSampleOfAPassItDraws` in
  `layer_texture_reference_test`. Fullscreen effects use the screen-space
  `fullscreen` camera in 2D and 3D scenes.
  - A fullscreen layer ignores its ancestors' transform
    (`SceneNode::SetIgnoreParentTransform`, set by `ParseImageObj`; the group still
    decides visibility through `EffectiveVisible`). Wallpaper Engine lays the layer
    over the whole screen whichever group it sits in; placed by the group's world
    matrix, its result was the screen shifted, scaled or turned by the group, with the
    screen's own corner showing in the opposite one.
    `CameraFraming.AFullscreenLayerCoversTheScreenWhereverItsParentSits` (a moved,
    scaled, turned and nested group, before and after the runtime ticks, which mirrors
    the layer's matrix onto its final card) and
    `.ParallaxDoesNotCarryAFullscreenLayerWithItsParent` (parallax walks to the
    outermost layer of a tree, and a fullscreen layer is its own) and
    `.AGroupStillDecidesWhetherAFullscreenLayerShows` (a group bound to a property
    hides and shows the layer, which covers the screen whenever it shows) in
    `layer_texture_reference_test`;
    `MetalSceneDraw.AFullscreenLayerCoversTheScreenWhereverItsGroupSits`
    draws a four-quadrant backdrop through a pass-through fullscreen layer alone and
    under a moved, scaled and turned group, and requires every picture to equal the
    backdrop alone.
  - The layers below a fullscreen layer are placed from its saved transform
    (`SceneNode::SetChildFrame`, set by `ParseImageObj` from the origin, scale and angles
    the scene saved, which default to none; `SceneNode::ChildTrans` is what children
    compose on, so the groups above still carry them). The layer is drawn at the screen
    centre with scale 1; its children were placed from that centre too, a canvas away
    from where they were saved (the "Post-processing Layer" of 3804689861, with a
    3840 x 2160 picture saved at the canvas centre, drew a quarter of it). A fullscreen
    layer with effects and children renders as a composition layer does
    (`fullscreen_holds_children` in `ParseImageObj`), so its effects reach the children.
    The children are drawn into that target through the scene camera, not the layer's
    compose camera (`SceneCamera::ChildrenUseSceneCamera`, which
    `ResolveNearestComposeTarget` reads to leave the draw's camera alone), so zoom,
    camera shake and camera shots reach them as they reach the screen copy behind them;
    through the compose camera, a fixed view of the canvas, they stayed unzoomed and still
    while the scene shook (3743578252's foreground fish). Parallax walks past the
    fullscreen layer to the group it sits in for the layers below it, and for a top-level
    fullscreen layer measures them from its saved origin (its `ChildTrans`).
    `CameraFraming.TheChildrenOfAFullscreenLayerAreSavedAgainstItsSavedTransform`
    (no origin, an origin, a scale, under a moved group; the layer still fills its target)
    in `layer_texture_reference_test`;
    `MetalSceneDraw.TheChildrenOfAFullscreenLayerAreSavedAgainstItsOwnTransform`
    saves one backdrop against seven shapes of tree (no origin, with an effect, an origin,
    a scale and a turn, nested, under a moved group, under a scaled and turned group) and
    requires each to equal the backdrop alone, and
    `.TheEffectsOfAFullscreenLayerReachItsChildren` requires an effect that
    keeps only red to leave no green or blue of a child.
    `.TheChildrenOfAFullscreenLayerFollowTheSceneCamera` draws a 64 x 64
    card under a fullscreen layer with and without an effect, zoomed 2x, shaking, and
    both, and requires each to equal the card drawn plain under the same camera.
    `.ParallaxMovesTheChildrenOfAFullscreenLayerWithTheirTree` (amount 0.5,
    cursor centred) requires a picture under group -> fullscreen layer (with and without
    an effect) and under a top-level fullscreen layer saved where the group is (children
    inheriting its depth 2) to equal the picture under the group alone.
    `Shaders/FullscreenParallax.*` in `scene_fullscreen_parallax_test` (amount 0.5, the cursor
    at the top-left and then the bottom-right corner, a backdrop at depth 1; on both
    shader flavours of a pass-through material) requires a top-level fullscreen layer
    without an effect, with one, saved with depth 0, saved with depth 0.5, saved off
    the canvas middle, and saved where the backdrop is with the backdrop below it, to
    draw exactly what the backdrop alone draws under the same cursor;
    `FullscreenParallaxBaseline` requires a normal layer at depth 1 to move at all, which
    the other cases would otherwise pass without. `WPImageObject::FromJson` gives a
    fullscreen layer depth 0 and never reads the one in the file, and the default depth 1
    moved the last pass of its effects, so the copy of the screen was drawn a second time,
    shifted by the cursor, over the scene (3521337568's film-grain post-processing layer).
    The layers below it keep their tree's depth (`ResolveLayerParallax`, which copies the
    outermost layer's saved depth into its descendants).
    Established from the 2.8.42 decompile (the layer's own draw ignores its model matrix;
    children are drawn through its composite) and from two local scenes, not from a
    Wallpaper Engine frame of a scene that has the layer: 3804689861's author preview
    fills the frame with the picture, and 3743578252 animates the groups its fullscreen
    layers sit in so that their fish swim, which needs the groups to carry the children.
    Not compared pixel for pixel: the previews are a close-up and an edited loop. 3743578252
    now draws its large dark foreground fish at scale 3.7 across the frame early in its
    timeline, which a Wallpaper Engine frame at the same time would settle.
- **A pass-through layer in a group reads the screen where it is drawn** —
  `Shaders/PassThroughLayout.*` and `PassThroughLayoutMoved.*` in `scene_passthrough_layout_test`
  draw a four-quadrant backdrop through a pass-through layer whose effect returns what
  it receives, so every picture has to equal the backdrop alone: the layer alone, a
  project layer with no origin in a group at the canvas centre (both shader flavours of
  a pass-through material), and, with the camera flavour, under a moved, 2x-scaled group
  (away from the 3-pixel band its half-sized card softens). The effect also makes the
  result opaque, so a card that copies the wrong part of the screen leaves black instead
  of letting the backdrop show through. The card that copies the screen
  (`PassthroughCardVertices`) used to be laid out from the layer's own origin, which is
  relative to its group, before any layer had a parent: issue #53's CRT "Full Composition
  Layer" (a project layer under a centred group) copied the screen half a canvas off and
  showed a half-sized copy of the scene in one quadrant. `LayOutPassthroughCards` now lays
  every card out from the layer's world matrix once the tree exists, and
  `SceneRuntimeContext::ApplyPassthroughCards` does it again at the end of a tick when that
  matrix is not the one the card was last laid out from, and never otherwise. The tests
  move the group once the scene has loaded (a slider bound to its scale and a
  property bound to its origin; a script on its origin; another layer's script on a group
  whose file holds plain values), and require the frames after to equal the backdrop and
  `PassthroughCardLayoutCount()` to have grown by exactly one per change and by nothing
  on the frames in between. A card that anything the file says can move (an origin, scale
  or angles that is a property, script or timeline, on the layer or an ancestor) is an
  `OnEvent` mesh, rewritten in place with no new graph; any other card is fixed geometry,
  and a move nothing declared (the last case) rewrites it and builds the graph again once,
  so a still scene keeps its static reuse of the chain. The pass that draws the footprint
  straight into clip space (the material shader named `passthrough`) lays the copy out
  in canvas coordinates, which is the screen again only for a layer covering the canvas; the
  moved and scaled cases are not required of it.
- **One cursor mapping, owned by the presentation** —
  `SceneRuntimeContext::SetCursorInput` maps window-normalized input through the
  cursor viewport the renderer publishes (`origin + (x, 1 - y) * size`) and writes
  it to `Scene::pointerScenePosition`, so consumers outside the script runtime
  read the same point instead of deriving their own. A particle control point that
  maps the pointer over the canvas (`pointerPosition * ortho`) agrees with the
  cursor only at the window centre once a wallpaper is cropped (`fill`) or
  letterboxed (`fit`). `ParticleMouseControlpoint.MouseControlpointFollowsTheCroppedPresentation`
  in `particle_mouse_controlpoint_test` (run by `check_renderer.py`) guards it.
  `offscreen_scene_probe` with `WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill` prints
  the mapping a running wallpaper would use. Nothing exercises `SceneWallpaper`'s
  own message loop offscreen, so the host's half (polling the pointer and
  publishing the viewport) is covered only by `mouse_input_test` at the unit
  level.
- **Cursor hit testing under scaling** — `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`,
  `.LayerHitTestingFollowsWhereTheWallpaperIsPresented` and
  `.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`;
  `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper`
  in `script_runtime_compat_test`. Scene coordinates reach the window through two
  transforms: the global camera rectangle fills the default render target, and
  `ComputeWallpaperScalingLayout` places that target in the window (`FILL`
  deliberately pushes it outside to crop). Cursor input arrives as a window
  fraction and is mapped back through both (`ComputeWallpaperCursorMapping` →
  `SceneRuntimeContext::SetCursorViewport`); mapping onto the raw canvas matches
  only when scene and display share an aspect ratio and otherwise squeezes every
  `cursorEnter`/`cursorLeave` box toward the screen centre. The mapping also
  reports the drawn content rectangle: coordinates extrapolate past it (scripts
  read positions outside the canvas), but named layers take cursor events only
  while the cursor is inside it, so letterbox bars never trigger a layer whose box
  crosses the canvas edge.
  The picture can also be positioned inside its slack (`WallpaperFraming`, the
  trailing `pan_x`/`pan_y` of `ComputeWallpaperScalingLayout`); the mapping derives
  from `layout.viewport_px` alone, so the pointer follows the position with no mapping
  of its own. `WallpaperScaling.CursorMappingFollowsThePannedPresentation` in
  `wallpaper_scaling_test` (CPU only, run by `check_renderer.py`) requires the window's
  left edge to map to the camera's left edge at a pan of 0 and the right edges to meet
  at 1, with the drawn content rectangle and the clip unchanged.
  `.DefaultPanIsBitExactWithTheCentredLayout` compares every mode against an in-test
  copy of the old centring arithmetic, so the default can never move a wallpaper by a
  pixel; a change to the layout function's arithmetic order has to keep it green.
- **`input.cursorWorldPosition` in a perspective scene** — `MouseInput.APerspectiveSceneHandsScriptsTheCursorRayPointAtTheFarPlane`,
  `.ThePerspectiveCursorPointLiesOnTheCursorRayOfAMovedAndShakenCamera`,
  `.ACameraPointAtDepthIsOnlyDefinedForAPerspectiveViewAndARealDepth`,
  `.AHeadScriptThatFollowsThePerspectiveCursorTurnsAsInWallpaperEngine`,
  `.ACanvasSceneKeepsTheCursorInCanvasUnitsEvenWithAPerspectiveCameraAround`,
  `.APerspectiveSceneStillHitsLayersWhereTheyAreDrawn`,
  `.AParticleControlPointFollowsTheCanvasPlaneCursorInAPerspectiveScene` and
  `.ThePerspectiveCursorPointFollowsThePictureWhenTheWindowCropsOrLetterboxesIt` in
  `mouse_input_test`. A display-sized
  scene (`Scene::display_sized`, the one with a perspective camera) gives scripts the point on
  the cursor ray `farz` in front of the eye (`UnprojectNdcAtDepth`), found from the cursor's
  NDC in the presented frame (a window that crops or letterboxes the picture moves it with the
  picture, not with the window); a canvas scene keeps canvas units with `z = 0`. Hit tests and
  `Scene::pointerScenePosition` (a particle's mouse control point) read the canvas-plane
  position (`SceneRuntimeContext::m_cursor_plane_position`), never that point. The head test runs the
  neutral-zone script of workshop 3477054430 with the cursor in the middle and the scene's
  camera, and requires the pose Wallpaper Engine showed (pitch -6.1, yaw -61.4 degrees,
  where canvas pixels give about -15 and -6). End to end, `metal_scene_draw_smoke`'s
  `LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend` with
  `WE_TEST_INPUT_JSON='[{"frame":0,"x":0.5,"y":0.5,"inside":true}]'` draws that wallpaper's
  head turned as Wallpaper Engine's frame shows it.
- **`engine.screenResolution`** has its own setter:
  `SceneWallpaper::publishScreenResolution` reports the display's pixels on scene
  attach and whenever the surface is replaced. `RenderInitInfo::width`/`height`
  already are those pixels (the renderer divides by `display_scale_factor` for
  logical points), so scaling them again doubles the resolution on Retina panels.
  It is neither the world region the cursor mapping publishes nor the
  rasterization size: a quality setting must not move a script's layout.
- **Cursor coverage masks** — `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask`
  in `script_runtime_compat_test`. Hit tests run in the layer's local plane
  (rotated and flipped buttons keep their rectangle) and, for image layers whose
  scripts handle cursor events, consult a coverage mask sampled from the albedo
  at parse time (RGBA8/BC2/BC3, at most 256 texels per side, alpha ≥ 16 counts as
  covered): transparent texels do not hit, so overlapping triangle buttons do not
  fire together. Puppets, videos, sprite sheets and opaque formats keep the
  rectangle test. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises
  real assets.

- **Which layers the cursor reaches** — `MouseInput.OnlySolidImageTextAndModelLayersAreHitTested`,
  `.ALayerThatDisablesPropagationHidesTheLayersBehindItFromTheCursor`,
  `.OnlyAVisibleBlockerInFrontStopsTheWalk`,
  `.ALayerBehindABlockerHearsNeitherTheDownNorTheClickOfAPress`,
  `.TheBlockerInFrontFollowsTheLayerOrderAndAFrameInProgress` and
  `.ARolledBackRegistrationRestoresTheCursorTargetOfTheLayerItReplaced` in
  `mouse_input_test`; for the parse
  `TextObjectRuntime.ATextLayerRegistersItsSolidAndPropagationFlagsForTheCursor`,
  `ModelLayerParse.ModelLayersAreCursorTargetsUnlessTheySayOtherwise`,
  `LayerTextureReference.ImageLayersAndGroupsRegisterTheirCursorTargeting` and
  `.LightsCamerasParticlesAndGroupsAreNeverHitTestedForTheCursor`. Wallpaper Engine walks the layers front to back and tests only solid
  (default on) image, text and model layers, by their quad; a plain group, a
  particle, a light or a camera is never tested. A visible layer under the cursor
  with `disablepropagation` ends the walk: the layers behind it hear no enter,
  leave, move or press, and keep the hover state they had, so a hovered layer is not
  left when a blocker moves over it. A blocker needs no script of its own, and one
  that is hidden, not solid, or behind the layer in question blocks nothing. The
  layer order is the scene's own (`LayerNameAt`). The frontmost visible blocker under
  the cursor is found once for a frame's cursor events (a walk from the front over
  the layers in order, one hit test per blocker it reaches) and a layer is out of the
  walk when it stands behind it, by a rank looked up in a map rebuilt when the order
  changes; the search is dropped again whenever a cursor callback has run, since a
  callback can hide or move a blocker, and costs nothing in a scene with no blocker.
  A cost has not been measured on a scene with many scripted layers and one blocker.
  Not modelled: Wallpaper Engine's walk skips blocking while a button is held and a
  captured set is non-empty, and fires its click on release rather than on press.

## Scene scripts and property bindings

All in `script_runtime_compat_test` and `scene_schema_tests` unless noted.

- **Script values, objects, start-up and local rotation without a device** —
  `scenescript_behavior_test` loads synthetic scenes for their runtime only
  (`tests/support/script_scene.hpp`, no Metal device, surface or window) and ticks them:
  - `ScriptVectorNumbers.*`: a scale eased with `value.x + (2 - value.x) * k` stays
    uniform, finite and monotonic for 30 frames; a two-component constant returning
    `value.y + 1` steps by one on both components; a number returned for angles, origin
    and colour, and written to `thisLayer.color` / `parallaxDepth`, fills every
    component; a script that returns nothing leaves a vector alone.
  - `Choices/ChoiceAsFlag.*`: two script properties bound to one combo with conditions
    `0` and `2` read `true`/`false` (typeof boolean) as the choice moves through 2, 0, 1,
    as a number and as text; a conditional layer `visible` follows the choice; a constant
    bound with a condition reads 1 or 0 while one with no condition keeps the number.
  - `ScriptEffectObject.*`: `thisObject.visible` of an effect script, written from
    `init`, `update` and a media handler, switches that effect only (also where a
    property hid the layer, and with two effects on a layer).
  - `ScriptKeyedSettingObject.*`: `thisObject.getAnimation()` with no name is a keyed
    constant's own animation (the layer's slide does not play); a named lookup still
    finds the layer's animation; a setting without a timeline finds the layer's first
    unnamed one.
  - `ScriptStartUp.*`, `ScriptInitResult.*`: all `init`s, then all first notices, then
    `update`, in layer order; a notice may call what a later layer's `init` set up through
    `shared`; what `init` returns is the value (a handle hides itself, a typing text starts
    empty, a vector or number is converted as `update`'s is), and nothing, an exception or
    an object for a flag leave it alone.
  - `ScriptLayerNames.*`, `ScriptSoundLayers.*`: twin, unnamed and twin text layers keep
    their authored names and are found and moved by name, also by a script that looks a
    later layer up while it compiles; sound objects are listed in order, counted, found
    by id and name, played and stopped through the layer object, twins played separately;
    a statically invisible sound has no index.
  - `Rotation.*`: `rotateObjectSpace` increments about each axis from a known orientation,
    successive calls, a rotated and scaled parent, mirrored scale and an anchored pivot,
    with expectations worked out from rotation matrices in the test.

- **Local-axis rotation** — `Rotation.*` in `scenescript_behavior_test` checks radians
  increments composed with an existing orientation, degree-valued angles readback,
  repeated updates, transformed parents, mirrored scale and anchored pivots.
- **Property-bound scene shading** — `LightingFog.HeightFogBoundToPropertiesEqualsTheSameFogWrittenOut`
  (`scene_lighting_fog_test`) draws a known squared-density gradient from a scene with
  property-selected endpoints and colour and compares it with the same fog written out;
  `.AmbientAndSkylightAreEachBoundAndEachCounted` checks ambient and
  skylight contributions independently in the resulting pixels.

- **Callback-only property scripts** — `*CallbackOnly*` in both binaries.
  Callback-only scripts keep their no-writeback behavior.
- **Script property load order** — `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue`.
  As in Wallpaper Engine, a layer's saved and user-bound `scriptproperties` reach
  the script after its module has run: top-level code reads the defaults the
  script declares, `init` and `update` read the values. A switch that moves its
  layers by the difference from a top-level reading stays where it was authored
  if the module already sees the user's position.
- **Module syntax** — `ScriptRuntimeCompat.ExportFollowedByUnicodeWhitespaceStillCompiles`,
  `.AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty` and
  `ScriptModuleSyntax.*`. `Scripting/ScriptModuleSyntax` is the one matcher for
  `export` and `export function update`, shared by the module rewrite and both
  update detections (`HasUpdateScript` in the parser, `wrap_script_if_needed` in
  the resolver). ECMAScript whitespace between the tokens counts, including the
  U+00A0 that text pasted from a rich-text editor carries and U+FEFF (not Unicode
  White_Space), and only where a statement can start, so `reexport` and
  `module.export` are not the keyword. Only the pure `ScriptModuleSyntax` test
  uses the rarer separators; the two that compile JavaScript through the linked
  QuickJS use U+00A0. The rewrite erases only the keyword, so a comment ending in
  the word keeps its line break.
- **Property-script feedback and hover easing** — `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping`
  and `.PropertyFeedbackResumesFromExplicitUserValueChanges`. `update(value)`
  receives the current value, including the previous frame's result and explicit
  property writes, not the authored value on every tick; that preserves iterative
  hover easing, full authored enlargement and continuous reversal on cursor leave
  and re-entry. JavaScript input conversion serializes only the value payload,
  without copying the live property's listener/subscription ownership.
- **A number returned for a vector property** — `ScriptVectorNumbers.EasingAScaleWithABareNumberStaysUniformFiniteAndMonotonic`,
  `.ATwoComponentShaderConstantStepsByTheNumberOnBothComponents` and
  `.WritingANumberToColourAndParallaxDepthSetsEveryComponent` in `scenescript_behavior_test`.
  `FillDynamicValueFromJS` turned a number into a Float whatever the property's
  type, so a `scale` script returning `value.x + (target - value.x) * speed` handed its next `update` a bare
  number, `value.x` was undefined, and the layer's scale and position went NaN from
  the second frame (a default-on clock never drew). A number for a vector type now
  fills every component of that type (`UpdateVectorFromNumber`), so the property stays
  a vector. The tests ease a node's `scale` toward 2 through a script property for 30
  frames (finite, uniform, monotonic, no script error) and step a two-component shader
  constant that returns `value.y + 1`. The same conversion serves the `thisLayer`
  setters, so `color` and `parallaxDepth` now take a number on every component
  (the third test writes `0.5` and `0.75` to them); both ignored it.
- **Native writes survive `update()`** — `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined`.
  "Keep the current value when `update()` returns `undefined`" only works if the
  current value includes what the script wrote, so evaluation continues from the
  live dynamic value, not a private copy of the authored base. Native writes
  (`thisLayer.visible = …`, `origin`, `scale`, `angles`) arrive through the typed
  `DynamicValue::update` overloads and must reach the next `update(value)`. The
  canonical case hides its layer in `init()` and sets
  `thisLayer.visible = alpha != 0` in `update()` without returning a value.
- **Script-driven layer visibility** — `HiddenLayerWithVisibilityScript.FollowsTheScriptInsteadOfBeingDropped` and
  `HiddenLayerWithoutScript.IsNotBuilt` (`scene_schema_part04_test`).
  A layer setting may carry `value`, `user` and `script` at once. `value` is the
  script's initial value, never a permission to run it: a layer authored hidden at
  rest (day/night or weather switchers) still runs its script, and dropping the
  binding leaves a scene drawing only `general.clearcolor`.
  `PropertyScriptProgram::Evaluate` keeps the current value when a script throws,
  returns `undefined`, or returns an object for a boolean, so a hidden helper
  layer cannot be revealed by accident.
- **User-bound image colour** — `LayerColourReachesEveryMaterial.BoundAndScriptedColoursTintTheLayerAndEachEffectPass`
  and `.TheDeclaredPropertyValueBeatsTheSceneFileValueAtParse` in `scene_schema_part09_test`,
  `ObjectSchema.ASystemPictureOverTheWhitePlaceholderDropsTheTint` and
  `.APropertyPictureKeepsTheTint` in `scene_schema_part01_test`. An image layer's
  `color` of `{"user": …, "value": …}` is the property's value; `value` is only
  its default, so a Workshop preset or a saved colour must replace it (issue #43:
  a preset's black drew in the base's red). `ParseImageObj` resolves it once
  before building `g_Color`/`g_Color4`, then `BindMaterialColor` feeds the layer's
  own material, every effect pass and a compose layer's passthrough from one
  value, keeping each `g_Color4` alpha. It is a listener, so it costs nothing per
  frame and runs only when the property changes. A layer whose placeholder a
  runtime image replaces drops a bound colour as it drops an authored one, and so
  does a solid placeholder whose slot a `scenetexture` property fills:
  `PlaceholderPicture.*` in `scene_placeholder_picture_test`. `WPImageObject` cannot
  read the properties, so `LoadImageEntry` resolves the layer's first slot against the
  loaded values as the material will (`ChosenPictureFillsPlaceholder`, over the same
  `ApplySystemUserTextures` that `LoadMaterial` uses); a preset's picture multiplied by its dark
  scheme colour drew the whole wallpaper black (issue #53). The tests draw a dark scheme
  colour over a chosen picture (a loose file the user picked, and a texture the preset
  ships), change the colour while the scene runs, and leave the property unset or name a
  file that is not there; the last two keep the placeholder's colour and keep following
  it. A layer with a picture of its own is still tinted by its colour. A host file that
  cannot be opened leaves the slot on the texture the material shipped
  (`TexturePropertyTextureName`); a name that a project does not hold takes the slot as it
  always did, but is no picture, so the placeholder keeps its colour.
- **Image layer brightness** — `LayerBrightness.TintsMaterialsOnlyWhereTheSceneRendersHdrAndFollowsItsBindings`
  (`scene_schema_part03_test`),
  `MetalSceneDraw.AnImageLayersBrightnessTintsItOnlyWhereTheSceneRendersHdr`
  and `.AnImageLayersBoundBrightnessFollowsItsPropertyAndScript`.
  Wallpaper Engine's layer draw (`FUN_140208670`, and the effect layer's final composite
  `FUN_140207740`) sets `g_Color4` to the layer's colour times its brightness only
  when the 0x2000 back-buffer bit is set, the HDR pipeline (`scene.hdr`, so `hdr` with
  bloom on), and to the colour alone otherwise. `ParseImageObj` builds `g_Color4` that
  way for the layer's own material, every effect pass and the compose passthrough;
  `SceneMaterial::tint` keeps the colour and the HDR brightness apart so a bound colour,
  a scripted `thisLayer.color` and a bound brightness each rebuild the product from
  the other's current value. The layer's brightness is not also the `g_Brightness` of
  a shader that declares one (`generic3`, `generic4`, `chroma4`, `foliage4`, an unversioned
  `genericimage2`): Wallpaper Engine reads the layer's brightness for the draw colour
  only and leaves that uniform, a material property, to the material; no stock shader
  declares both it and `g_Color4`. The pixel test draws grey 0.8 through a `g_Color4`
  shader (brightness 0.5, colour `0.5 1 1`: 0.2, 0.4, 0.4 in HDR, 0.4, 0.8, 0.8 without
  bloom or HDR), with and without a copy effect and a `g_Brightness` shader, changes a
  bound `glow` property while the scene runs and drives the brightness from a script.
  A text layer's brightness is separate (text-spec T6).
- **Scripted image colour** — `ColourScripts.*` in `scene_schema_part03_test`
  and `MetalSceneDraw.AnImageLayersColourScriptDecidesItsColour`.
  An image layer's `color` that carries a script is that script's value every frame,
  over the scene file's `value`, as on a text layer: `ParseImageObj` resolves it
  like a bound colour and `BindMaterialColor` feeds the layer's own material, every
  effect pass and the passthrough from the script's value. It is the colour the
  media widgets' template returns, black until `mediaThumbnailChanged` brings a
  cover's colour (the two tests run that template idle and after a cover), where the
  layer used to keep the scene file's colour for ever (the MP3 player's display of
  one local scene drew light teal where Wallpaper Engine draws black). A script that
  returns nothing keeps the colour, and one that writes `thisLayer.color` and returns
  nothing sets it: `SetNodeColor` also updates the bound value, as `SetNodeVisible`
  and `SetNodeTranslate` do, because `DynamicValue` notifies on every update and the
  bound value would otherwise put the old colour back over the write on the same tick
  (this was the reason a scripted `color` used to be left unbound). The Metal test
  covers a returned colour, a write, nothing returned, a plain colour, the idle
  widget and a cover, equal to each other; the schema tests read
  every material of a layer with an effect, a written colour over three ticks, a
  colour script made of `scene.on` handlers (queued as a scene script on its layer,
  and its write reaches the effect pass), a script whose next `update(value)` is given
  the colour it just wrote, a cover that arrives after them, and the scene's
  `Script` demand reason. The Metal test also has a cover that arrives after
  frames were drawn black. In an HDR
  scene the layer's brightness multiplies the script's colour into `g_Color4` like any
  other colour: `LayerColourPrecedence.AScriptOrAPropertyOwnsTheColourAndHdrBrightnessScalesOnlyTheTint`
  and `.WithoutHdrBrightnessLeavesTheTintAlone` (`scene_schema_part10_test`)
  keep the product through a colour a script returns and one it writes with
  `thisLayer.color`, and has the script's colour alone where the scene does not render
  HDR. Before the change a scripted colour stayed the scene file's on every material,
  so every case that depends on the script failed.
- **User properties and interactive scenes** — `applyUserProperties` runs once
  initially, then only for changed properties, after the whole property set has
  been refreshed. Exercise clock clicks and hidden-helper enter/leave through
  projected input (`WE_TEST_INPUT_JSON`, `WE_TEST_CLICK_*`), not by forcing
  overlay alpha. A closed author menu and an audio-driven wave with no audio are
  not evidence that a rendered frame has exercised either feature.
- **Script start-up order and what `init` returns** —
  `ScriptStartUp.EveryInitRunsBeforeAnyScriptIsToldTheUserPropertiesAndBeforeAnyUpdate`
  (`scenescript_behavior_test`; an options
  layer calls from its first `applyUserProperties` a function a later layer's
  `init` hands out, then sets the switch that keeps the widget shown) and
  `ScriptInitResult.*` (a handle that hides itself
  from `init`, a typing text that starts empty there, and an `init` that returns
  nothing keeping the scene file's value). Started one script at a time, the
  call threw and the switch was never set, so a music widget faded itself out;
  with `init`'s value dropped, its drag handle stayed on screen and its title typed
  onto the placeholder.
- **Layers scripts gather by name** —
  `ScriptLayerNames.TwinsAndUnnamedLayersKeepTheirAuthoredNames` and
  `.TwinTextLayersEachWithAScriptKeepTheirNamesAndAreFoundByThem`
  (`scenescript_behavior_test`; twin images, an unnamed image and a twin text, each with a script of its own,
  are found by name and moved by another layer's `init`) and
  `ScriptSoundLayers.*` (sound layers in
  the scene's order, found by id and by name, two that share a name played
  separately). A widget that moves its layers by name prefix left its cover behind,
  and one that finds its tracks by `.mp3` found none and threw when told to play.
- **User-switched effects** — `RenderGraph.parsedEffectVisibilityFollowsTheBoundUserProperty`
  (`rendergraph_smoke`, image layers) and
  `TextObjectRuntime.TextEffectVisibilityFollowsTheBoundUserProperty`. An
  effect's `visible` bound to a user property (`{"user": "toggle", "value":
  false}`, or a combo `condition`) holds the editor's value only as a default: the parser builds the effect when the
  property's current value says so, by the layer-visibility rule
  (`ResolveBoolSetting`), and keeps the authored value for a property the project
  does not declare. It is decided at parse time with no per-frame cost: a live
  property preview holds the property at the loaded value (see *Load-only
  properties* below) and Apply changes reloads. A scripted effect `visible`
  keeps its authored value. Reading only the default left colour modes and
  effect toggles in customizable wallpapers doing nothing.
- **Alignment anchors under dynamic transforms** — `AnchoredTransform.TheAnchorOffsetIsDerivedAgainFromScriptedOriginAndScale`
  (`scene_schema_part05_test`),
  `ScriptRuntimeCompat.RotatedAnchoredLayerTurnsAboutItsAnchor` and
  `.ScriptedRingBarsHangOutwardFromTheirCircle`, plus `nodes.txt` translate diffs
  from `offscreen_scene_probe`.
  - Alignment is an anchor, not a one-off offset. `SceneRuntimeContext` owns it
    for image layers and re-derives `origin + size * scale * 0.5` for the
    named edges whenever origin, scale, size or rotation changes; a text layer is
    not one of them (its alignment hangs its card from the node, see *Text
    placement about the origin*, and `SetNodeAlignment` turns a text layer
    down, as Wallpaper Engine's text object has no `alignment` to set). Baking the
    offset into the node translate loses it as soon as a scripted or user-bound
    origin writes the translate, and ignores scale. Centre-aligned image layers
    carry no offset. An alignment a script sets on a layer that had none
    (`bar.alignment = 'top'`) offsets by the scale delta,
    `size * (scale - 1) * 0.5`, so the unscaled layer stays where it was authored
    and grows away from that edge; this is the renderer's own convention, since
    Wallpaper Engine's SceneScript reference omits `alignment`.
  - The offset is turned by the node's rotation (x, y, z order of
    `SceneNode::GetLocalTrans`), so a turned layer keeps its named edge on the
    origin. Every rotation write re-derives the anchor: `SetNodeRotation`
    (`layer.angles`), `RegisterNodeRotation` and the bound-angles pass of `Tick`.
    Unrotated layers keep the same arithmetic bit for bit.
  - Re-registering a node (`RegisterNodeVisibility`, `RegisterNodeTranslate`,
    `RegisterNodeScale` and `RegisterNodeRotation` all call `RegisterNode` again)
    must not re-seed an existing anchor from `node->Translate()`, which already
    contains the offset; `SetNodeAlignment` keeps the existing anchor mode. The
    double offset shows only on layers whose scale or origin is dynamic, which is
    why a static-origin/scripted-scale case is in the test.
- **Host queries on `engine`** — `ScriptRuntimeCompat.UpstreamConsoleInputAndEngineCompatibilityStubsAreCallable`.
  The `IEngine` queries Wallpaper Engine documents are functions a script can
  call: `isRunningInEditor()` and `isScreensaver()` return `false`,
  `isDesktopDevice()` `true`, `isMobileDevice()` `false`, and `isWallpaper()`
  returns `!engine.isScreensaver()` (the test swaps `isScreensaver` to check that
  it follows). A missing one throws "not a function" and aborts the script's
  `init` or `update`. All but `isRunningInEditor` (a native function) are defined
  in `AppendCommonHostBootstrap`, which runs once per shared script context,
  never per frame.
- **Layer parents and scripted alpha** — `ScriptRuntimeCompat.LayerGetParent*`
  and `.LayerAlpha*`. `getParent()` is how an icon script reads its group;
  without it the whole `update` throws every frame. `layer.alpha` must reach
  `g_UserAlpha`, and only for layers whose authored alpha is not already owned by
  a timeline, an update script or a user property (two writers per frame fight).
  The layer's own pass applies the layer's alpha, once (twice on a puppet with bones
  under effects). A write has to reach it, and the `g_Color4` of each effect pass, not
  only the one registered last, and an effect with an alpha of its own (Wallpaper
  Engine's Opacity, the `g_UserAlpha` of its shader) keeps it, as it does under an
  authored alpha: a layer under such an effect drew a written, bound or keyed alpha
  once more for each of them, a half as a quarter:
  `ScriptRuntimeCompat.LayerAlphaWritesReachEveryMaterialOfTheLayer` (all of them,
  except an effect's own `g_UserAlpha`; the read-back of a write; a second registration
  replacing the first), `LayerAlphaReachesEveryMaterial.AHostOrScriptWriteReachesTheLayerAndEveryEffectPass`
  (`scene_schema_part09_test`; a layer's own material and each pass of its chain after parsing, a script-switched
  effect's pass included, an alpha a script owns left alone),
  `EffectOwnAlpha.TheLayersAlphaNeverOverwritesAnEffectPassOpacity` (an Opacity pass keeps its
  `alpha` whether a script writes the layer's, a property is bound to it or its own
  script owns it, with one such effect and with two),
  `.AnEffectThatSetsNoAlphaStartsFromTheLayersAuthoredAlphaAndKeepsIt` (an Opacity pass
  that sets none starts from the layer's authored alpha and a write leaves that alone),
  `LayerAlpha.AWrittenAlphaLeavesTheMaterialsAsTheSameAlphaAuthored` (`scene_schema_part03_test`; the skinned pass appended to a
  puppet's chain draws the layer, so it takes the layer's alpha and its effect does not;
  the layer's own pass, the sheet the chain starts from, takes it too, and a write puts
  every material where an authored alpha puts it: a puppet with bones under effects
  applies its alpha twice, [a known limitation](renderer.md#known-limitations)),
  `MetalSceneDraw.AScriptsLayerAlphaReachesTheLayerWhateverItsEffectsDo`
  (a script fading a layer to nothing and to half at 0.5 s leaves it opaque before,
  and clear or half transparent after, with no effects, a copying effect, an effect
  with an alpha of its own at 1 and at 0.8, two of them, every effect switched off, and
  a colour blend mode; a fade that left the layer's own pass at
  its authored alpha kept a faded widget on screen, and one that wrote the Opacity pass
  too drew a quarter where it should draw a half),
  `.AnAuthoredBoundOrScriptedAlphaIsAppliedOnceUnderEffects` (the same
  shapes at an alpha of a half, authored, bound to a property and owned by a script:
  a half once, where an effect's own alpha or the fallback passthrough of a chain whose
  effects a script switched off drew a quarter),
  `.ALayerColourIsAppliedOnceWhenEveryEffectIsSwitchedOff` (the same for
  the layer's colour) and `.AComposeLayersAlphaFollowsWhatDrivesIt` that
  a compose layer's alpha, which lands in its passthrough because its own pass reads no
  `g_Color4`, follows a property and a script as the authored one does.
- **Property and name bindings** — `ScriptRuntimeCompat.AuthoredColorPropertiesStayVectorsAcrossTicksAndPropertyChanges`:
  `createScriptProperties().addColor(...)` exposes a `Vec3` even when the saved
  `scriptproperties` stores RGB as a space-separated string, and again after
  native property updates replace the value; `addText` values stay strings.
  `DuplicateLayerNames.TwoPlainLayersWithOneNameGetIdBasedRuntimeNames`,
  `LayerNameLookup.BindingsStayWithTheirLayerWhileANameResolvesToTheFirstDeclaration` and
  `MalformedObjectEntries.AreIgnoredWithoutDisturbingNameResolution`
  in `scene_schema_part04_test`: duplicate
  non-text layer names keep separate internal binding keys; SceneScript name
  lookup selects the first declaration in authored order (including lookups made
  while a script module initializes) while each layer's `thisLayer` addresses its
  own key; the alias pass skips non-object entries, non-string names and
  nonnumeric IDs. A text label that repeats another layer's name keeps its own
  runtime key (`__we_text_<id>`, asserted in `text_object_runtime_test`), so
  `getLayer("s")` addresses the layer that owns the name.
- **Video-controlled visibility and music scripts** — `scenescript_media_event_smoke`:
  `getVideoTexture().isPlaying()` reflects shared runtime pause/play state, so
  scripts that hide a layer during init can reveal it during update; `Vec*.mix`
  and `MediaPlaybackEvent` constants are available.
- **A scene with no player is told nothing plays** — `scenescript_media_event_smoke`:
  `SceneScriptMediaEventSmoke.ASceneNoPlayerFeedsIsToldNothingIsPlayingOnItsFirstTick`
  (integration off and no event: the first tick delivers an empty
  `mediaPropertiesChanged` and `PLAYBACK_STOPPED` once, and a real event is still
  dropped), `.ARealStateTheSceneHeardBeforeItsFirstTickIsNotRepeatedAsIdle`,
  `.TheIdleStateFillsInOnlyWhatNoRealEventSaid` (per event type) and
  `.ARealEventAfterTheIdleStateIsDeliveredLikeAnyOther`; in `metal_scene_draw_smoke`
  `MetalSceneDraw.AMediaWidgetIsHiddenWhileNothingPlays`
  (a group hiding itself on `PLAYBACK_STOPPED` takes its parented card with it, after
  an `init` that shows it), `.AMediaWidgetShowsWhileSomethingPlays` and
  `.ANoMusicPlaceholderShowsWhileNothingPlays` (a hidden group that
  shows itself on `PLAYBACK_STOPPED` is brought into the graph). Without the idle
  state the media widget's cover and mascot stayed on screen for every user with media
  integration off.
- **Who hears a button's release** — `SceneSchema.APressedTransportButtonComesBackWhenItIsReleased`
  and `CursorHitTest.ALayerThatShrinksWhileHeldStillHearsItsOwnRelease`;
  `SoundLayerScripts.ALayerThatTookAPressHearsItsReleaseAfterThePointerLeftTheWindow`
  and `.ALayerThatDidNotTakeThePressHearsNothingOfItsRelease` in
  `sound_layer_cursor_behavior_test`. A release goes to whatever took the press,
  wherever the cursor has gone, the window included; re-testing the layer on the
  way up leaves a button that shrinks while held, or a press dragged off the
  desktop, latched for good. A layer that did not take the press hears a release
  only under the cursor, and a scene-wide script hears one from anywhere.
- **Creating layers from scripts** — SceneScript creation tests cover independent
  cloned layers, owner-local cached factories, bounded authored pools and lazy
  template loading. A script imported from the Workshop declares
  `export let __workshopId = '<id>'` and names its assets as in its own project
  (`models/bar.json`) while the editor stored them under `models/workshop/<id>/`;
  `thisScene.createLayer` passes the id on, and the runtime tries the workshop
  folder only after the path as written, the owner's own workshop folder and the
  lazy loader have found nothing. `ScriptRuntimeCompat.CreateLayerFindsTheAssetsOfTheWorkshopItemItsScriptDeclares`,
  `.CreateLayerPrefersThePathAsWrittenOverTheDeclaredWorkshopItem` and
  `.CreateLayerLooksInAWorkshopFolderOnlyForANumericDeclaredItem` cover the
  lookup. Template source layers are usually hidden and never parsed, so the lazy
  loader builds the template from the bare model: visible (copies start as copies
  of it) and as large as the model's picture when the model states no size
  (`ScriptMadeLayers.ACreatedLayerFindsAWorkshopModelByTheScriptsDeclaredItemAndTakesThePicturesSize`
  in `scene_schema_part07_test`); a
  zero-sized hidden template makes every lazily created layer invisible. A
  scene layer using the model registers as its template, but one with an effect
  chain (its own camera) or child layers cannot be copied, which is common for
  the script's own layer: the lazy loader then builds the model's own layer once
  and it replaces that registration
  (`ScriptRuntimeCompat.CreateLayerBuildsTheModelsOwnLayerWhenTheLayerUsingItCannotBeCopied`;
  a model that loads into such a shape fails once and is not reloaded,
  `.CreateLayerDoesNotReloadAModelThatLoadsIntoALayerItCannotCopy`). A model
  that is a passthrough or compose layer parses only as far as its early return,
  which leaves the template node owned by the lazy parse alone, so the loader
  takes that registration back when it reports the model unusable; otherwise the
  runtime kept ticking and showing a freed node
  (`Models/RefusedModel.AModelThatCannotBeCopiedLeavesNothingBehind/passthrough` in
  `scene_schema_part08_test`;
  AddressSanitizer reported it as a heap-use-after-free in `SceneRuntimeContext::Tick`,
  and on a real device it crashed the process in the Metal completion queue about
  once in three runs of one local scene).
  Refusing it threw `Unable to create layer` from `init` and logged
  `createLayer unsupported template shape`.
  `thisScene.destroyLayer` (a layer or its name) removes a layer a script
  created: it leaves the scene graph and the runtime's registries at once, so the
  layer object the script still holds reaches nothing and a second call answers
  false, while the node is freed only once the graph has been rebuilt without it
  (`ScriptRuntimeCompat.DestroyLayerRemovesALayerTheScriptCreated`,
  `.ADestroyedLayerIsFreedOnlyOnceTheGraphNoLongerDrawsIt`). A layer from the
  scene file stays and the call answers false. Without
  it, a script that rebuilds its layers when a setting changes threw
  `not a function` before building the new set.
- **Timeline events** — `ScriptRuntimeCompat.*Timeline*Event*`, `*Marker*`,
  `GlobalAnimationListenersRunOncePerMarkerWhateverIsBound`,
  `GlobalOnlyAnimationListenerSeesTheCurrentTickTime` and
  `SceneGetAnimationFindsATimelineOnAnotherLayer`: crossing, `event.frame`,
  reverse travel and exact loop wraps, delivery after `init`, one global listener
  run per marker with zero and two bound scene scripts, a fresh host context for a
  global-only listener, and scene-wide `getAnimation`.
  - `ScalarAnimationPlayback::Advance` queues every `options.events` marker the
    playhead crosses as a whole `ScalarAnimationEvent` (`frame` beside `name`);
    departure is exclusive and arrival inclusive, in both directions. A loop runs
    on a circle, so a wrap, an exact landing on the seam and a marker authored at
    the period are the same point, reverse travel is symmetric, travelling a whole
    period or more reports each marker once, and markers arrive in the order the
    playhead met them. `SetFrame` is a jump and reports nothing.
  - `SceneRuntimeContext::Tick` drains the queue after advancing the clocks *and*
    re-evaluating scripted values (a property script initializes lazily, so a
    marker crossed by the first tick must still reach an initialized handler) and
    calls `animationEvent` on the property and scene scripts bound to the
    timeline's layer. The global `engine.on`/`scene.on` list runs once per marker,
    not once per matching program, and refreshes `engine.runtime`/`engine.frametime`
    itself. Every crossed marker is collected before any handler runs, because
    handlers create, hide or destroy layers.
  - `thisScene.getAnimation(name)` exists beside the layer's `getAnimation`: a null
    layer argument to `__animationControl` matches the name across every
    registered timeline (`SceneRuntimeContext::FindAnimationByName`).
- **Puppet animation layer control** — `ScriptRuntimeCompat.PuppetAnimationLayer*`:
  `getAnimationLayer(name).play()` restarts a finished single-shot layer on every
  copy of the shared state; a `visible` bound to a user property toggles the
  layer. Puppet animation layers are one shared playback state per image object
  (`WPPuppetLayer` copies share it), registered under the layer name and backed by
  `SceneRuntimeContext::PuppetAnimationControl`. Authored layers start playing; a
  single-shot layer holds its last frame and reports stopped.
  `animationlayers[].visible/rate/blend` bound to user properties follow the
  property like any other setting.
- **Vector material constant timelines** — `VectorConstantTimeline*.*` and
  `SharedTimelineWrap.AChildWrapsOnlyOnTheParentsClock` in `scene_schema_part10_test`,
  `ScriptRuntimeCompat.VectorMaterialTimelineDrivesEveryComponentSeparately` and
  `.ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding`, and the
  `generated-perspective-animation` case in `check_renderer.py`. Each component of
  a material constant resolves its own curve (`c0`–`c3`) and its own entry of the
  initial value; unanimated components keep that value. The constants of one
  material pass are collected first, `options.parent.key` is walked to its root
  with memoized results, and the whole group shares the root's single
  `ScalarAnimationPlayback`, so `thisLayer.getAnimation(name)` drives it and
  looping and restarting happen once, on the root. Sampled component copies are
  single-shot, so a short child curve holds its last key instead of wrapping on
  its own length. A missing parent, a parent without a usable animation, or a
  cycle logs once and freezes that group on frame 0; relations never cross
  material passes. Without the curves a perspective quad's homogeneous `w` terms
  go negative and the quad inverts into a spike; the generated case asserts the
  page covers the centre and the margin stays clear (a blank or all-white frame
  fails too).
- **Scripted vector material constants** — `ScriptedVectorConstants.EveryComponentReachesTheScriptAndComesBack` (`scene_schema_part11_test`):
  a script that swaps a `vec2`'s components only produces the authored numbers
  when it is handed a vector, not the text `[x,y]`. Constants resolve at the
  authored component count: one component as a float, two and four through
  `ResolveVectorSetting`, three through `ResolveVec3Setting`; a constant with no
  authored value has no count to preserve and still resolves as a string.
- **Compiled exports and caches** — compiled script exports suppress only absent
  handlers; initialization, scheduled callbacks, shared scene callbacks,
  live-value fallback and live alpha/geometry hit order stay covered by
  `script_runtime_compat_test` and `mouse_input_test`. Transform/material caches
  avoid recomputing sources but still repair changed destinations in the
  original phases; a failed registration releases only its new
  subscriptions/values and restores existing mask/puppet identity.
- **Authored defaults versus loaded values** — `project_property_preview_test`
  (CPU only, in the `check_renderer.py` gate). A scene loads with the project's
  defaults under the user's saved choices, and `SceneParseRequest::authored_project_properties`
  (set by `MainHandler::loadScene`; null means the loaded table is also the
  authored one) keeps the defaults apart, as `SceneRuntimeBootstrap` does for the
  runtime. `ApplyProjectPropertyOverride(document)` takes a whole document: the
  declared defaults with exactly these values over them, so a property the
  document leaves out is at its default again whatever the scene loaded with, and
  `ResetProjectPropertyOverride()` is the empty document. Both return the sorted
  names whose value in effect changed (a change of kind counts). The test pins
  the table arithmetic and, through the real `WPSceneParser`, every way a
  property reaches a scene: a flag and a choice with a user condition (layer
  visibility), a slider (`g_UserAlpha`) and a colour (`g_Color4`) on an image
  layer, a bound text, and a bound material constant. For each, loading with a
  saved choice, applying a document and returning leaves visibility, every
  material constant and the text bit for bit equal to a fresh parse of the
  authored table, and applying a document equals loading with it. The fixture
  makes the authored and the saved value differ on every layer, so a return that
  stops at the loaded values fails. A document adds no time-advancing work
  (`DescribeTimeAdvancingWork` stays 0 for a still scene), so the on-demand idle
  analysis is unchanged. A name the scene loaded with but the project does not
  declare keeps its last value until the next load; callers send only declared ids.
- **Load-only properties** — `project_property_preview_test`
  (`LoadOnlyProperties.*`, CPU only). Almost every property is a live binding, so
  a document reaches the scene on its next tick. Two readers decide once, while
  the scene loads, and a built effect or a filled material slot is not redone:
  a `usertextures` slot that names a `scenetexture` property
  (`UserTexturePropertyName`, noted by `LoadMaterial`) and an effect whose
  `visible` is bound to a property, plain or with a combo `condition`
  (`UserPropertyName`, noted by `ResolveUserEffectVisibility`, image and text
  objects). Building every hidden effect would cost passes and memory, so these
  stay load-only. The parser calls `NoteLoadOnlyProperty(name)`, which records
  the value the name was read with (absent when the table did not name it);
  `LoadOnlyProperties()` lists the names. `PreviewProjectPropertyOverride(document)`
  is `ApplyProjectPropertyOverride` with every noted name forced back to that
  value for every consumer of it, live ones included (`glow` here also shows a
  layer, and the layer stays put), and lists the names the document asked
  something else for as `deferred`: a document that leaves out a name the scene
  loaded with a saved choice defers it too, and asking for the loaded value again
  defers nothing. A scripted effect `visible`, an effect with a plain value, a
  property nothing reads and a live slider note nothing. One test builds the
  scene again with the new values to show the effect set and the slot texture
  differ, which is why a running scene cannot take them.
- **A flag bound to a string property reads the string as a flag** —
  `project_property_preview_test` (`ChoiceProperty.*`, CPU only) and
  `script_runtime_compat_test`.
  `DynamicValue::update(const std::string&)` set the flag to false for every string
  unless a condition was attached, and a binding copies the property's flag, so a
  `visible` of the form `{"user": "mode", "value": true}` on a property that is a
  combo (a toggle the author later turned into a choice) never showed its layer,
  whatever the choice. The flag of a string is now `StringIsTrue` (`true` in any
  case, or `1`, the reading `RuntimeScalarValue::String` and `asBool` already had;
  it compares in place and allocates nothing, because a script that returns a
  string runs it on every tick), and a binding with a condition still compares the
  choice with it. The rule belongs to the flag, so it holds for every bool bound to
  a string property and for a string a script returns. The tests load three layers
  bound to one combo (no condition, condition `1`, condition `2`) and check which
  show for `1`, `true`, `TRUE`, `0`, `false`, an empty choice, `None` and `2`, both
  as the scene loads and as `ApplyProjectPropertyOverride` moves the choice while
  it runs; load an image layer's effects bound to the same combo and check which
  are built; connect a flag and a conditioned value to a string `DynamicValue`;
  pin the spellings (`true` in any case and `1` are on; `0`, `2`, `01`, `1 `,
  ` true`, `truee`, `tru`, an embedded NUL and a high byte are not); show that a
  combo `project.json` declares as a number stays a number, on for any whole
  number but 0 where the string `2` is off; and, in `script_runtime_compat_test`
  (`ScriptRuntimeCompat.AVisibleScriptThatReturnsAStringIsReadAsAFlag`), run
  visibility scripts that return `'1'`, `'true'`, `'TRUE'`, `'0'`, `'false'`,
  `'maybe'` and `''`. Wallpaper Engine draws a layer bound this way at the combo's
  default `1`; its answer for another choice is not established, so what the tests
  pin for any other string is this engine's own rule, and a numeric setting bound
  to a choice without a condition is unchanged (it reads 0). A puppet animation
  layer's flag and the other bool consumers share the one `DynamicValue` path and
  are not exercised one by one.
- **A script property bound to a choice with a condition is a flag** —
  `ChoiceAsFlag.ScriptPropertiesBoundWithConditionsReadTrueOrFalseAsTheChoiceMoves` in
  `scenescript_behavior_test`.
  A conditioned binding set the flag to whether the choice matched but kept the
  choice as the value's type and string, so `DynamicValueToJS` handed a script the
  string `"2"` for every flag over that combo, true in JavaScript whatever the
  condition; a clock offering MM/DD, DD/MM and YYYY/MM/DD as three flags over one
  combo always showed the first. `DynamicValue::update` from a string, directly or
  copied from the bound property, now makes a conditioned value a Boolean. The test
  binds two script properties to one combo (conditions `0` and `2`), has the script
  report which is truthy and its `typeof`, and moves the choice through `2`, `0` and
  `1` with `ApplyProjectPropertyOverride`. Consumers that read `getBool()` (layer and
  effect `visible`) see what they saw before.
- **Sound layer volume follows its slider** — `project_property_preview_test`
  (`SoundLayerVolume.*`, CPU only, a fake sound stream and a null-backend sound
  manager, so no audio device is opened). `WPSoundParser::Parse` read a
  slider-bound volume once, so a sound layer could not follow a property change.
  `WPSoundParser::BindVolumeProperty` resolves the bound property like any other
  slider setting (the authored volume while the project declares no such
  property) and sets `WPSoundStream::SetVolume`, an atomic store the audio thread
  already reads, so a sound layer is not load-only and costs nothing per frame.
  The volume follows a property, clamps above full, and returns to the project's
  own volume on the empty document, on a reset and after a saved choice, never to
  the saved choice or to the volume the layer carries in the scene. An undeclared,
  unnamed or non-numeric property leaves it alone. A document refreshes every
  property, so only a change of the bound property moves the volume: an unrelated
  edit does not undo a volume a script set with `SetSoundLayerVolume`. A released
  stream is not touched, and the real `Parse` binds a user-bound volume and leaves
  a plain number alone. Audible output on real hardware is not checked.
- **A property document on a running scene** — `project_property_preview_test`
  (`ScenePropertyPreview.*`, CPU only, no surface or window),
  `HiddenLayers.APropertyPreviewRevealsALayerWithOneGraphRebuildAndAGraphBuiltLaterLeavesTheHiddenOneOutAgain`
  in `layer_texture_reference_test` (CPU) and
  `MetalSceneDraw.APropertyPreviewChangesThePixelsAndAnEmptyDocumentRestoresThemByteForByte`
  in `metal_scene_draw_smoke` (private textures, skips without a Metal device).
  The wallpaper property `project_property_preview_json` carries a flat JSON
  object; `MainHandler` parses it, never touches the saved override JSON and stages
  it in `RenderHandler`'s latest-wins slot, and `CMD_APPLY_PROJECT_PROPERTIES`
  (posted only when the slot was empty, and dispatched in `onMessageReceived`, where
  a missing case silently drops a command) shows it on the render thread with
  `PreviewProjectPropertyOverride`. The tests send documents through
  `SceneWallpaper::setPropertyString` to scenes that have a runtime and nothing to
  draw: a document reaches the runtime, a load-only property stays put and a name
  left out is the project's own value; a burst of 500 documents queued while the
  render thread is held inside the first (a listener that waits) runs the runtime
  twice and handles two commands, the first and the last (the test-only
  `PropertyPreviewCommandsHandled` counts them, so a command per document fails); a
  document that is not a JSON object, or one that arrives before any scene exists,
  changes nothing and is not kept for the scene that arrives next; a second scene
  with the same property names shows its own loaded values and the first is not
  touched again; a preview adds no time-advancing work. On the graph, a preview that
  reveals a layer the graph left out makes one tick raise the mutation flag once, a
  held property reveals nothing, hiding the layer again and showing it again on the
  same graph raise nothing, a graph built while it is hidden leaves it out again and
  showing it then raises the flag once more. On Metal, a slider-bound alpha changes
  the picture with no new graph, a switch that shows a layer rebuilds the graph
  exactly once and draws the picture a fresh load with the same values draws, and
  the empty document brings the first frame back byte for byte, twice over, without
  another graph. On a live surface (`unchanged_present_test`, the Compatibility
  backend on a layer no window owns, timing-shaped and named in `REALTIME_TESTS`),
  `UnchangedPresent.APropertyPreviewShowsOnAStillSceneAndWakesAnIdleOneForOneFrame`
  sends a slider through the property: a still scene whose passes are all reused
  submits exactly one frame, presents a different picture and goes back to
  repeating, and with the on-demand clock the stopped scene draws exactly one frame
  and goes back to sleep. A paused scene showing the change on resume comes from the
  same per-command frame request and is not exercised; a preview on a real display,
  and the hitch of a revealed layer compiling new pipelines, are not checked.
- **SceneScript API parity with Wallpaper Engine 2.8.42** — the script API is
  checked against what Wallpaper Engine's shipped script classes and modules and
  the entry points and class members its binary registers do, not against what
  this engine happened to expose. In `script_runtime_compat_test` unless named
  otherwise:
  - *Small fixes.* `SceneScriptMediaEventSmoke.PlaybackStatesAreNumberedAsWallpaperEngineNumbersThem`
    (stopped 0, playing 1, paused 2; the literal and the constant must agree);
    `.AnimationLayerCountIsThePuppetsNotTheNumberAskedFor` and
    `.AnimationLayerCountIsZeroWithoutAPuppet`; `.WEMathConstantsAreNumbersAndMixInterpolates`
    (`deg2rad` and `rad2deg` are the factors, not functions);
    `.WEColorConvertsBetweenRgbAndHsvAndScales` (`rgb2hsv`, `normalizeColor`,
    `expandColor`) and `.WEColorHsv2RgbDoesNotClampSaturationOrWrapHue` (a
    saturation above 1 gives components outside 0..1, a hue of 1 or more goes
    round the sextants again, a negative hue is black, as in Wallpaper Engine);
    `.WEVectorReportsTheAngleOfADirection`;
    `.LocalStorageDeleteRemovesAKeyAndRemoveStaysAnAlias`;
    `.CursorScreenPositionIsInDisplayPixelsFromTheTop` (`input.cursorScreenPosition`
    is the window-normalized pointer times `engine.screenResolution`, y from the
    top; `input.cursorLeftDown` is the primary button). The typed Rust path
    sends the same numbers: `wallpaper-core` `media::integration` tests
    (`playback_state_serializes_as_the_numbers_scripts_compare_against`,
    `playback_event_carries_the_script_number_not_a_host_numbering`) and
    `wallpaper-bridge` `scene_media_playback_reaches_scripts_in_wallpaper_engines_numbers`
    (the host's own numbering, playing 0, paused 1, stopped 2, is mapped to the
    variants by name).
  - *Vectors and matrices.* `.VectorsCarryTheWallpaperEngineMethodSet`,
    `.VectorsBuildFromStringsAndPrintLikeWallpaperEngine`,
    `.VectorsTheHostHandsOutAreTheGlobalClasses`, `.Mat4ComposesTransformsAndInvertsThem`,
    `.Mat3HandlesTwoDimensionalTransforms`,
    `.MatrixDeterminantAndInverseMatchValuesWorkedOutExactly` (a 4x4 and a 3x3
    worked out in exact rational arithmetic, a swapped column, a singular matrix),
    `.EulerAnglesTurnAboutXThenYThenZAndComeBackOut` (the order, the round trip
    over the whole range and at +-90 degrees about y, a scale leaving the angles
    alone) and `.MatrixDecompositionRebuildsTheMatrixAndMirroringIsANegativeXScale`
    (also axis-angle, `lookAt` and `normalMatrix`).
    `Vec2`/`Vec3`/`Vec4`/`Mat3`/`Mat4` are classes with Wallpaper Engine's method
    set and semantics (`"x y z"` strings, `toString()` with spaces, a `Vec2` beside
    a `Vec3` standing for its own components); the vectors the host builds
    (`engine.canvasSize`, `thisLayer.origin`) are instances of them from the first
    frame, not bare objects until something moves. The matrix routines
    (determinant by expansion along columns, the inverse as adjugate over
    determinant, rotations as products of elementary turns) are written from the
    mathematics, not from Wallpaper Engine's file. The classes were also compared
    method by method against Wallpaper Engine's own with randomized inputs outside
    the repository (not a checked-in test, since that needs its files): no value
    or class differs except two leniencies kept on purpose, a `Vec4` beside a
    `Vec2` (the shipped one gives NaN for z and w, this one leaves them alone) and
    a vector built from a wider vector or a plain object (the shipped one stores
    the object in every component, this one takes the components). A singular
    matrix has an inverse of non-finite numbers in both, though the sign of the
    infinities can differ.
  - *Layers.* `.SceneEnumeratesItsLayersInOrderAsTheObjectsGetLayerReturns`,
    `.LayersAScriptCreatesJoinTheEnumerationAndLeaveItWhenDestroyed`,
    `.InitialLayerConfigIsTheSceneFilesObjectForTheLayer`,
    `.ASceneKeepsItsObjectListOnlyWhenAScriptReadsIt` and, with the real parser,
    `LayerRegistry.LayersAreListedInDeclarationOrderFoundByIdAndExposeTheirObject`
    and `.TheObjectListIsOnlyKeptWhenSomeScriptAsksForIt` (`scene_schema_part08_test`):
    `getLayerCount` (a number), `getLayer(index)` (`null` out of range),
    `enumerateLayers`, `getLayerByID` and `getLayer(name)` answer the same cached
    wrapper objects, and `getInitialLayerConfig` a fresh parsed copy of the layer's
    object each call; hidden templates are not layers. Only layers the parser
    instantiated are counted: an object the scene file marks statically invisible
    (and nothing can show) is never built, so it has no index and no id, and the
    count and later indices differ from the scene file's object list by those.
    `.LayersShowTheNameTheSceneFileGaveThemWhateverKeyTheyAreRegisteredUnder` and
    `LayerRegistry.ScriptsSeeTheAuthoredNameOfLayersRegisteredUnderGeneratedKeys`:
    `layer.name` is the authored name (empty for an unnamed layer) even where the
    layer is registered under a generated key because its name is shared or
    empty; every call still goes by the key. `.OneLayerOrderServesIndexCountEnumerationAndSorting`
    and `.SortingASiblingWithinItsGroupReordersOnlyThatGroup`: `getLayer(i)`,
    `getLayerCount`, `enumerateLayers`, `getLayerIndex` and `sortLayer` are one
    order; a sort moves the layer in it (clamped to the ends) and the draw order
    among the layer's siblings follows, once.
    `.DestroyLayerRemovesEveryLayerBelowItFromTheRuntime`,
    `.ScriptsCanKeepUsingWrappersOfLayersDestroyedWithTheirParent` and
    `.ANameFreedByDestroyLayerCanBeGivenAgainAndParentsAreChecked`: destroying a
    layer destroys the layers a script made below it (none stays registered,
    counted, named or findable; their nodes are freed together once the graph no
    longer draws them), a name can be given again, and a layer cannot hang below
    itself.
  - *Entry points.* `.ApplyGeneralSettingsFollowsInitAndTheInterfaceLanguage`,
    `.ASceneScriptIsToldTheLanguageAfterItsInit`, `.ResizeScreenReportsANewDisplaySizeToStartedScripts`,
    `.ResizeScreenReachesSceneScriptsAndEngineOnListeners`,
    `.DestroyRunsOnceForScriptsThatStartedWhenTheSceneIsTornDown`,
    `.DestroyDoesNotRunForAScriptThatNeverStarted` and
    `.AScriptedValueDestroyedBeforeTheRuntimeLeavesItsRegistry`: `destroy` pairs
    with `init`; a scripted value that is destroyed first leaves the runtime's
    list, so nothing ticks or ends it afterwards. `Teardown.ScriptsDestroyRunsWhileTheScenesFilesAndLayersStillExist`
    (`scene_schema_part08_test`):
    the scene ends its scripts first thing in its own destructor, while its file
    system and everything else still exist (the runtime is declared above them and
    would otherwise end them after they were gone). `LayerRegistry.ASceneScriptsInitAlreadySeesOrderIdsObjectsAndTheTextHooks`:
    a scene script's `init` runs after the layer order, ids, object list and
    text hooks are installed (scene scripts start last in the parse). The
    language scripts are told is always `en-us`: `SetLanguage` exists but nothing
    calls it yet.
  - *Animation layers.* `.ThisObjectIsTheAnimationLayerAScriptIsBoundTo`,
    `.ThisObjectIsTheLayerForAScriptOnTheLayerItself`,
    `.AnimationLayersAreOneObjectPerLayerAndKnowTheirOwnName`,
    `.AnimationLayerEndedCallbacksFireWhenASingleShotFinishes`,
    `.RemovedEndedCallbacksStaySilent` and
    `.ALoopingAnimationLayerNeverEndsAndItsListenerStaysSilent`: a script on
    `animationlayers[i]` has that animation layer as `thisObject`, which is the
    same object `getAnimationLayer` gives for its name or its position and has the
    layer's authored name; `addEndedCallback` listeners (one set per layer,
    however it was asked for) run once per finish of a single-shot layer, from
    the puppet state the renderer advances, and never for a looping one.
  - *A property script's own object.* `ScriptEffectObject.WritingVisibleFromInitSwitchesTheEffectAndLeavesTheLayer`
    and `ScriptKeyedSettingObject.GetAnimationWithoutANameIsTheSettingsOwnAnimation`
    (`scenescript_behavior_test`): a script
    deciding an effect's visibility has the effect as `thisObject`, so writing
    `thisObject.visible` from `init` or a media handler switches the effect and leaves
    the layer shown (it hid the layer and left the effect on); a script on a keyed
    shader constant gets the constant's own timeline from `getAnimation()` with no
    name on a layer whose origin also has an unnamed timeline (it got the origin's,
    and the constant stayed on its first key).
  - *Sprite sheets.* `.PausedSpriteSheetHoldsItsFrameAndPlayResumesIt`,
    `.StoppedSpriteSheetReturnsToItsFirstFrameAndSetFrameStillPins`,
    `.SpriteSheetRateScalesPlaybackAndTheSheetDescribesItself`,
    `.SpriteSheetRateReadsBackWhatWasWrittenAndOnlyAPositiveRateAdvancesIt` and
    `.ALayerWithoutASpriteSheetReportsNoFrames`: `getTextureAnimation()` has
    `play`/`pause`/`stop`/`isPlaying`/`rate`/`fps`/`frameCount`/`duration`/`name`;
    the shader value updater advances the sheet by the frame time the node lets it
    have, so a paused sheet holds its frame (driven through the real updater);
    `rate` reads back what was written, and a rate that is not a positive speed
    holds the sheet without changing what it reads.
  - *Text layers.* `.TextLayerStyleIsReadAndWrittenThroughTheLayer`,
    `.TextStyleOnAnotherKindOfLayerStaysAPlainProperty`,
    `.TextStyleRejectsValuesTheLayerCannotUse`, `.TextAlignmentOnlyTakesTheWordsItIsDefinedFor`,
    `.TextPointSizeSurvivesAReadModifyWriteWithoutLosingPrecision`,
    `.CreateLayerMakesATextLayerFromItsConfiguration`,
    `.CreateLayerWithoutAnythingToMakeStillThrowsAndWithoutAFactoryReportsIt` and, with the
    real parser (`scene_schema_part08_test`),
    `ScriptMadeText.ALayerMadeByAScriptIsBuiltLikeASceneTextObject`,
    `TextRestyle.PointSizeFontAndAlignmentWrittenByAScriptChangeTheStateAtOnceAndTheLayoutLater` and
    `Teardown.TheRastersOfMadeAndDestroyedTextLayersAreReleased`: `font`, `pointsize`,
    `horizontalalign` and `verticalalign` read and write the text layer, a write
    lays it out again and moves the card about the layer's origin (setting one axis
    keeps the other's authored edge); the alignments take only `left`/`center`/`right` and
    `top`/`center`/`bottom` (anything else stays a plain property); the size reads
    back as the float it is; a font is resolved by the parser's own rule;
    `createLayer({ text, font, pointsize, color, alpha, ... })` parses a text
    object as the scene file's own are parsed and joins the scene beside the layer
    that made it, and when such a layer is destroyed its raster is dropped from
    the scene once the graph that drew it is gone.
  - *Image layers made by script.* `.CreateLayerHonoursSizeNameParentAndParallaxDepth`,
    `.ASizedLayerHasItsOwnStretchedCardAndTheTemplateKeepsItsOwn`,
    `.ParallaxDepthIsReadAndWrittenThroughTheShaderUpdater`,
    `.ParallaxDepthIsTheDepthOfWhatIsDrawnAndAWriteReachesTheLayersBelow`,
    `.ACreatedLayersParallaxDepthDecidesWhetherTheCursorMovesIt`,
    `.CreateLayerWithAParentThatNamesNoLayerStaysBesideItsCreator` and
    `.ALayerCreatedBelowAParentMovesWithItAndStaysOutOfTheRoot`: `size` stretches
    the copy's own card (the template's geometry is shared with its copies, so the
    copy gets one of its own) without touching texture coordinates, `name` makes the
    layer reachable by it (and `destroyLayer` still takes the object), `parent`
    moves it below that layer and its world place follows the parent (a parent
    that names no layer leaves it beside its creator, not at the root), and
    `parallaxDepth` is a property of every layer. A write reaches the layer, the
    effect passes it is drawn through (a layer drawn through them holds the depth
    on those alone) and the layers below it (Wallpaper Engine
    moves a whole tree by its outermost layer's depth, so a write on a child
    changes only that child's drift; layers above and beside keep theirs), and a
    layer that starts or stops following the cursor asks for a new render graph.
  - *Layer transforms.* `.LayerTransformMatrixPlacesAChildWhereItsParentsPutIt`,
    `.LayerTransformMatrixCarriesTheTurnAndScaleOfItsParents`,
    `.LayerTransformMatrixFollowsALayerWhereverItMoves` and
    `.LayerTransformMatrixOfALayerWithoutANodeIsTheIdentity` (nodes made by hand), and
    `ScriptPlacement.ALayersTransformMatrixIsItsWorldMatrixNotTheOneItRendersFrom`,
    `.EveryLevelOfNestingContributesItsScale` and
    `.AnEdgeAnchoredLayersMatrixIsItsQuadCentreAndItsOriginTheAnchor`
    (`scene_schema_part03_test`, layers the parser built): `getTransformMatrix()`
    is the layer's world transform as a `Mat4` in canvas units, y up (x and y in
    `m[12]` and `m[13]`, the frame the scripts compare against `engine.canvasSize`).
    A child's matrix has its parents' scale and turn in it (a group at (100, 200)
    scaled by two puts a child at (10, 20) at (120, 240); turned a quarter, at
    (60, 220) with its axes turned and doubled), a layer that ignores its parent's
    transform answers its own placement, a layer drawn through an effect (which
    renders from an identity of its own) still answers where it stands, in a parsed
    scene too (the node registered under its name is the one that carries that
    identity), and a read right after a write to the layer or to a parent sees the
    write. A layer anchored to an edge (`alignment`) answers the centre of its quad,
    half its drawn width right of a left anchor, while `layer.origin` still reads the
    anchor, and the matrix follows a script that moves the anchor. A name with no
    node answers the identity, and a script that reassigns the global `Mat4` does
    not change what the host builds. Each call answers a matrix of its own.
  - Not covered here: `localStorage` persistence, effects, bones, particles,
    scene properties, the camera, `Intl`, and the other layer transform calls
    (`getChildren`, `setParent`, `lookAt`, `lookAtYaw`,
    `getAttachment*`: a script that calls one still stops at `not a function`);
    host plumbing for `SetLanguage` (scripts are told `en-us` until the host calls
    it).
- **Scene commits in headless tests** — `scene_schema_tests` helpers wait for
  posted work with a render-looper round trip (`beginSurfaceReconfigure`) and a
  main-looper one (installing a pointer callback replays from the main looper)
  before `shutdown()`, which stops the loopers without draining them. A test that
  posts a scene and shuts down at once measures a race. A graph that never
  reached a backend is simply dropped by the next scene.

## Layers, textures and compositing

The `rendergraph_smoke` target keeps its 34 `RenderGraph` identities: five retained
project cases in `rendergraph_smoke.cpp` and 29 independently authored cases in
`graph_contract_cases.cpp`, with concrete support in `graph_contract_support.hpp`.
The retained blend/effect/skeleton logic and always-active `TestRequire` remain.
These parser/graph fixtures use in-memory assets and real Null audio; their empty
texture entrances are not decoded-image or native-rendering evidence.

- **Composites, covers, perspective images, unbound slots, fog** — pixel tests
  through the synthetic scene harness, each in a file of its own:
  `LayerComposite.*` in `layer_composite_render_test` (a chain's translucent result
  and a four-channel data buffer keep their values in the composite; a layer 0 units
  high or wide fills a composite of the canvas size on that axis, shown or scaled to
  zero, and draws nothing on the scene; one unit thin keeps its size);
  `CoverSlot.*` in `cover_slot_composite_test` (a cover slot over a hidden layer's
  composite, idle, with a cover a few frames later, cleared, with one and two tracks
  for the previous cover, the cover's clamped sampler, and the unchanged picture-art
  slot); `PerspectiveImage.*` in `perspective_image_layer_test` (a flagged card's width
  from the camera formula, bare and through an effect, with other fields of view; a
  fullscreen layer and a card at the canvas plane unchanged); `ModelParallax.*` in
  `model_parallax_test` (a model, grouped or not, 2D, flagged `perspective` or in a 3D
  scene, moves with the pointer; its pass reports that it follows the cursor);
  `UnboundSlot.*` in `unbound_texture_slot_test` (a slot nobody bound reads zero,
  listed as null or left out; an authored texture, a shader default and a
  presence switch are unchanged; a missing named asset and an unresolved layer
  reference keep their failures); `LightingFog.*` in `scene_lighting_fog_test`
  (height fog from a package of version 22 and 23 is the same picture; ambient,
  skylight and height fog bound to properties equal their literals and cost no pass;
  a live edit is held until a load; bound distance fog keeps its authored value).
- **Effect buffers and swaps** — `EffectBuffers.SizeAndFormatFollowTheBufferTheLayerAndTheScene` and
  `.SwapCommandsLowerToCopiesAndOnlyGoThroughATemporaryWhenTheSecondBufferIsReadFirst`
  (`scene_schema_part04_test`) pin `fit`/`width`/`height` sizing, the float and 8-bit formats and how a `swap`
  lowers to one copy or a three-copy exchange;
  `MetalSceneDraw.AnEffectsSwappedBuffersAccumulateAndItsFloatBuffersKeepTheirSign`
  draws an accumulating, signed effect. Wallpaper Engine's
  fluid simulation (`effects/fluidsimulation`) needs both: without the swap its
  history buffers were never written, and a local scene that runs it drew wrongly.
- **3D model materials and skinning** — `ModelLayerParse.ModelMaterialsDefaultToOpaqueAndDepthTestedAndExplicitStateWins`
  and `.BonesReachEveryMaterialAndTheBindPoseIsTheIdentity` in `scene_schema_part01_test`.
  Model materials default to normal blending, back-face culling and enabled
  depth test/write; explicit pass settings win, and image defaults are
  unchanged. Skeletal models share one `WPPuppetLayer` playback across material
  slots, attachments and runtime animation controls, including bind-pose uploads
  when no clip matches, with no extra render passes or texture allocations.
  `MdlSkeleton.VersionThreeSkeletonKeepsHierarchyAndPivotsForMeshVersions`
  and `.VersionTwentyThreeFileWithVersionThreeSkeletonKeepsTheChain` in
  `mdl_parse_tests`: mesh format versions do not justify flattening an
  authored skeleton. Versioned model fixtures cover MDLV13–23 attribute layouts
  (`MdlMesh.SurfaceAttributesSurviveEveryFileVersion` and
  `.SkinnedMeshesKeepBoneStreamsAndSkeletonForEveryVersion`).
- **Pass depth and cull words** — `ModelLayerParse.PassStateWordsOutsideTheListsReadAsTheFirstEntry` (`scene_schema_part01_test`):
  `depthtest` and `depthwrite` are on only for `enabled` and `cullmode` is off only for
  `nocull`; any other word (`less`, `greater`, `always`, `inverted`) reads as the list's
  first entry: no depth test, no depth write, back faces culled. A write without a
  test is not drawn (`ResolveSceneDepthState`). The native capability check no longer
  refuses a material for its depth word, so such scenes stay on Native Metal;
  `MetalCapability.AnUnsupportedDepthCompareIsRefusedWithItsOwnReason` went with the
  rule it pinned.
- **Perspective model contracts** — the parser selects the index width from the
  vertex count (32-bit indices above 65535 vertices; reading that blob as uint16
  triples rejects the mesh or draws scrambled triangles), and the vertex cap is
  4 million. `g_NormalModelMatrix` is a std140 `mat3` (48 bytes) and uniform
  writes are clamped to the reflected member size, so an oversized write cannot
  spill into `g_ViewProjectionMatrix`. Culled model passes keep the
  counter-clockwise front face (`kSceneFrontFaceCounterClockwise`; clockwise culls skyboxes). A perspective far plane is
  padded by a tenth of a percent so a skybox scaled to exactly `far` is not
  clipped off-centre. An image layer's `alpha` `update` script or user property
  is applied to `g_Alpha`, not only an animation timeline. Perspective particle
  billboards scale with their layer, in an authored 2D canvas as in 3D, since
  Wallpaper Engine draws them through the layer's model matrix, unless the particle
  file is `worldspace`, which it draws through none; quantity remains the documented
  emission-rate factor, not a replacement for the authored maximum count.
- **A model's tangent reaches the shader that declares it** — Wallpaper Engine's
  model shaders (`generic`, `generic2`, `generic3`, `generic4`, `genericimage3`,
  `genericimage4`, `chroma4`, `foliage4`, `fur4`) read the signed tangent of a
  normal-mapped model from `attribute vec4 a_Tangent4` (the two `genericimage`
  shaders for a skinned puppet layer), and the renderer hands a vertex input the
  mesh attribute of the same name. The model parser named it `a_Tangent`, so the
  input found no attribute and read the first vertex buffer from offset 0: the
  position and, in a model without bones, the normal's x. The tangent frame of a
  lit, normal-mapped model was then built from that, the perturbed normal came out
  far longer than one, and the highlight swept through the specular pole:
  hard-edged patches, contour lines and white sparkles on a lit roof where
  Wallpaper Engine draws a smooth pool. The
  attribute is now named `a_Tangent4` (`WE_IN_TANGENT`); nothing else changes, so
  there is no extra pass, buffer or per-frame work, and a model without a normal map
  never read it. Tests: `MdlMesh.SurfaceAttributesSurviveEveryFileVersion` in
  `mdl_parse_tests` (the names the generated mesh carries, for every file version)
  and `MdlSchema.GenMeshIncludesNormals` in `mdl_schema_tests`, and
  `MetalSceneDraw.AModelsTangentReachesTheShaderThatDeclaresIt` (a
  quad built by the model parser from a tangent that is no axis, with handedness
  -1, drawn through a probe vertex shader that builds the tangent and bitangent as
  `generic4` does (`BuildTangentSpace`, without the model transform; Wallpaper
  Engine's own shaders are not in the repository); the fragment shader shows the
  tangent, the bitangent and a perturbed normal, each a flat colour equal to the
  mesh's own values, where before the change every pixel was the
  position-derived read).
- **Layer textures tiled across models** — `LayerTextureReference.CompositeAddressingFollowsTheSourceLayersClampUvs`
  in `layer_texture_reference_test`. `_rt_imageLayerComposite_<id>` repeats when
  the source layer says `"clampuvs": false` and clamps when it is true or absent;
  otherwise a model whose UVs run far outside 0..1 smears the composite's edge
  texels into solid bands.
- **A composite holds the chain's result as written** —
  `LayerComposite.ALayerWithNoHeightFillsItsCompositeAndShowsNothing` and
  `.ATranslucentResultKeepsItsColourAndAlphaInTheComposite` in `layer_composite_render_test`: a translucent solid layer 64 wide and 0 high, hidden at
  zero scale or shown, whose effect writes a colour of alpha 0.25 through the
  model-view-projection matrix; a second layer shows that composite's colour and
  alpha, and the buffer itself draws nothing on screen. Before the change the card
  that carries the chain into the composite was 0 high, so the composite stayed
  empty (an audio widget's bars, which read their spectrum from such a buffer,
  never moved), and once filled, the chain's last pass blended into it with the
  layer's translucency, multiplying the colour by an alpha the buffer uses for data.
- **Layer targets: point sampling and wrap** — `LayerTextureReference.LayerTargetsFollowNointerpolationClampuvsAndTheTextureHeader`
  and `.ACompositeFollowsItsLayersTextureHeaderWhateverIsParsedFirst` in
  `layer_texture_reference_test` and
  `MetalSceneDraw.AnImageLayersTargetsArePointSampledWhenItAsks`.
  The ping-pong pair an image layer's effects run through, and the composite
  another layer reads, are point-sampled when the layer sets `nointerpolation` or
  its primary texture's header does, wrapped when `clampuvs` is off, clamped and
  linear otherwise; per-effect buffers stay clamped and linear. The header is read
  from the texture file (`LayerRenderTargetFilter`), because the composite of a layer
  another layer reads is registered before the layer's own material is loaded: the
  second test makes the point-sampled texture's only user the layer in question, in
  three layer orders, with and without an effect chain (whose ping-pong pair has to
  agree with the composite), and a texture with no flag or one that cannot be read
  stays linear. The Metal test shows a 16 by 12 target 16 times larger on both
  renderers: a smooth gradient by default and flat squares with `nointerpolation`.
- **Mip level of point-sampled file textures** — `MetalSceneDraw.ATexturePointSampledByItsHeaderPicksItsMipLevelByPoint`.
  The reference builds the sampler of a file texture from a flags word that is the
  texture's own (its two low bits are the `.tex` header's `noInterpolation` and
  `clampUVs`): with `noInterpolation` the min, mag and mip filters are all point. `TextureSample::mipFilter` carries that, set by the `.tex`
  parser from the flag and read by the Metal sampler; every other sample, render targets and the
  default-constructed `TextureSample {}` fallbacks among them, keeps the linear mip
  filter. The test draws a seven-level chain, white then black, at 1.68 texels to the
  pixel: a header with the flag gives the black second level, one
  without it the blend of the two. A render target has a single level, so its filter
  has no mip to choose. No local scene shows the difference: its point-sampled
  textures have one mip level or are magnified.
- **Shape objects** — `LayerTextureReference.AShapeDrawsItsLastEffectAdditivelyOntoTheScene`
  (CPU, in the gate) and `MetalSceneDraw.AShapeIsAddedOntoTheScene`. A
  `shape` is the group node `ParseLayerNodes` makes for it with a mesh and a material
  added by `ParseShapeObj`: the quad of `point0` to `point3` (corner `(p.x, 1 - p.y)`
  of a canvas-high square about the layer, texture coordinate `p`) or the whole
  square, the last visible effect's material with `DIRECTDRAW` forced on, drawn
  additively onto the scene. The effect shader of both tests only compiles when
  `DIRECTDRAW` is on, so the test fails if the parser stops forcing it. The Metal
  test draws half-transparent red over green and requires
  identical pictures, red-added inside the quad and untouched outside it. The
  shipped light-shaft effect, parsed with the editor's own assets, compiles through
  the shape path in both its linear and its radial modes; drawn once offscreen on
  Native Metal it was a beam narrowing upward and fading downward, as the editor
  shows it (checked by hand, not kept as a test, as it needs the editor's assets).
- **Model flags of the layer utilities** — `LayerTextureReference.TheDepthTestedComposeModelComposesLikeTheOthers`
  and `.AProjectLayerTakesTheCanvasSizeAndKeepsItsOrigin`. A layer composes when its
  model is the composition layer or its depth-testing variant; a model with both
  `autosize` and `projectlayer` is as large as the scene's canvas, whatever size
  the scene saved. `solidlayer` is read and unused, and `autosize` alone still takes
  the saved size.
- **A layer's saved size over its model's** —
  `LayerSize.*` in `scene_layer_size_test` (parse only, no device). A model can state a
  `width` and `height` (the editor writes a frame's size for a sprite sheet); the layer is
  still as large as the `size` the scene saved, and the model's size is only for a layer that
  saved none (400x300 saved over 64x64 stated draws 400x300; none saved draws 64x64; neither
  stated leaves twice the origin, as before), for a still picture and for an animated
  sheet of frames alike, and the picture is sampled over the whole card. A CRT wallpaper
  whose screen is a sprite sheet resized in the editor drew its screen at the frame's size,
  a dark rectangle inset in the monitor with a wide border of background round it. Not
  compared with a Wallpaper Engine frame (no Windows VM).
- **Depth state of a layer drawn through effects** —
  `MetalSceneDraw.ALayerDrawnThroughEffectsKeepsItsOwnDepthTestAndWrite`.
  The last pass of an image layer's effects is drawn with the layer's authored
  `depthtest` and `depthwrite`, not the state its effect pass authored
  (`SceneImageEffectLayer::SetFinalDepth`, applied beside the layer's blending in
  `ResolveEffect`). The write is left out for a layer Wallpaper Engine sorts: one whose
  material blends, `translucent` or `additive`, in a scene with `transparentsorting` on
  a perspective camera (`Scene::opaque_first`); the parser hands such a layer no write.
  The fixture is an opaque card nearest the camera, a red translucent layer behind it,
  and a card behind that which depth-tests and writes none, drawn into a depth-attached
  scene with and without a pass-through effect that authors neither state, by both
  renderers. A layer that tests is hidden over the nearer card with effects exactly as
  without; one that writes hides the card behind it; one that authors neither draws over
  the nearer card even when its effect pass authors both. The red layer is also a solid
  layer (`solidlayer_depthtest`) and a composition layer (`composelayer_depthtest`,
  holding a red card) that test without writing. Eight more cases draw the same cards
  through a perspective camera with `transparentsorting` (the far card translucent,
  since an opaque one is drawn first there). A translucent or additive layer that tests
  and writes, whether a plain card, a solid layer or a composition layer, is hidden over
  the nearer card yet does not hide the far card drawn after it, whether or not the far
  card runs the same effect and authors the same state. That layer is transparent over
  the far card, as a glare card is, so the case asserts that its texels cut nothing out
  of the far card, not that the far card is drawn under the layer, which Wallpaper
  Engine's sort would add and this engine's scene order does not. A layer authoring
  neither is the reference that proves the geometry. A `normal` or `alphatocoverage`
  layer is not one Wallpaper Engine sorts: it keeps its write, and the far card is
  hidden behind it. Each case except the geometry references fails
  when the rule it guards is broken: with no final depth state the effect cases draw the layer over the nearer card
  and a layer authoring neither is hidden; with the write kept for a layer that blends
  the sorted cases of such a layer draw nothing over the far card (it is cut out); with
  the write dropped from every layer of a sorting scene the `normal` and
  `alphatocoverage` cases draw the far card over the layer.

  The depth test and write rest on Wallpaper Engine's binary (its image layer copies the
  material's `depthtest` and `depthwrite` flags onto the pass, and a scene that sorts
  draws the layers that blend after the others, back to front, so the write hides
  nothing there), and on frames of 3509243656 (a star's glare layers, authored
  translucent with both enabled, over opaque spheres). Without the test each star is a
  smooth warm disc; with the test and the write a card-shaped hole is cut out of
  everything farther drawn after the nearest star's glare card: the other stars' glows
  (a star without its halo), the nebula layers (a dark rectangle with hard edges around
  a star) and the hover HUD of a farther star, whose ring and leader line are absent
  while its text label, drawn without a depth state, is there. With the test and no
  write the discs are white with a warm glow outside them, the glows and the rings are
  back and no rectangle is left, as in Wallpaper Engine's frame. The seeded A/B behind
  that (the scene's script `Math.random` seeded, 12 s in, pointer at the centre: seeds 1
  to 3, 5 to 8, 10, 13 and 14) differs by 13 to 86 thousand of 7 million pixels per
  frame, and seed 14 is the pair in which a star's ring and leader line return. A ring
  in the glare card's own plane is drawn with the write (equal depth passes), so the
  failure is a farther layer under a nearer star's card, not a coplanar one. Across the
  100 local scenes 14 image layers with effects author a depth-tested material; of the
  two perspective scenes that sort (3509243656, 3589454154) only 3509243656 has effect
  layers that author a write, and they are all translucent, so no local frame shows a
  layer that keeps its write in a sorting scene: that half rests on the binary and the
  test. 3665954520 (2D, no depth attachment) draws byte for byte as before. 3589454154
  (Saturn) differs between no depth state, the test alone and the test with the write in
  no more than 13 pixels outside its clock text. 3477054430 (a moon layer that tests and
  writes, no sorting) draws the same pixels with and without the write; the test draws
  17 small clusters of star pixels (about 500 of 7 million pixels at 3456x2024) over the
  moon's disc that Wallpaper Engine's frame does not have: with the test those pixels
  are 38 to 44 levels off its frame on average, without it 2 to 3. The likely cause is
  the star shell model (additive, `depthwrite` enabled) being nearer than the moon; it
  is not settled here and not changed.
- **Layers a wallpaper's properties hide** — `HiddenLayers.ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt`
  in `layer_texture_reference_test` (CPU, in the gate) and
  `MetalSceneDraw.ALayerItsPropertiesHideHoldsNoImagesUntilAScriptShowsIt` in
  `metal_scene_draw_smoke`. A layer hidden by a visibility only a reload changes
  (authored, or bound to one of the wallpaper's properties, on the layer or an
  ancestor) has no passes in the graph: it holds no effect
  images, loads no textures and costs what a dropped layer costs. A
  script-driven visibility stays in the graph, and so does a hidden layer another
  layer samples, with its ancestors; a layer named only in its own
  `dependencies` is not one. A script writing `visible` takes the layer
  over: showing a left-out layer, or a property applied or previewed in place
  showing one, marks the graph mutated, the rebuilt graph draws it exactly as the
  property would, and a layer a script has written is never left out again, so
  blinking it rebuilds nothing. A layer only a preview showed has no such owner: a
  graph built while it is hidden leaves it out again. A left-out layer that was
  the scene output's first writer leaves its load and clear to the first layer
  drawn: with clearing off that layer still loads instead of discarding
  (`RenderGraph.aHiddenFirstWriterLeftOutKeepsTheSceneOutputsLoadAndClear` in
  `rendergraph_smoke`). Customizable wallpapers ship every theme, language and
  format as a layer; keeping their hidden effect chains cost gigabytes of
  targets and a render pass per hidden first-use clear every frame.
- **Layer as texture** — `layer_texture_reference_test` (CPU, in the gate):
  `_rt_imageLayerComposite_<id>[_a|_b]` forward refs, duplicate names, missing
  targets, cycles, a layer's own composite outside its effects, file names vs layer names, invisible sources
  kept, producer-before-consumer graph order, and an effect-chain source linking
  from its composite rather than `_rt_default`.
  - A render target is a name that starts with `_rt_` or `_alias_`; any other
    texture name is a file, however it starts
    (`ATextureNamedWithALeadingUnderscoreIsItsFile`). Layers exported from an image
    editor are often named like `_0022_Eyes`, their textures with them: read as a
    target nobody registered, the slot was left unbound and the layer never drew
    (issue #81: a portrait's eyes and lids). The buffers an effect declares are targets
    under a `_rt_` key whatever the effect calls them, `_coc`, `plain` or `_alias_…`, and
    `plain` and `_rt_plain` stay two buffers
    (`AnEffectsOwnBuffersAreTargetsWhateverTheyAreCalled`).
  - A composite is the source layer's card in its own texture space, whatever
    its placement, the scene camera or parallax do
    (`AReferencedLayerIsItsCardWhereverTheSceneShowsIt`). A compose layer's
    camera is not layer-local: its children keep their place inside it
    (`ComposeChildrenKeepTheirPlaceInsideTheLayer`), and a `composelayer` drawn
    into its own composite still samples the screen behind it
    (`ShaderUpdaterMatrices.AComposeLayerReadsTheScreenThroughTheScreenCameraAndItsFullModelMatrix`
    in `shader_updater_behavior_test`).
  - A compose layer that only copies the background is skipped unless another
    layer samples it; then it is drawn into its composite and nowhere else, since
    its card covers its whole target (`ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`).
    A mask that paints that background back over later layers otherwise has
    nothing to sample, and native Metal falls back.
  - A sampled layer inside a compose layer is drawn into its own composite as
    well as into the compose layer's picture, so the compose layer's own effect
    can sample its child (`AComposeLayersEffectCanSampleItsOwnChild`; pixels on
    the native backend in `MetalSceneDraw.AComposeLayersEffectSamplesItsOwnChild`).
    Drawn only into the compose target, the child had no composite: the graph
    logged `link tex <id> not found` and native Metal fell back at prepare.
    Hidden for good (authored or by a property) it is only its composite; hidden
    by a script it keeps its draw into the picture, since nothing rebuilds the
    graph when the script shows it again. The same rule decides whether a
    sampled top-level layer keeps its on-screen draw.
  - A sampled text layer is its card in its own composite, as an image is
    (`ASampledTextLayerIsItsCardInItsOwnComposite`; pixels on the native backend
    in `MetalSceneDraw.AHiddenTextLayerAnotherSamplesIsItsCardInItsComposite`).
    With effects the card is the chain's final card, which is the chain's buffers
    and nothing wider, and a card aligned to one side of the origin is framed
    off the layer's origin. A relayout moves the composite camera with
    the card and resizes the target to keep one texel per unit, since a consumer
    may place the image by its size (`g_Texture1Resolution`); only a size change
    in texels costs a new graph. The target is the card's width and height with
    the fraction cut off, as the scene loads and after every relayout alike (a
    spacing of 0.2 per glyph gives the test cards of .6, where rounding and cutting
    differ; after the first relayout the target was rounded, one texel too wide).
    A hidden sampled text is still laid out when
    its text changes. Before, a text layer had no composite of its own: drawn
    through the scene camera into a screen-sized fallback it sat wherever it is
    on screen, and hidden it was never drawn, so a marquee of a hidden song
    title showed nothing.
  - A layer's own effect binding the layer's `_a` composite (or the bare name)
    reads the chain's buffer A, the image `previous` names at that point (the
    layer before any effect, for the first), and does not make the layer a
    sampled one; other layers binding the name still get the final composite
    (`ALayersOwnEffectReadsItsBufferANotItsComposite`, image and text layers,
    with and without another consumer; pixels on the native backend in
    `MetalSceneDraw.ALayersOwnEffectReadsItsBufferANotItsComposite`). Read as the
    composite, the effect sampled a link the frame filled only after it: native
    Metal refused the scene as history feedback (the retired Compatibility renderer
    logged `slot 0 (_rt_link_<id>) has no image` and drew nothing for a clock whose
    outline effect names its own text). Built-in blur, shine and
    godrays carry the same names, `_a` and `_b` alternating along the chain, in
    the slot their effect binds to `previous`; that binding wins.
  - A self `_b` in the layer's own effects is that same input, not last-frame
    history (`ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn`, the editor's
    `_a`-then-`_b` alternation and `_b` in both effects;
    `SelfBInItsOwnEffectsIsNotAReference`; pixels on the native backend in
    `MetalSceneDraw.ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn`). The
    editor names the buffer `previous` was in when the effect was set up: the
    layer is drawn into `_a` and each effect pass without a target of its own
    moves to the other buffer, so a name can be stale after effects are
    reordered. Wallpaper Engine keeps last-frame images in an effect's own
    `unique` buffers filled by a `copy` command (motion blur), not in these.
    Taken as history, the name made native Metal refuse the scene, and an
    effect naming `_b` in its first slot without a `bind` (a wave after an
    audio-bar effect) had no image for the slot.
  - A layer's own `_a` or `_b` outside its effects is its composite as the frame
    before left it. The shared graph copies each composite into the layer's
    `_rt_link_<id>` after the layer draws, so a read of it ahead of that copy is
    history, and `sceneToRenderGraph` declares the link as a target that carries
    its previous frame, shaped like the composite it is copied from. Without the
    declaration there was no image for the link on its first
    draw (the `slot 0 (_rt_link_<id>) has no image` line above) and drew the layer
    from nothing every frame, while native Metal kept the picture, so the two
    differed; with it they are byte-identical after 1 and 4 frames
    (`MetalSceneDraw.ALayerReadingItsOwnCompositeSeesTheFrameBefore`,
    with the material naming `_a` or `_b` and with the layer's object also naming
    `_b`, which no parser reads). Native Metal no longer refuses a scene for such a
    name (`ALayersOwnCompositeOutsideItsEffectsIsNotARefusal`).
  - Older editors also list the layer in its own `dependencies`, once for each
    self name its effects bind. A dependency names no slot, so it cannot ask
    for the last frame, and a layer waits on nothing of its own; whatever it
    does sample of itself is a texture name. The self entry is skipped: it
    gives the layer no composite and keeps no hidden layer in the graph
    (`ALayersOwnEffectReadsItsBufferANotItsComposite` and
    `ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn` with and without it;
    `HiddenLayers.ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt`).
    Recorded, it drew the layer's last effect pass a second time every frame,
    into a composite nobody sampled.
  - A linked composite's size is never folded into the material as a zero at
    parse time (the card padding divides by it and every texture coordinate of
    the consumer's card becomes `NaN`), and nothing stale is folded in its place:
    the shader reads the target's real size whichever the backend uploads last,
    constants or live values (`AReferencedCompositeIsSampledAtItsRealSize` checks
    both orders).
  - `ExternalMaterialsKeepHiddenTransitiveProducers` covers texture references
    absent from the scene JSON.
- **User-chosen scene textures** — `MediaThumbnailTextureSmoke.TextureProperty*`,
  `.UnsetTexturePropertyKeepsTheAuthoredTexture` and
  `.AnUnreadableUserFileKeepsTheAuthoredTexture` in `media_thumbnail_texture_smoke`;
  `TexLoose.AbsolutePath*`, `.PackagedLoosePicturesComeFromTheMountNotTheHostDisk` and
  `.HostLooseAssetReadability` plus
  `TexPackage.PresetFilesMountBesideThePackageAndThePackageWins` in
  `tex_container_tests`. A `usertextures` entry is either a cover slot the runtime
  supplies or the name of a `scenetexture` property. The property stores a path,
  not a copy, so a slot is only replaced when that file opens at load; unset,
  moved and unreadable all keep the authored texture. Origin travels on
  `LooseAssetCandidate`, never re-derived from the path: a mounted
  `/assets/materials/foo.png` is absolute too, and deciding by `is_absolute()`
  sends every packaged loose picture and video to the host filesystem, where none
  exist. A Workshop preset names its own pictures and videos relatively
  (`files/clip.mp4`) and ships them beside its base's `scene.pkg`, so
  `MountSceneSource` mounts the project folder under the package: packaged files
  still win, and the probes mount the same way. With only the package mounted
  those layers draw black and native Metal falls back.
- **Cover slots keep their authored art** — `MetalSceneDraw.ACoverSlotShowsItsAuthoredTextureUntilACoverArrives`
  (idle, cover before start, cover while running, cover then clear, plain RGBA and
  block-compressed art, a slot with nothing authored),
  `.ACoverIsSampledClampedWhateverItsAuthoredPictureAskedFor` and
  `.AnIdleCoverSlotUploadsItsPictureOnceAndACoverChangeCostsOneUploadPerFrameInFlight`
  in `metal_scene_draw_smoke`; `CoverSlot.*` in `media_thumbnail_texture_smoke` and, with
  `.ASlotOverAnotherLayersCompositeShowsThatCompositeUntilACoverArrives`, in `cover_slot_composite_test`. A
  `usertextures` cover slot (`$mediaThumbnail`, `$mediaPreviousThumbnail`) is the
  picture its author left in that position until a cover is published, and again
  after the explicit clear; the previous-cover slot stays on its authored picture
  until a track has a predecessor. Wallpaper Engine's own frame of a cover layer with
  nothing playing shows that art, and a transparent texel there draws nothing. The
  slot is one runtime image to the renderer (`BindCoverSlot`), so it costs the
  version check a cover already had: no graph rebuild, an idle layer uploads its art
  once per frame in flight and a cover change once per frame in flight again. The
  picture is decoded when a renderer first asks, once, so the texture budget set after
  the parse applies to it. Not substituted: a video, a sprite sheet, a mask or normal
  map (one or two channels), a missing file. A cover keeps its own clamped sampler
  whatever the art's flags say. Art that is another layer's composite stays a render
  target in the slot, with the cover beside it (`SceneMaterial::cover_slots`), and
  the renderer binds the cover there while the image it uploaded is one; the new test
  draws a hidden layer's composite under both cover names, idle, with a cover a few
  frames in (after a still target could have been reused), cleared, and with one and
  two tracks for the previous cover. Before, the slot was the transparent texel: the
  idle, cleared and first-track cases drew nothing on either renderer, and without the
  pass marked as reading a runtime image a cover published mid-run was never shown.
- **JPEG/EXIF orientation** — `tex_schema_tests`: all eight EXIF display
  transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated
  JPEG/EXIF data, invalid IFD offsets.
- **Texture mip budget** — `TexBudget.*` in `tex_container_tests` and
  `MetalSceneDraw.ATextureWhoseNextLevelFallsShortOfTheSurfaceKeepsItsFullSizeLevel`
  in `metal_scene_draw_smoke`. A 2D scene's packaged chain loses a leading level only
  while the next one is still at least as long as the surface's longest side
  (`IImageParser::SetTextureSurfaceSize`), so the level kept covers the surface and a
  picture is never magnified to save memory: a 4240 px texture on a 3456 px display
  keeps its full-size level, which Wallpaper Engine samples, where the earlier rule
  (the surface rounded up to a power of two) dropped it and drew the next, 2120 px,
  level 1.8 times too large. Covered: the selection and the layout metadata it
  preserves (`.SurfacePicksAuthoredLevelsAndKeepsLayoutMetadata`), encoded
  levels dropped without decoding and truncation (`.DroppedEncodedLevelsAreSkippedButALyingSizeStillFails`),
  sprite and video chains left whole (`.SpriteAndVideoTexturesKeepTheirWholeChain`),
  a 4100 px level on a 3456 px surface kept
  (`.ALevelTheNextOneCannotCoverIsKept`), the property for 1920×1080,
  2560×1440 and 3456×2234 surfaces and wide and tall textures from half the surface to
  twice it (the kept level is as long as the surface or the texture, and the one after
  it is shorter than the surface: `.KeptChainIsTheSmallestThatStillCoversTheSurface`),
  levels of a TEXB0003 container measured by their headers
  (`.EncodedChainsAreMeasuredByTheirHeaders`), and the draw test, a 528×352
  chain with a white first level and black others across a 384×256 surface, which
  is drawn from the first level blended with the second (black without
  the change). Not covered: a layer drawn larger than the display
  ([Known limitations](renderer.md#known-limitations)).
- **Render scale** — `RenderScale.*` in `render_scale_test`: physical surface
  sizing and scale/resize transitions (full scale keeps every target at the
  authored size, half scale halves the raster but not the authored canvas,
  three-quarter scale rounds rather than truncates, returning to full scale
  restores the exact size) without changing 2D canvas behavior; a perspective
  raster follows the surface without changing the canvas fallback.
- **2D scene resolution** — `RasterResolution.*` in `render_scale_test` (the
  sizing every backend shares): Canvas mode ignores the display completely and
  keeps the numbers `RenderScale.*` pins; Display mode makes the default target
  and every screen-bound target the size the canvas is presented at (the FILL
  layout in output pixels, so a 1920x1080 canvas on a 3456x2234 panel is
  3972x2234, a canvas wider than the panel keeps its aspect and overshoots it, a
  display smaller than the canvas rasterizes fewer pixels), while the canvas
  stays the source extent (`scene_extent` and the authored sizes do not move)
  and an author-sized target such as an effect's ping-pong buffer follows the
  render scale alone. The render scale divides the display raster, the raster
  never exceeds the device's longest texture side and keeps its aspect when it is
  capped, Canvas to Display and back leaves no drift, and a perspective scene, a
  plain video and a media-sized default target do not read the choice at all.
  `MetalSceneDraw.A2DSceneIsRasterizedAtTheSizeItIsPresentedAtWhenTheHostAsksForTheDisplay`
  pins the native glue by reading the scene's image back: the size follows the
  choice and the render scale live through `ApplyRenderScale`, and a surface
  that moves to another display re-sizes it at the next graph. `MetalSceneDraw.ASceneIsRasterizedAtTheSizeItsResolutionAsksFor`
  makes the scene's own shader report the raster (the texel size the renderer
  hands it times the canvas) and requires the picture to be the one colour that
  proves the raster size, so a renderer that kept the canvas or sized the display differently
  shows as another colour; `UnchangedPresent.ARunningSceneTakesTheResolutionTheHostChooses`
  does the same through a running `SceneWallpaper`, setting the process-wide
  choice and re-sending the render scale as the host does, and reads the posters
  across Canvas, Display and a half render scale. The bridge's
  `tests::scene_settings` and `config::store::tests` pin the saved choice (it
  ships on the display, survives a restart under its own `[quality]` key, a name
  that is neither is refused, the renderer is told at start-up and once per
  change, and every open scene is handed the render scale in force without a
  reconcile), and `PanelPerformanceSettingsTests` the panel's side.
- **Particle owner and inherited scale** —
  `MetalSceneDraw.ParsedParticleBillboardsKeepTheirAuthoredScaleThroughParentsAndChildren`
  parses and simulates an original deterministic scene on both production
  renderers. Its three particles have one local size and owner scales .25, .75
  and 1: their 384x256 output bounds are 20x20, 60x60 and 80x80, matching the
  same original fixture rendered by Wallpaper Engine 2.8.42. Mirrored owners,
  a nonuniform parent and a nonuniform child-particle transform also have
  exact bounds and coverage assertions. Local size must not be divided by an
  average owner scale: that made small authored flames enormous and erased
  the difference between their scales. CPU coverage in
  `particle_billboard_size_test` protects authored-canvas and perspective
  projection, depth, inherited/nonuniform/mirrored scale and model-space size;
  `particle_rope_pieces_test` (`RopePieces.ThickFormatCarriesTheEndColourAndEndHalfSize`)
  checks local endpoint widths. No transform or
  scale norm is read during raw geometry generation. A `worldspace` particle
  file is the exception that draws through none of its layer's matrix (above).
- **Random sprite-sheet frames** — `ParticleMouseControlpoint.SpawnedParticlesCarryAnIndependentFrameValueSpreadOverTheSheet`
  in `particle_mouse_controlpoint_test`. A `randomframe` particle keeps one frame
  for its life: the particle's own `seed`, one draw at spawn, so identical spawns
  still differ (a function of the spawn state gave identical particles one frame, and
  an integral value would always select frame 0). `ParseLevel.RandomFrameNeverBlendsNeighbouringSpriteFrames`
  in `particle_parity_test` checks the file-level rule, and
  `Renderers.RandomFrameDropsTheSheetBlendFromTheShaderWhateverTheFileAsks` parses
  scenes through the real scene parser with a probe shader and requires the
  `SPRITESHEETBLEND`-gated uniform to be compiled out of a `randomframe` file and out
  of one with the no-blending flag, and kept for a sequence.
- **Particle behaviour against Wallpaper Engine 2.8.42** — `particle_parity_test`
  (CPU, in the gate), every fixture built from JSON in the test. `ParticleSpawn.*`:
  the sphere's distance distribution for a flat, an all-nonzero and a stretched
  `directions` (mean and share inside half the radius against the closed forms),
  minimum and maximum distance, away-from-centre velocity and the random direction of
  a particle born on the centre, `cone`, `sign`; the box's fold of a negative minimum,
  hollow centre for a positive one, control point orientation turning only an emitter
  that names a later control point; one seed per particle. `EmitterSchedule.*`:
  `flags` 2 against the rate, a burst paid out of the rate's account, `delay`,
  `duration`, periodic windows with pauses, `maxtoemitperperiod`, a window re-arming
  the burst, a lone burst firing once, and every instance running its own schedule.
  `Initializers.*`, `ColourInitializers.*` and `ColourOverride.*`: hue steps spaced as
  the loader spaces them (whole-turn and partial ranges, one step or none, a range of no
  width) and colour-list noise as a draw cut off at 0 and 1 with the override added
  after it; `exponent` on every random initializer, the
  millisecond lifetime floor, pixel and scene-unit size defaults, `sizerandom` and
  `alpharandom` scaling the value so far (two in a file narrow each other in either
  order, one alone keeps its range, the lifetime stays replaced;
  `Initializers.ASecondSizeInitializer...`, `.TwoSizeInitializersScaleInEitherOrder`,
  `.ASecondAlphaInitializer...`, and `ParseLevel.TwoSizeInitializersOfOneFile...` through
  the scene parser and a real spawn), the colour override
  re-tinting colours (spread kept, identity for the preset's own colour, white
  desaturating, plain tint without colours, HSV and list initializers, `colorchange`
  default and re-tint, the override's tint on top of a re-tint and not for an override
  equal to the preset's colour, a `colorchange` end re-tinted past red tinted back to red
  (issue #67), brightness only in HDR). `ParticleOverrideTint.*`
  (`particle_override_tint_test`): after the re-tint a colour-bearing preset's newborn is
  multiplied by the override and remembers that product (a scene of version 5 or later
  keeps the re-tint alone: `InstanceOverride.FromSceneVersionFiveARetintedPresetIsNotTintedByTheOverrideAgain`
  in `particle_parity_test`, read off Wallpaper Engine probe scenes at versions 1 to 6),
  the colourless preset gets the
  override unsquared, an override equal to the preset's representative colour leaves the
  default colour exactly, and a `colorchange` ramp is tinted at both ends. `SequenceInitializers.*`:
  `mapsequencearound`/`between`, `inheritcontrolpointvelocity`, `positionoffsetrandom`,
  `inheritinitialvaluefromevent` (an inherited `multiplysize` scales by half of the
  parent's size, in the engine's unit, `setsize` copies it). `Movement.*`, `AngularMovement.*`,
  `ControlpointAttract.*`, `Oscillators.*`, `Turbulence.*`, `Vortex.*`,
  `ControlpointOperators.*` and `Collision.*`: the integrators and damping, that only
  the movement operators advance a particle (a file without them keeps its particles
  still) and that they keep the previous position only while an operator asks for it,
  gravity kept in screen axes with the layer's scale in a layer-space system (a
  `worldspace` system's gravity is left as written), falloff and flags, a delete
  threshold tested on the path of the last step, the instance speed override on the
  attract pull, turbulence speed and position-oscillation frequency (and the file flag
  that ignores it), the oscillator formula and blend window, per-particle turbulence,
  vortex centre/axis/flags/audio, the control point operators, and collision shapes
  (the response given to every particle found inside whichever way it moves, the
  default sphere origin of a pixel scene, and flag 1 carrying a plane or sphere with a
  turned control point). `Prewarm.*`: a start time
  populates the first frame, the 0.05/0.2 s step, the bound on a huge start time, an
  event child's instance (and the number of steps it costs, capped at 6000), a
  static child, and a worldspace system or a pinned control point prewarmed by the
  matrix its layer ends up with under its parent groups. `EventFollow.*`: a follower keeps its
  particles after the followed one ends and stays where it ended. `WorldSpace.*`:
  live particles and their velocity stay in the scene when the layer moves, turns
  or is rescaled, a follower hangs where the layer's matrix puts its worldspace
  parent's particle, every renderer's node of a worldspace system draws from the
  layer's origin alone, and a layer under a scaled group is spread by the whole
  chain. `ParseLevel.*`:
  renderer defaults, truncation and clamps, smoothing only without scrolling,
  override control points, pinned control points, the pixel-canvas flag and the
  particle defaults a scene gets with and without a projection key. `InstanceOverride.*`:
  a control point, its angle and the brightness bound to user properties follow them while
  the scene runs, and the speed override with the file flag that ignores it.
  `Renderers.*`: an empty `renderer` list draws nothing but the system still runs and
  spawns its children, a missing or non-array key gets one sprite, and a 2D scene's eye
  is 2000 in front of the canvas. `MultipleRenderers.*`: one mesh per `renderer` entry,
  each with its own shader whatever order the entries are in, and live particles kept in
  birth order for a plain rope in any position. `RopeGeometry.*`: a subdivided rope
  trail, a plain rope's `subdivision + 1` pieces per pair in the thick layout, and a
  trail's recorded points and strip length as the shader sees them. `ParticleCorpus.EveryLocalParticleFileSimulatesWithoutNonFiniteValues`
  is opt-in (`WE_TEST_PARTICLE_DIR` names a directory of unpacked scenes): twenty
  simulated seconds of every particle file there, no non-finite value, never more than
  `maxcount`; `ParticleCorpus.PrewarmCostOfTheLocalLibraryIsReported` times the prewarm of
  every file with its own start time and prints the slowest. `particle_mouse_controlpoint_test` keeps the audio-emitter
  cases, the size override on ramps, the control point attraction, the mouse control point in
  the cropped presentation and the movement and audio-band cases, updated to the rules above.
  The layer-scale size cases live in `particle_billboard_size_test`
  (`ParticleBillboardSize.GeneratorWritesTheAuthoredHalfSizeWhateverTheOwnerAndParentScales`,
  `.LayerSpaceBillboardIsDrawnThroughTheWholeLayerMatrix`,
  `.AuthoredCanvasAndPerspectiveCamerasBothFollowTheLayerScale`); the instance override record,
  the birth initializer and the rate and count overrides in `particle_override_test`
  (`ParticleInstanceOverride.*`, `ParticleRateOverride.*`, `ParticleCountOverride.*`); mouse
  control points in the owner's space, emitter control point selection and the order of
  movement and control point attraction in `particle_control_point_test`
  (`ParticleControlPoints.*`).
- **Rope and rope-trail geometry** — `particle_rope_pieces_test` and
  `particle_rope_geometry_test`, with
  `RopeGeometry.ATrailIsDrawnAsOnePiecePerSubdivisionBetweenItsRecordedPoints`
  (CPU, in the gate). `particle_rope_pieces_test` (`RopePieces.*`, `RopeTextureRepeat.*`)
  builds the generator input by hand: pieces per instance and never across instances, dead particles skipped
  and neighbours joined, subdivision through the particles, coincident points
  without `NaN`, the thick format's end colour and half-size, the instance offset, the rope-trail head, tail shrink and per-slot
  separation, and how `uv_scale`, scrolling and smoothing encode the strip length.
  `particle_rope_geometry_test` keeps the simulation's history (its subsystem fixtures carry a movement
  operator because a particle only moves inside one) — birth point, growth to capacity, zero time step, respawn
  reset. Index width: packed 16-bit up to 16 384 quads, 32-bit past that,
  overflow-safe capacity math, and draw order across instances on a 32-bit mesh.
- **Hidden particle geometry** — `ParticleSystem::RebuildVisibleMeshes` runs after
  `Tick` and rebuilds a hidden subsystem on the frame it becomes visible or must
  produce; the simulation still runs while it is hidden.
  `RopeHiddenLayerReveal.ALayerRevealedAfterItsStepDrawsWhatAnAlwaysVisibleRunDraws`
  (`particle_rope_pieces_test`) shows a layer (or its parent) in the Tick after Emitt and compares the first
  visible frame's mesh bytes with an always-visible run, counting the generator's calls; `particle_rope_pieces_test`
  and `particle_billboard_size_test` cover the geometry; a fixed-seed
  `offscreen_scene_probe` dump of a hidden-then-shown particle scene must stay
  byte-identical to a build that generated every frame.
- **Matrix packing and live uniform updates** — `ShaderValuePacking.*` and
  `ShaderValueUpdaterCompat.*` in `script_runtime_compat_test` cover column-major
  values, row-major/strided inputs, inline/dynamic/empty ownership and current
  camera/effect/material-slot values; `ShaderUpdater*` in `shader_updater_behavior_test`
  pins the per-slot reflection, render-target sizes and audio-spectrum arrays. Native Metal writes live engine uniforms after parser defaults (checked on
  output pixels in `metal_scene_draw_smoke`).
- **Lighting projection** — `MetalSceneDraw.LightingViewDirectionFollowsTheAuthoredSceneThroughEffects`
  checks lit and unlit pixels for both projections, directly and through
  effects. Material compilation sets `SCENE_ORTHO` from the authored scene
  projection, effect passes included, so a 2D layer uses the
  shader's fixed view direction rather than a perspective eye on the layer's
  plane (which reduces its lighting to ambient-only). Material overrides cannot
  change this scene-owned switch, and the shader request/cache key includes it.
  `PerformLighting_V1` itself is generated as Wallpaper Engine writes it, below.
- **Scene lights (LightingV1)** — from `Renderer/`, `cargo test --release --locked -p
  wm-shader --features ffi --lib preprocess::lighting` pins the generated block (arrays
  sized by the `LIGHTS_*` combos, nothing for an unlit pass), `pipeline::tests::globals`
  (`each_light_member_has_exactly_the_count_of_its_combo`) the light members the
  reflection reports, and `--test metal_compile`
  (`the_msl_of_lit_programs_compiles_with_the_system_metal_compiler`) compiles a lit
  program with the system Metal compiler. `--test corpus`
  (`lit_shaders_expand_the_lighting_block`) expands the block in Wallpaper Engine's own lit
  shaders when `WALLPAPER_MACHINE_ASSETS_ROOT` names them, and its `lit and fogged` combo set
  preprocesses every shipped shader with both fogs on.
  `SceneLights.EachLightKindFillsItsOwnLightingArray` and
  `.ALegacyLightIsKeptAtItsOriginAndReachesThePackedLightPosition` (`scene_schema_part02_test`)
  check every kind's uniform layout, parenting and the legacy-only packing;
  `SceneLights.LightsFollowAUserPropertyAScriptAndAnIntensityTimeline` the
  bindings and the light-state hash the static cache folds in;
  `NormalMatrix.ItIsTheRotationOfTheDrawWithoutItsScale` the per-draw
  normal matrix; `MetalSceneDraw.ALayerIsLitByScenePointAndDirectionalLights`
  the lit pixels.
  `SceneFog.DistanceFogIsCompiledIntoPassesWhoseFogComboIsOn`,
  `.WithoutDistanceFogNoPassIsCompiledWithIt` and `.AuthoredDensitiesReachTheFogParameters`
  check that scene fog reaches a pass whose `FOG` combo is on (and only such a
  pass) with Wallpaper Engine's parameter layout,
  `MetalSceneDraw.AnEffectLayerIsFoggedWhereItSitsAsAPlainLayerIs`
  that a layer under a copy effect is fogged where it sits, as the same layer
  without the effect is (the centre, sides and corners of its card within two
  levels, for distance fog and for height fog; fogging the
  layer's own card dimmed it toward the edge),
  `.AnEffectLayersColourAndAlphaAreAppliedOnceWhenItIsFoggedWhereItSits`
  that the layer's colour and alpha come through that pass once, not twice (the
  fogging pass draws with a white colour),
  `.AnEffectLayerWhoseEffectsAScriptSwitchesIsFoggedWhereItSits` that
  it holds with the chain's only effect switched off and on by a script,
  `.AnEffectLayerThatMakesItsOwnPictureIsFoggedWhereItSits` that it
  holds for a layer whose own pass is not drawn (`copybackground` off): an effect
  that paints red where its input is empty makes a red card, fogged as the plain
  layer is, where the same effect over a layer that draws its own pass makes a black
  one, and
  `.AnEffectLayerWhoseMaterialTakesNoFogIsNotFogged` that a layer
  whose material turns `FOG` off stays unfogged under an effect, and
  `RenderTargetSlots.TheTexelUniformIsTheStepOfTheTargetTheSlotSamples` that
  `g_Texture<N>Texel` is (1 / width, 1 / height, width, height) of the sampled
  texture. After a shader-layer change, rebuild
  `Renderer/target/release/libwm_shader.a` (`cargo build -p wm-shader --features ffi
  --release`, run inside `Renderer/`) before the CMake test binaries, or they link the
  old compiler.
- **HDR, bloom and emissive masks** — an authored `hdr` scene with bloom on uses
  RGBA16F color intermediates
  (`BloomHdr.HdrNeedsBloomToo`: with bloom off it is
  8-bit, as in Wallpaper Engine); masks and source media keep their formats and
  SDR scenes keep RGBA8. HDR shader combos are enabled before compilation, not
  approximated by raising final display brightness, and the fourth
  texture-component flag (TEX bit23) travels through the C++/Rust compiler
  interface so an alpha-channel emissive mask can enable its shader branch.
  Missing HDR materials fail rather than silently substituting LDR. HDR bloom
  follows Wallpaper Engine 2.8: as many half-size levels as the frame's shorter
  side allows, at most eight and at most `bloomhdriterations`; extraction and
  downsampling read one source texel either side and upsampling half of one
  (`ScenePostProcessPass::source_texel_radius`, refreshed at prepare/resize); the
  two coarsest levels upsample through `hdr_upsample_cubic` (the linear upsample
  stands in when an asset set lacks it); every upsample adds its level times
  `bloomhdrscatter` as it is, and the extraction strength is
  `bloomhdrstrength / (scatter^max(levels - 2, 0) + 1)`. A scene that leaves the
  keys out gets strength 2, threshold 1, feather 0.1, scatter 1.619 and eight
  iterations. `BloomHdr.TheLevelCountFollowsTheFrameAndTheIterationLimitAndWeighsEachPass` and
  `.TheLevelCountIsCappedAtEightOnALargeFrame` (`scene_schema_part06_test`) check
  the levels, radii, cubic passes and weights the parser builds, and
  `MetalSceneDraw.HdrBloomWeighsItsLevelsAsWallpaperEngine` GPU pixels across
  live strength and scatter changes (zero strength included);
  `.ParsedHdrRadianceSurvivesEffectsLayerLinksAndBloom` uses an
  original bit23 emissive texture through the real parser, effect chain and layer
  references. `MetalSceneDraw.OverbrightRadianceReachesBloomWithoutChangingLdrColor`
  reads pixels and unclamped radiance on the native backend, and
  `BloomHdr.AnHdrSceneWithoutItsHdrMaterialsIsRefusedRatherThanDrawnWithTheLdrChain`
  guards the parser.
- **Render targets and texture allocation**
  - Texture residency comparisons must cover the scene's full visibility and
    crossfade cycle, including the moments when each affected image is actually
    visible; matching startup frames can miss large animated layers whose
    opacity is still zero.
  - Native Metal allocates only targets the compiled passes name.
    `metal_scene_draw_smoke` checks that a declared but unused target stays
    unallocated through optimisation off/on, and that a copy the plan drops as
    dead is not made while the optimisation is on and gets its image back,
    filled, when it is turned off without a recompile. Compare target residency
    with the harness's render-target bytes, not the device-wide allocation.
  - `render_target_lifetime_test` checks 32 generated multi-version graphs
    against a last-access oracle, plus nested composites with aliases, three
    sizes, visible and hidden parents, and background-copy enabled/disabled.
    Alias clears and readers must refer to the same canonical resource. Pooled
    targets are retained until every logical version has finished, and effect
    inputs are cleared explicitly when `copybackground=false`; the test asserts
    version lifetimes and a real transparent writer before an effect samples its
    empty input.
  - The check's eight generated nested-compose scenes compare pooled and isolated
    allocation byte for byte and add known-pixel assertions that empty inputs do
    not leak old pixels and that children actually render.
  - A target the frame reads before anything writes it, and writes later, carries
    the previous frame's pixels (a motion-blur history buffer). The render graph
    flags it (`carriesPreviousFrame`), and the renderer reserves it an image of
    its own before preparing passes, so it is never
    pooled; pooled, it would take an image another target redraws every frame and
    a trail would blend in a faint copy of some other layer. The scene output is
    exempt (the frame's prepass clears it first). `RenderTargetLifetime.OnlyTargetsReadBeforeTheFrameWritesThemKeepTheirOwnImage`
    and `.CarriedOverKeysAreTheOnesReadBeforeTheirFirstWrite` cover the graph.
    It costs exactly those buffers' memory. Native Metal keeps every carried-over
    target in an image of its own for the life of the graph, so it draws these too
    (`MetalSceneDraw.ALayerReadingThePreviousFrameSeesExactlyThePreviousFrame`:
    the first frame reads the cleared buffer, each later one the frame before,
    byte-identical with scene optimisation off and on), and reports the loop as
    a reason to keep the clock running.
- **Render-target reuse correctness** — `static_subgraph_cache_test` (reuse
  verdicts, copy elision, alias resolution, and `OnlyWritersOfCacheableTargetsAreSampled`:
  only the passes `Plan` reads are sampled, and an unsampled pass cannot
  change a verdict) and, on the native backend,
  `MetalSceneDraw.AnUnchangedTargetIsReusedAndProducesTheSamePixels` and
  `.TurningTheOptimisationOffDrawsEveryPassAgain` in `metal_scene_draw_smoke`.
  Reuse must be provable by readback, not by a counter alone: a skipped pass has
  to leave byte-identical pixels, and a changed input has to redraw. A pooled
  image another target still draws into is never pinned, because that key's prepared
  passes still draw into the image every frame; pinning it lets a skipped layer read
  another layer's picture from the second frame on, which the pooled/isolated
  comparison in `check_renderer.py` shows as a divergence.
- **Sprite-sheet stepping and reuse** — `MetalSceneDraw.ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges`.
  A sheet between frame changes may be reused, but its clock must keep running or
  the animation never reaches the next frame. `sprite_animation_test` checks
  elapsed time across cadences and long loops.

- **Fit with blurred backdrop** — `backdrop_geometry_test` and `backdrop_scene_test`. The
  mode's picture, position, scale factor and pointer mapping are Fit's; the room around
  it holds a darker, blurred copy of the same live picture, drawn only into the bands
  the picture leaves, so the picture's bytes are Fit's. The copy exists only while a
  composition has room for it (a one-pixel gap is none), costs no extra scene pass,
  and moves neither with the picture's position nor with its scale factor. A frame that
  repeats the picture repeats the copy and is skipped; the key that decides it must
  keep its capacity.

## Alpha compositing

- **Source-over coverage** — the `generated-alpha` case in `check_renderer.py`.
  `SetBlend` (and the native `MetalBlend` state) writes source-over's
  `As + Ad*(1-As)` for `BlendMode::Translucent`: the color source factor is
  `SRC_ALPHA` but the alpha source factor is `ONE`. With `SRC_ALPHA` for both,
  every translucent draw loses coverage on partially covered texels, nested
  compose layers multiply the loss, and soft anti-aliased seams show a thin
  saturated line. Opaque and fully transparent texels are unaffected. The case
  composites a half-covered source over transparent, half-covered and opaque
  destinations inside a compose layer and samples the composed alpha back as RGB
  (expected 128/191/255). It uses synthetic shaders only. A text composite is the one
  exception: the card of a text layer that draws through effects writes its glyph's alpha
  squared, as Wallpaper Engine's glyph pass does, because that is where its text lands at
  alpha cubed; the rule above is the blend state of every other draw and is not touched
  (see the text composite entry under Text, fonts and clocks).
- **Alpha-to-coverage passes** — `MetalBlend.*` in `metal_backend_test`. On multisampled
  attachments coverage decides what an `alphatocoverage` pass keeps and kept
  samples are written unblended, as in Direct3D (blending as well multiplies
  partially covered texels by alpha a second time and dims thin lines). On
  single-sample targets coverage is disabled and source-over
  blending is used, otherwise transparent or partially covered pixels become opaque.
  Scenes stay single-sampled, so edges are thresholded rather than antialiased.
  `generated-alpha-single-sample` verifies composed coverage on Compatibility
  (128/191/255), `MetalSceneDraw.SingleSampleAlphaCoveragePreservesTransparentAndPartialPixels`
  checks zero, half and full coverage as RGB on Native Metal across repeated
  frames, and the CPU blend-state tests keep the unblended multisample
  contract. None of this adds MSAA targets, render passes or allocations.

## Text, fonts and clocks

- **Fonts and limits** — `text_object_runtime_test`. Font decoding prefers valid
  authored bytes, then the installed face of the font the scene names, then Arial;
  missing paths and malformed embedded fonts use the same fallback for both
  measurement and rasterization. Coverage spans seven font choices and three
  text samples including Chinese, plus missing/corrupt sources and valid assets,
  and checks actual glyph coverage rather than just nonempty strings. Authored
  `maxwidth`, `maxrows`, `limitwidth`, `limitrows` and `limituseellipsis`
  constrain both measurement and rasterization, including dynamic text updates:
  `TextObjectRuntime.WidthAndRowLimitsProduceTheSamePixelsAsExplicitLineBreaks`
  and `.EllipsisFitsTheLastVisibleRowAndLimitFlagsRemainIndependent` compare the
  rendered pixels and layout bounds, and FreeType and fallback fonts share the
  same wrapping and truncation rules. A layout runs for every change of a text
  layer, so the faces are kept and not read each time:
  `TextObjectRuntime.ASystemFontIsOpenedOnceAndNotForEveryLayout` counts the font
  files a layer's layouts open (one for the font, then the faces of the list down to
  the one that has a glyph it lacks, all on the first layout and none after; the
  faces read from their files, not from a copy of the font in memory),
  `.AFallbackFaceIsOpenedOnlyWhenAGlyphIsMissing` that text the font can draw asks for
  no second face, `.AFontTheWallpaperShipsIsNotOpenedFromAFile` that an authored font
  stays in memory, and `.TheFaceCacheKeepsEightFacesAndDropsTheOneUnusedLongest`
  that ten fonts leave eight open and the one used last is not reopened, and
  `.AFontFileThatChangedIsOpenedAgainBeforeItsCachedFaceIsUsed` that a font file
  rewritten or deleted under a cached face is opened again, not read through the old
  mapping. The face of
  a collection is chosen by PostScript name, not by position in the file:
  `.AFaceOfACollectionIsChosenByItsPostScriptName` (the four weights of Songti, by ink,
  and a name the file lacks opens the first face once) and
  `.HanFallbackUsesTheSimplifiedFace` (the ideographic and fullwidth commas and the
  ideographic full stop sit on the baseline, as in PingFang SC, not 0.29 to 0.36 em
  above it, as in the Hong Kong face that starts the file);
  `.TheFaceTheSystemNamesReachesTheLayerFromTheSceneAndFromAScript` and
  `.ANewFaceOfTheSameFileLaysTheTextOutAgain` cover how the name gets to the layer.
  They need the fonts macOS ships; the Han test skips where PingFang SC is not
  installed, and the eight-face test where fewer than ten of the fonts it names are.
- **Scene fonts** — `text_object_runtime_test`. `TextObjectRuntime.SceneFontKeysAreTheEightWallpaperEngineKeys`
  requires the eight `systemfont_` keys as the whole lower-case string and nothing near them
  (`systemfont_Arial`, `fonts/systemfont_arial`, `systemfont_Helvetica`, `systemfont_serif`, a bare
  family) to be a key, and everything that is not one to resolve to Arial;
  `.AMissingFontFileDrawsInArial` parses a missing file, a bare family, a wrong-cased key and an
  unknown key and requires Arial's face and Arial's pixels for each, with the font the scene named
  still what a script reads back; `.ATextObjectWithoutAFontKeyIsArial` that a text object with no
  `font` is in Arial and has Arial's line (153 pixels at 32 points, ascender 121, where a
  Helvetica's is 1.0 em); `.AMissingWindowsFontIsSetInThatFontsAdvancesAndLine` that
  Consolas, Cambria, Segoe UI and Calibri have the line the cards Wallpaper Engine saved pin (161
  and 171 pixels at 33 and 35 points, 156 at 32, 538 and 222 for Segoe UI at 97 and 40, 163 for
  Calibri at 32), their digits and for Consolas every glyph the real advance (75, 80, 73, 217, 89
  and 67 pixels), Consolas's digits 0.643 em tall within 0.03 and its ascender 103 and descender 36
  pixels at 33 points, and the clocks' cards within 5 percent of the saved ones;
  `.AStandInSetsTheBaselineByTheRealFontsAscenderAndDescender` that the rows are set in the real
  font's units and not the stand-in's; `.AGlyphTheFontLacksComesFromTheFirstFaceOfWallpaperEnginesList`
  with Apple Braille as the font, which has no letters and no Han: an `A` is Arial's pixels
  (PingFang SC and Helvetica have one too and differ), a Han character PingFang SC's and not Arial
  Unicode MS's, a glyph no face has is skipped without moving its neighbours, and a glyph the font
  has is the font's; `.EachFaceOfTheFallbackListDrawsWhatTheFacesBeforeItLack` finds, for each face
  of the list after Arial, a glyph none of the faces before it has and requires a layer whose
  font has nothing of it to draw it as that face alone does (it needs at least three faces of the
  list that can be told apart, and logs the ones it cannot); `.CjkPunctuationIsNotDrawnByTheSymbolFace`
  that the fullwidth and ideographic marks come from PingFang SC and not from Apple Symbols (which
  draws some of them centred), and that a symbol both have, which Arial and Segoe UI's stand-in
  lack, is still Apple Symbols'; `.AFamilyThatMovedOrAppearedIsFoundAgain` that a family not
  found is asked for again after the retry time, a found one is kept while its file is there and
  looked up again when the file is gone. The migrated tests: the scene-font parse tests now expect the kind `system`
  and the identity of the key (`arial` for a family and a font that cannot be loaded),
  `TextParseScene.ParsedVerdanaTextIsDrawnAntiAliasedIntoACardOfItsMeasuredSize` (in `text_object_behavior_test`, which replaced the family test) and
  `.TheFaceTheSystemNamesReachesTheLayerFromTheSceneAndFromAScript` use the keys,
  `.FontFallbackHandlesFamiliesMissingFilesAndCorruptAssets` builds its reference through
  `ResolveSceneFont`, and the tests that wanted Helvetica's metrics ask for the installed family
  (`ResolveInstalledFamily`). The Consolas ascender is the one number checked against a frame of
  the reference: the clock of 3299228616 has digit rows 87 pixels tall in both and within a pixel
  of each other's place; the other three stand-ins' ascender and descender are the fonts' own as
  remembered and only their sum is pinned.
- **Text as Wallpaper Engine sets it** — `text_object_runtime_test`.
  `TextObjectRuntime.PointSizeIsRequestedFromTheFontAt300Dpi` asks FreeType for the
  face the way Wallpaper Engine does (`FT_Set_Char_Size` at 300 dpi, whose line
  height is one row's card height) and requires the layout to agree;
  `.PointSizeIsClampedToTheRangeWallpaperEngineAccepts` pins the 1 through 256 clamp
  for measurement and estimate alike. `.EmptyTextIsATwoByTwoCardPlusPadding`,
  `.CardPaddingSizesTheCardAndNeverNarrowsTheWrap` (a limit that just fits keeps the
  text on one row whatever the padding) and `.CardPaddingGrowsTheCardOutwardOnEveryAxis`
  (the ink is the padding in from the card's edge for every alignment) cover the card; `.ANegativePaddingTakesTheCardInAndOnlyTheTopIsCapped` pins that
  a lane is capped at 512 and not floored (a card never goes below a pixel);
  `.PaddingAndSpacingReadTheFormsWallpaperEngineReads` (number, `"x y"`, a lone
  `"x"`, a bound `value`, the 32-pixel default, the 512 cap, a negative lane, and a
  JSON array, which the reference does not read and so leaves the default) and
  `.CardPaddingAppliesOnlyToLayersWallpaperEnginePads` (effects, a visible effect
  only, colour blend other than none and add, LED source, opaque background) cover
  the parse and the gate, and `.ASceneWithFogPadsEveryTextLayerWhateverItsEffects`
  the scene-wide fog flags (`fogdistance`, `fogheight`: the renderer composites every
  text layer in such a scene, which is what pads it; the same two flags also add the
  `FOG_COMPUTED` combo to its shader, which a text layer's own shader has no use for).
  `.SpacingAddsToEveryAdvanceAndToTheLinePitch` requires a
  row to be the pen at the glyph starts and the last glyph's ink, so `n` glyphs
  widen by `n - 1` gaps, and rows to step by the line height plus `spacing` y;
  `.SpacingMovesTheRowsOfRasterisedText` checks the pixels.
  `.BlockAlignJustifiesOnlyRowsThatEndedAtAWordWrap` justifies the wrapped rows of
  a paragraph to exactly `maxwidth` and leaves the paragraph's last row and the
  next paragraph's rows pixel-identical to the unjustified layout;
  `.BlockAlignNeedsAWidthLimitAndALineThatWraps` leaves unlimited and single-row
  text alone. Where a row ends is pinned against the rule read from the reference:
  `.TheLastRowTheLimitAllowsIsCutAtTheGlyphThatDidNotFit` (on the last row
  `maxrows` allows nothing wraps; the row keeps every glyph before the one that did
  not fit, inside a word if that is where it falls, and with two rows allowed the
  first still wraps at its last space and only the second is cut),
  `.AnEllipsisReplacesTheEndOfTheLastRowAtTheGlyphThatDidNotFit` (the marker
  replaces the end of that row, glyphs dropped one at a time until it fits, never the
  whole word before it),
  `.ALineBreakWithNothingAfterItAddsNoRowAndNoEllipsis` (a break with nothing after
  it ends the text; one with anything after it, a second break included, is cut)
  and `.ARowThatWrapsAtADoubleSpaceKeepsAllButOneOfTheSpaces` (the break is at the
  last space before the glyph, and the space before it stays in the row, where
  `blockalign` has it to widen). Each fails against the rule it replaced (a
  word-boundary cut on the last row, a row after a trailing break, every trailing
  space dropped). `.TextMeasuresToTheCardsWallpaperEngineSaved` is ground truth: the
  size of a text layer in a scene file is the card Wallpaper Engine laid the text out
  in, and the five cards it saved for Arial text that the tests keep (with and
  without a padding of 32, a lone full stop, a run of dashes, a long run of
  underscores) are reproduced to the pixel with exact comparison, which is as far as
  the claim goes: other fonts and scripts, and any other text, are not compared. They
  are the metrics of the Arial of the machine that ran Wallpaper Engine, and a build
  of the font with other metrics shows as a difference, not a skip.
  `.PenAdvancesAreUnhintedWholePixelsKernedWithTheNextGlyph` states the kerning rule
  against FreeType's own numbers. Two cards that were reproduced while the rule was
  developed, one of wrapped text of 729 characters and one with a padding of 128, are
  not kept: their text is private, so nothing re-checks them. The other fixtures use
  a system font, so the tests state relations to the font's own metrics, not pixel
  counts, and the ground-truth tests skip where Arial is not installed.
- **Layout record and the authored `size`** — `text_object_runtime_test`.
  `TextObjectRuntime.LayoutRecordMatchesFreeType` reads the record of Helvetica at
  32 pt against FreeType's own size metrics (the ascender and descender, cut to whole
  pixels, and the height plus `spacing` y as the pitch), counts the rows of `H\nH`,
  `H\n` (a break with nothing after it adds none) and `H\n\nH`, lets an A with a ring
  raise the top of the block above the ascender and nothing else, and checks the
  padded card and the empty text (no rows, a 2 by 2 card); the test fails, not skips,
  if that font's ring no longer rises above its ascender.
  `.BoxLayoutHasTheSameRecordAsAFace` gives the record of the boxes a text is laid out
  in where no font opens (0.9 em of ascender, 0.3 of descender, a 1.2 em line), which a
  machine with a font never reaches. `.AuthoredTextObjectSizeDoesNotSetTheCard` parses
  a `size` of 320 by 120 beside the same text without one and requires the same
  card, texture and quad for both, as the text grows and shrinks;
  `.ACardShrinksWhenScriptedTextGetsShorter` a script that writes a shorter text under
  that `size`, which kept the box's card before;
  `ScriptMadeText.ASizeSuppliedByTheScriptIsIgnoredForText` (`scene_schema_part08_test`) a `createLayer` with one.
  `.ATextLayerIsMeasuredOnceAsItIsParsed` counts one measurement per layer where a
  layer's card, texture and runtime state measured it four times,
  `.ATextCardIsBuiltAtItsTruncatedSizeInTexels` requires the buffers of a card with a
  fractional width (a colour blend, so they are the card's) to be that width cut
  down, not rounded, `.ACardsTexelExtentIsItsSizeWithTheFractionCutOff` pins the one
  rule every such buffer takes its size from (the scene's, an effect's and a
  composite's, at parse and after a relayout), `.ACardThatGrowsWithinATexelKeepsItsBuffers`
  requires a card whose width grows by a fraction that stays within the texel its
  buffers already have to leave them and the graph alone (the pair of texts is found
  by measuring, so it holds for any font; it rebuilt the buffers at twice the size
  before), and `.PlainAlignedTextKeepsItsCardEdgeOnTheOrigin` pins what the
  placement changes after it must keep: a plain text sits on its origin by its card's
  left, right or middle edge and its top, along the layer's own scale. The scene
  `size` appears in no other expectation; `TextRaster.CentredTextIsCentredInItsCard` and the
  clock parent test (`TextClockScene.TheParentClockKeepsAVisibleRuntimeTexture`, a synthetic clock
  scene) in `text_object_behavior_test` read the card from the text.
- **Text placement about the origin** — `text_object_runtime_test`. The alignment keys
  hang the card from the layer's origin and leave the node on it.
  `TextObjectRuntime.TheReferenceLineOfTheVerticalAlignmentSitsOnTheOrigin` finds the
  baselines of one row and of three, with and without a `spacing` y, in the pixels of
  the raster, and requires the first to lie an ascender below the origin for `top`, half
  of it for `center`, and for `bottom` the rows' pitches and a descender above it, with
  the face's numbers read from FreeType apart from the layout. The ground truth is
  Wallpaper Engine's own, from the probe scenes it drew: DIN Engschrift at 48 points put
  the first baseline 159, 79.5 below the origin and 50 above it.
  `.ArialAtThirtyTwoPointsHangsFromTheOriginByTheReferenceLine` states the offsets of
  the 153-pixel Arial card Wallpaper Engine saved,
  `.TheCardHangsFromTheOriginByTheEdgeTheTextIsAlignedTo` the nine alignments with and
  without padding and with one and three rows (the card is the same card for every
  alignment; the padded edges lie beyond the origin),
  `.PaddingGrowsTheCardOutwardAndLeavesTheTextWhereItWas` that the ink is as far from
  the origin with the padding as without, `.AlignmentDoesNotChangeThePixelsOfARow` that
  one row is the same raster whichever way it is aligned, and
  `.TheFirstBaselineDoesNotDependOnInkAboveTheAscender` that an A with a ring makes the
  card taller and moves the baseline nowhere (it fails, not skips, if the font's ring no
  longer rises above its ascender). `.RowsOfABlockAlignWithinTheWidestRow` and
  `.ARowsFirstGlyphKeepsItsOwnBearingWhateverTheOtherRowsStartWith` set rows of three
  widths and rows opened by a glyph that overhangs to the left, and read where each
  row's ink starts against the widest row; the second fails if a row's pen is moved by
  another row's bearing, and, with the overhang on a narrower row above a wider one, if
  the rows are set within the block's width (which that overhang stretches) and not
  within the widest row's. `.TheBoxesOfTheFallbackAreSetByTheRuleTheGlyphsAre` puts the
  boxes drawn where no font opens through the same rule. At the scene,
  `.AlignmentOffsetsTheQuadAndNeverTheNode` requires the nine layers' nodes to stay at
  the authored origin, scale and turn with their quad off it by the layout's offset, in
  the layer's own axes, `.ChildrenOfAlignedTextStayOnTheParentsOrigin` that a child of a
  scaled and turned text sits at its own place in the parent's space,
  `.ChangingTheAlignmentMovesTheQuadWithoutResizingIt` that a script's write of
  `horizontalalign` moves the quad on the next layout and not the node,
  `.ScriptsCannotSetAnAlignmentOnATextLayer` that `alignment` is no property of a text
  layer, and `ScriptMadeText.ALayerMadeByAScriptSitsAgainstItsOriginAccordingToItsAlignment` that a
  layer a script makes is placed like a scene's own. The cursor is over the card where
  it hangs: `MouseInput.ATextLayersHitBoxIsItsCardWhereItIsDrawn` (a left- and
  top-aligned, scaled and turned card, on each side of the origin) and
  `.ACoverageMaskIsReadAcrossTheCardWhereItHangs`. `MetalSceneDraw.AnAlignedTextLayersBlockEdgeSitsOnItsOrigin` draws an H
  for each of the nine alignments, plain and with an effect, and requires the ink's
  right edge on the origin (within three pixels, because the probe frames put it up to
  three units inside) and the baseline where the reference line puts it;
  and
  `.EnablingAnEffectDoesNotMoveAnAlignedTextLayer` that padding moves
  nothing.
- **Opaque background** — `opaquebackground` fills the card's rectangle, and not the room a style
  needs around it, with `backgroundcolor` times `backgroundbrightness` at the layer's alpha, the
  brightness only in the HDR pipeline.
  `MetalSceneDraw.AnOpaqueBackgroundFillsTheCardAtTheLayersAlpha` draws a caption
  in each quadrant of a four-coloured backdrop and requires the quadrant's colour mixed towards the
  plate by the alpha at every corner of the card and the backdrop untouched just outside it, with
  the stem of the glyph over the fill when the card is drawn directly and blended into the cleared
  composite when it goes through an effect (the expectations come from the blend equations and
  `kTextCompositeAlphaExponent`); `.AnOpaqueBackgroundFillsTheCardAndNotTheRoomAStyleNeedsAroundIt`
  gives the text an outline and a shadow and requires the fill to stop at the card; both fail with
  the fill off. `TextObjectRuntime.AnOpaqueBackgroundsColourBrightnessAndInsetReachTheCardsMaterial`
  requires the colour, the brightness in each pipeline (and a bound one following its property), no
  constant at all on a card without a background, and the card's inset in its raster following a
  relayout (`g_CardInset`, a `DynamicValue` the text effect gate holds). The fill is one pass with the
  glyphs, the glyph over the fill as the two quads one after the other, or the composite cleared to
  the fill; for the colour blend "add" that is the two added as one value, which differs from adding
  them where they overlap.
- **Text composite and live padding** — a text layer that draws through a visible effect
  is drawn through a composite of its own, as Wallpaper Engine draws it: the card starts as
  the scene behind it with no alpha, the glyphs are blended into it by their alpha on
  colour and on alpha alike, the effects run on that, and the last pass goes onto the scene
  by the alpha the card holds. Black text of alpha `a` over a background therefore stands at
  `a` cubed of the way to black through an `opacity` chain, where the same text with no
  effect stands at `a`; in the probe scene `probetext4` (DIN Engschrift and Baqacents,
  `Alpha`, through the `opacity` effect) Wallpaper Engine's stems are at 0.275 and 0.125 for
  alpha 0.65 and 0.5 and so are ours (1.000, 0.651 and 0.498 without the effect, in both),
  and the ink of its strokes is within 0.6 percent of Wallpaper Engine's where it was 2.5 to
  4.2 times it. The clock of 3819684521 (black, alpha 0.73, one `opacity` effect over white)
  draws its interior at (162, 161, 157) where Wallpaper Engine has (164, 162, 158) and the
  old single alpha gave (75, 74, 70), and the `blurprecise` heading of the same scene (alpha
  1) has 99.7 percent of Wallpaper Engine's ink where it had 152. The card does the seeding
  and the glyph blend in its own pass, not in two, because it covers the whole composite:
  it samples the scene (`_rt_default`) at the screen position of each fragment through
  `g_EffectModelViewProjectionMatrix`, the matrix of the scene camera over the layer's own
  transform, and writes `mix(scene, glyph, alpha)` with the alpha raised to
  `kTextCompositeAlphaExponent` (2; declared in `WPSceneParser.hpp` with
  `TextCompositeReach`, the share of the colour that lands, which every test derives its
  expectation from, so a different measurement changes that one line). A composite is only
  for a layer whose effects the glyphs go through: with every effect off the layer is plain
  text (the card's `g_Composite` is 0, which a script that switches an effect moves with
  it), and a layer with a colour blend keeps the single alpha it had, since how the blend's
  passthrough treats a seeded card is not known. The chain's effects and the passthrough
  that ends it while a script has every effect off take a white `g_Color4`: the card carries
  the layer's colour and alpha, and an unbound `g_Color4` is zero, which made Wallpaper
  Engine's own `effectpassthrough` (the `genericimage3` shader, the card times `g_Color4`)
  draw nothing, so a text layer whose scripted effects were all off was invisible with the
  shipped assets. Colour blend mode 31 ("add") draws a text layer without a running effect
  additively, so the passthrough of that state is drawn additively
  (`SceneImageEffectLayer::SetIdleFinalBlend`), and the last pass is translucent while an
  effect runs, as Wallpaper Engine forces it. An effect with no pass counts for neither the
  margin, the composite nor the fallback (`EffectCountsForText`: one predicate for the
  load-time padding, the composite's start and the runtime's count). `text_object_runtime_test`
  and `metal_scene_draw_smoke`:
  `MetalSceneDraw.AnEffectsTextIsComposedOverTheSceneBehindItAsWallpaperEngineDoes`
  draws black captions of alpha 1, 0.65 and 0.5, with and without an effect, over a backdrop of
  four flat colours and requires `1 - a` and `1 - TextCompositeReach(a)` of each colour (so the seed is the scene behind the card, the right way up and the right
  way round); `.ATurnedAndScaledEffectsTextIsComposedOverTheSceneBehindIt`
  does it for a stem turned and scaled about the point the four colours meet and requires no
  quadrant's colour in the channels another's lacks;
  `.AnEffectsTextIsComposedOverTheSceneInTheHdrPipeline` repeats the first in
  the 16-bit HDR pipeline; `.ATextLayerWhoseEffectsAreAllOffKeepsItsSingleAlpha`
  requires the picture of a layer whose only effect is off to be that of one with none;
  `.ATextLayersCompositeFollowsItsScriptedEffects` switches the one effect on
  from 0.5 s to 1 s and requires single alpha, composed alpha, single alpha, with the ink in
  the same place in all three (the margin comes and goes with the effect, the ink does not
  move), through a passthrough stand-in that multiplies by `g_Color4` as `genericimage3` does,
  so a layer that binds none is caught; `.AnAddLayersTextIsAddedWhileItsScriptedEffectsAreOffAndComposedWhileOneIsOn`
  is the same for mode 31 (green over red adds to (255, 128, 0), then mixes);
  `.ATextLayerThroughShippedEffectsIsDrawnWhetherItsScriptHasThemOnOrOff` is the
  scripted case with Wallpaper Engine's own `opacity` effect and `effectpassthrough` and skips
  without the shipped assets. `TextObjectRuntime.ACardKeepsItsPaddingOnlyWhileAnEffectPassIsVisible`
  is the padding's half: Wallpaper Engine counts the visible effect passes again whenever an
  effect's visibility changes, so the card of a text layer whose scripted effect starts off
  has no margin as it loads, gains it while the script has the effect on and loses it again, a
  layer whose scripted effect starts on is padded as it loads, and one with another effect that
  is always on keeps its margin through every switch;
  `.AnEffectWithNoPassCountsForNeitherTheMarginNorTheComposite` that an effect with no pass
  does none of it and leaves no layout to redo as the scene loads; and
  `.OnlyATextThroughVisibleEffectsReadsTheSceneForItsCompositeAndOnlyOnce` that the seed is
  one pass and only for a layer that has a visible effect. The drawn checks are
  `metal_scene_draw_smoke` cases, not a `check_renderer.py` case. Two tests
  encoded the single alpha and were migrated:
  `MetalSceneDraw.TextStylingChangesPixelsWithoutRerasterizingGlyphs` expects the composed
  alpha (32 of 255 at alpha 0.5) from the layer that draws through an effect, and
  `TextObjectRuntime.AddColorBlendTextIsDrawnAdditivelyOntoTheSceneUnlessItGoesThroughEffects`
  (renamed) expects the chain of an "add" layer with an effect to end in a translucent draw,
  with the card's own pass the one that samples the screen. Not established, and the one
  measurement against the cube: whether an effect that leaves alpha alone (a skew, a
  transform) also gives `a` cubed. The white VHS timestamp of 3465215190 (alpha 0.65, `skew`
  and `pulse`) has its strongest pixels 0.41 of the way from the background to white in
  Wallpaper Engine's frame, and the black one over it (alpha 0.63, `skew`) 0.40: `a` squared
  (0.42 and 0.40), where this composite gives 0.28, `a` cubed, and the single alpha it
  replaced 0.68; the card is minified and turned the same way in every frame, so the ratio is the
  exponent. A model that fits every measurement made so far is a glyph pass that keeps the
  single alpha (`kTextCompositeAlphaExponent` 1, `a` squared for any chain) and an `opacity`
  effect that takes the layer's alpha for its own `alpha` whatever its constant says (the
  third factor of probetext4, whose effect has `alpha` 1). That is a rule about effect passes
  that this change does not make, so the choice stays open; the capture that settles it is
  described under Known limitations in [renderer verification](renderer.md#known-limitations).
- **Text effect buffers are the card** — `text_object_runtime_test`. The buffers an effect
  chain on a text layer draws into are the layer's card with the fraction cut off, at least
  4 texels, as Wallpaper Engine builds them, so the chain's `v_TexCoord` runs 0 to 1 across
  the card. `TextObjectRuntime.EffectTargetIsTheCardNotACapacity` parses seven layers (centred,
  left and top, right and bottom, padded, with an authored `size` of 800 by 400, with a
  card of fraction .6, and with no text), each with a one-pass effect and with one that draws through a
  buffer of its own, and requires the first buffer, the camera and the final card to be
  the width and height of the card the layout measured, cut off and not rounded, centred
  where the alignment hangs the card, with texture coordinates exactly 0 to 1 on the
  final card and on the node the graph resolves it onto. None of them is a capacity, as
  they were (twice the canvas or four times the authored `size`, at most 4096).
  `.ACardThatChangesInTexelsResizesTheBuffersOncePerTextChangeAndRebuildsNothing` makes a text
  longer and requires every buffer sized from the first to follow, the targets to be asked to
  resize once (`ConsumeRenderTargetResizeFlag`) and the graph never (`ConsumeSceneGraphMutationFlag`),
  and neither again over thirty frames that change nothing, then makes it short again and
  requires the same of the smaller card; a card under 4 texels (no text) gets 4 by 4
  buffers and a final card that is exactly them (the `empty` variant above);
  `.ACardThatGrowsWithinATexelKeepsItsBuffers` and
  `.AnEffectChainFollowsTheCardWhenTheAlignmentMovesIt` are the other side: a card that
  changes by a fraction or only moves costs the graph nothing.
  `.RuntimeTextEffectTargetsResizeWithTextRasterSize`,
  `.ParserTextEffectFinalUvsAreTheWholeCutOffBuffer`,
  `.SceneScriptTextEffectMutationKeepsFinalUvsOnTheWholeBuffer` and the two
  `.AlignedTextEffect...` tests follow the same rule through the parser, a relayout, a
  script and the alignment. They are now `TextEffectChain.TheChainFollowsACardThatGrows`,
  `.AFractionalCardIsCutOffNeverRounded`, `.AScriptSetTextKeepsTheFinalCardWhole`,
  `.ARightBottomTextWithAnEffectFollowsTheMeasuredRenderFrame` and
  `.AStaticAlignedTextWithAnEffectCoversItsRasterWithoutScaling` in `text_object_behavior_test`.
  `.ACardPastTheBufferLimitIsCutOffToIt` there (formerly `.OversizedTextEffectClipsFinalMeshToBoundedTarget`) keeps the
  one clamp that is left: a card past 4096 texels on a side, which Wallpaper Engine has no
  limit for, is drawn into buffers cut to 4096. `MetalSceneDraw.AnEffectsUvOffsetIsAFractionOfTheCard` puts a layer
  through an effect that reads its input 0.25 along, across and down, and requires the text
  to move by a quarter of the card's width, and up by a quarter of its height (`v` runs
  from the top), within 1.5 pixels; with buffers sized from the canvas the
  text moved by a quarter of those and left the picture. In a probe scene (`HHH` in
  DIN Engschrift 48 with a padding of 200 through the `transform` effect at offset
  0.25 0, in boxes of 400 by 160 and of 1400 by 700) the text stands 162 canvas units left
  of its unaffected twin for a card 646 units wide, in both boxes (our render of the probe; no
  frame of Wallpaper Engine's has been compared for it, so it shows the buffers are the card, not that
  Wallpaper Engine moves the text by that much). A real clock (a
  left-aligned, padded layer through a skew effect) that stood 22 pixels right of
  Wallpaper Engine's, in a 3456-pixel frame, is within one.
- **A text card that changes size resizes the targets and builds no graph** —
  `MetalSceneDraw.ATextCardThatChangesSizeResizesTheTargetsAndDrawsWhatARebuildDraws` in
  `metal_scene_draw_smoke`. A caption through a two-pass effect that reads its input's size
  (`g_Texture0Resolution`, so a size that was not followed shows in every texel) is made longer,
  shorter, longer and back, each edit another size in texels, and drawn twice: once as the host does
  (`ResizeRenderTargets` under the graph it has) and once building the graph again for each change
  (`RebuildWatch::resize_as_rebuild`, the same as `WE_TEST_RESIZE_AS_REBUILD`). The two final pictures
  must be byte for byte the same, the first run must rebuild only what the second rebuilt beyond its
  resizes, and it must have resized at least once per edit. With the target sizes of the
  lowered passes not refreshed (the loop over `descriptions` in `resizeTargets` left out) the pictures differ.
  `.ATextCardThatChangesSizeNeitherRebuildsTheGraphNorTouchesAVideo` is what that is for: a caption beside
  a playing video changes width and the graph is not built again, the decoder is the one that was playing
  and no media file is opened or closed; it fails when a resize asks for a rebuild
  (`WE_TEST_RESIZE_AS_REBUILD=1`). A scene whose text changed width every few draws
  (a perspective scene of seven puppets and 17 text layers, whose readouts are laid out again every few
  draws) built the graph 41 times in 180 draws, 2.2 s of compile in all (about 54 ms each), which decoded and uploaded its
  textures and copied a 54 MB and a 201 MB vertex buffer each time, and drew at 19 frames a second
  at 44 ms of CPU a frame; it now resizes 38 or 39 times in 30 to 32 ms (about 0.8 ms each; 42 render passes a
  frame) and draws at 60 frames a second at 4.5 ms. The resize and rebuild times are the `N graph rebuild(s),
  M target resize(s) ... ms wall in all` line of `metal_scene_draw_smoke` on scene 3589454154, `WE_TEST_METAL_FRAMES=180`,
  `WE_TEST_SETTLE_TEXT=1`, `WE_TEST_RANDOM_SEED=1`, three runs each way (the rebuilds with `WE_TEST_RESIZE_AS_REBUILD=1`:
  41 or 42 in 2.22, 2.23 and 2.28 s; the resizes 29.7, 31.6 and 32.0 ms); the other figures of this sentence are from the
  run that found it and were not repeated. The
  `metal_scene_draw_smoke` local run prints both counts and what asked
  (`N graph rebuild(s), M target resize(s) ...`).
- **A video stays open and on its frame when the render graph is built again under it** —
  `MetalSceneDraw.AVideoStaysOpenAndOnItsFrameWhenTheGraphIsBuiltAgainUnderIt`
  in `metal_scene_draw_smoke`. A 20 second 640 by 360 clip in one group of
  pictures (the long clip of `synthetic_video.hpp`: one keyframe, and a bar that crosses the
  picture once, so the column of the bar tells the frame) plays under a caption that draws
  through an effect. A seek to 12 s decodes 360 frames, which takes 0.4 s and many draws. The
  video clock is set to 12 s at the third draw and the scene is drawn at the pace of that clock,
  every draw captured as a poster, until the picture shows the clock's frame (within two frames
  of thirty a second). The wait is for the picture and not for a number of draws, so a machine
  that is slow to seek only takes longer, and a run that never gets there (900 draws) fails
  naming the frame it was on. Then the caption becomes a longer text and the graph is built
  again at that draw (`RebuildWatch::force_at`: a text card no longer asks for it). The picture is the draw that
  follows the rebuild and must show the clip's frame for the clock (within four frames), and the
  renderer's work counters must name the same decoder before and after
  (`OWE_RC_VIDEO_SOURCE_INSTANCE`, with one source open). With the keeping switched off for the
  run it fails: the picture is the clip's frame 0 with the clock at frame 365,
  and the decoder is another one (3 then 4 on Native Metal).
  `.AVideoTheRebuiltGraphLeavesOutIsClosed` is the other half: a property hides
  the video layer in the tick the graph is built again in, so it leaves the layer
  out (a layer hidden by a property nothing else writes is left out; one that `SetNodeVisible`
  hides keeps its passes) and nothing in it binds the video that was playing. The decoder was
  kept for the new graph and not taken back, so it must be closed with the compile: the number
  of `.mp4` files the process holds open (a decoder holds its file for as long as it lives) is
  back to what it was before the scene, and fails with the closing of what was
  kept taken out of either compile. It passes with the keeping switched off, being the other
  side of the one above.
  `.AVideoStaysOpenWhenARenderScaleChangeCompilesTheGraphAgainOnNativeMetal` applies a render
  scale of one half to a Native Metal renderer that is drawing the video, through
  `ApplyRenderScale` (the raster halves, so the graph was compiled again), and requires the same
  decoder before and after; it fails with the `hold()` in `ApplyRenderScale` taken out (the
  decoder is another one). `.AVideoSetAsideForACompileThatIsRefusedIsClosedOnNativeMetal`
  releases the surface of a renderer that has drawn the video, clears its graph for a rebuild
  and has the compile refused (a renderer with no surface compiles nothing): the `.mp4` files
  the process holds open must be back to what they were before the scene, which fails with the
  close in the refused compile taken out.   Real wallpaper 3326873240 (Native Metal, 3456 by 2024 display size, real time, five packaged
  4K videos, a clock under an effect;
  `WE_TEST_COMPARE_REBUILD_AT=200 WE_TEST_COMPARE_STOP_AFTER_REBUILD=3`): the rebuild opens no
  video and takes 0.05 s, where with the videos closed as before it opens all five and takes 1.4
  s (1.2 to 3.4 s depending on the load); the picture three draws later is the picture of a run
  that did not rebuild, pixel for pixel outside the box of the clock's digits, in both builds
  (the seek of the first video opened lands while the later ones are still opening, so the head
  of the clip is not seen on this wallpaper, only the wait is). With the local clock set so that
  the minute turns over during the run (a fixed POSIX `TZ` offset, seconds included, that puts
  the turn twelve seconds into the run), the clock caused the rebuild itself in some runs and
  not in others: at draw 381 with the keeping (0.05 s, no video opened) and at draw 630 with the
  videos closed (1.3 s, all five opened again), the pictures again equal to a run that did not
  rebuild outside the clock's box.
- **Alignment words and brightness** — `text_object_runtime_test`.
  `TextObjectRuntime.AlignmentKeysAreReadAsTheEnumRegistryReadsThem` parses a scene
  with every shape of the two keys (absent, each word, wrong case, empty, a longer
  word, a number, `null`, an object) and `.AlignmentWordsParseLikeTheEnumRegistry`
  checks the two parse functions on their own: exact words, `left` for any other
  horizontal value and `center` for any other vertical one, and no `alignment` key
  (`TextParseScene.AStrayAlignmentKeyDoesNotPlaceTextAcrossTheOrigin` and `...AboveTheOrigin` in
  `text_object_behavior_test`).
  `ScriptMadeText.TextAlignmentWordsAreTheLowerCaseOnesOrTheDefault` (`scene_schema_part08_test`)
  makes a layer with an `alignment` and a wrong-case word and gets a centred one.
  `TextObjectRuntime.TextBrightnessAppliesOnlyInTheHdrPipeline` reads the material's brightness in a
  plain scene, one with `hdr` and no `bloom`, and one with both (brightness 0, 2.39, a
  user-bound one that follows its property), and
  `.ABrightnessScriptStillRunsWhereBrightnessDoesNothing` keeps a brightness script
  running where it draws nothing. `MetalSceneDraw.ATextLayersBrightnessDoesNothingOutsideTheHdrPipeline`
  draws white text at brightness 0, 2.39 and 1, and with every effect off, and gets the
  same picture, and
  `.ATextLayersBrightnessReachesTheHdrPipeline` draws nothing at
  brightness 0 in an HDR scene.
- **Text colour blend and screen anchor** —
  `TextObjectRuntime.ColorBlendModeMixesTextWithTheScreenThroughThePassthroughPass`
  and `.AddColorBlendTextIsDrawnAdditivelyOntoTheSceneUnlessItGoesThroughEffects` (CPU, in the gate) and
  `MetalSceneDraw.ATextLayersColourBlendModeAppliesItsColourAndAlphaOnce`,
  which draws white text at half alpha over green: mode 2 mixes
  half of white once (128, 159, 128), mode 31 adds half of it (128, 191, 128), and
  the pictures are identical. `.ScreenAnchorOffsetsPinTheLayerToTheEdgeItNames`
  tabulates the nine anchors against the presented margins, and
  `.ScreenAnchoredTextFollowsThePresentedAreaAndNothingElseDoes` moves the draw of
  anchored layers with `SetCursorViewport` (a pan, a display that shows more than the
  canvas, and back) while layers with `none`, no key, or only the key keep their
  place: the `anchor` key is never a pivot. The shift is the node's draw offset
  (`SceneNode::SetDrawOffset`, carried by `RenderTrans` and by the final card of an
  effect chain) and not its translate, so `.ScreenAnchorDoesNotMoveTheChildrenOfTheLayer`
  keeps the layers parented to it on its origin,
  `.ScreenAnchorIsAWorldTranslationWhateverTheLayerScaleAndTurn` shifts a scaled and
  turned layer by the margins in the scene's axes,
  `.AScreenAnchoredLayersOriginReadsBackAsTheSceneGaveIt` reads an origin, adds to it
  twice and writes it back without the layer walking by the margin, and
  `.ScreenAnchorMovesTheFinalCardOfALayerWithAnEffectChain` moves the card an effect
  chain draws as well. `DrawOffset.AnOffsetLeavesBothModelMatricesAlone`,
  `.TheOffsetIsAPlainWorldTranslationOnTheRenderMatrix` and
  `.AnOverrideBeatsTheOffsetAndClearingOrZeroingRestores` (`scene_schema_part03_test`)
  pin the node rule (an override is not moved by it),
  `MouseInput.ACursorHitFollowsAScreenAnchoredCard` the cursor over the card where it is
  drawn, `MetalProjection.TheLayerPlaneIsWhereTheLayerIsDrawn` the perspective hit
  plane, and `MetalSceneDraw.AScreenAnchoredTextLayerIsDrawnWhereItsAnchorPutsIt`
  the picture, with and without an effect chain: 40 columns in
  for a display that shows 344 of 384.
- **Outline, blur and drop shadow** — `TextObjectRuntime.OutlineGrowsTheGlyphByItsThicknessInPixels`,
  `.OutlineThicknessIsCappedWithTheGlyphAtlasAndNeverBelowOnePixel`,
  `.BlurSoftensEdgesOverItsSizeAndKeepsTheGlyphWhereItIs`,
  `.DropShadowFollowsItsOffsetAndOpacityAndOutlineWidth`,
  `.StyledTextCardGrowsOutwardAndKeepsTheLayoutBoxWhereItWas`,
  `.ParserReadsTheFontShaderStyleAndPicksTheStyledShader`,
  `.StyledTextCardCoversTheStyleWhenTheLayerIsParsed` and
  `.StyleColoursFollowTheirPropertiesAndTheBakedKeysAreReadOnceAndHeld`, and
  `MetalSceneDraw.StyledTextIsDrawnWithItsOutlineAndShadowByTheNativeBackend` and
  `.StyledTextWithoutAnOutlineKeepsTheLayersColourAtItsEdges`.
  The raster of a styled layer holds three coverage masks (red the glyph, green the
  glyph and its outline, blue the shadow with its opacity), so the glyph takes the
  layer's colour and the outline and shadow keep theirs; the first Metal test requires
  green outline and magenta shadow pixels around white glyphs (Native Metal only), and
  the second, draws red text blurred, and shadowed in red, over
  white: every pixel is red mixed with white, so its red channel must stay full,
  which it does not when an outline colour the layer never asked for is mixed in at
  the partly covered pixels (the shader takes the outline colour into the glyph only
  for a layer with an outline, as the reference's path without `OUTLINE_ENABLED`
  does). The property test binds the outline and shadow colours, which follow their
  property live, and the switches, sizes and opacity, which are read once at load with
  the user's value, noted load-only and held by a preview. Sizes are pixels of the
  finished text, capped in the shader's atlas units (outline 5.1, blur and shadow 6),
  and the tests state them as distances from the unstyled glyph box.
- **Text edges take the glyph's colour** —
  `TextObjectRuntime.EveryTexelOfRasterizedTextCarriesTheTextsColourWhateverItsCoverage`,
  `.StyledTextLeavesEveryTexelOutsideItsMasksClear` and
  `MetalSceneDraw.AMagnifiedTextsEdgesFadeToItsColourNotToBlack`.
  The card's texture is straight alpha sampled linearly, so a layer scaled up past
  its raster (a small pixel font enlarged) reads edges between a glyph texel and a clear
  one; the clear texels hold the text's colour (white in the runtime's neutral cache),
  not black, or the colour dims toward black along with the alpha and a dark ring runs
  round every stroke. The first test requires the colour in every texel of a plain
  raster whatever its alpha; the second requires a styled raster, whose channels are
  coverage masks, to keep its texels outside the masks fully clear. The Metal test draws
  red text over white at three pixels a texel, plain and through an effect chain, on both
  renderers: every pixel is red mixed with white, so its red channel must stay full, and
  the plain card draws over a thousand pixels darker than that without the colour in the
  clear texels. It also requires an edge ramp three pixels wide or more along a row, which
  text drawn at the size of its raster does not have, so the test cannot pass by not
  magnifying the text. Through the chain the card is drawn into a composite of about its own
  size and the scene behind seeds it, so that variant guards the composite and was never
  dark. A text with a colour blend writes the card without blending, and the passthrough's
  Darker Color (5) and Lighter Color (10) take the min and max of the screen and the card's
  colour with no alpha, so the colour in the clear texels reaches the screen there:
  `MetalSceneDraw.ATextLayersColourBlendModesDrawItsTextAndNoBox` draws
  orange text on navy through modes 10, 5, 2, 0 and 6, with the fixture's
  passthrough written as `ApplyBlending` is for 5 and 10, and
  `.ATextLayersColourBlendModesDrawItsTextAndNoBoxThroughTheShippedPassthrough` does the
  same through Wallpaper Engine's own `effectpassthrough` (skipped without the shipped
  assets). Every mode must draw its glyphs in the blended colour and change no more pixels
  than the unblended text does (a box over the card changed 40592 against 5029 before the
  card's rest colour), and text enlarged three to one in modes 10 and 5 must fade over the
  edge pixels without going past the scene or the text. The other paths that sample the
  card between texels or write it without blending (a chain whose buffer differs from the
  raster, the direct draw while every effect is off) have no test of their own; every
  blend there weighs the card by its alpha, so the colour of a clear texel does not reach
  the screen.
- **Cache metadata and corruption** — `render_target_lifetime_test`,
  `text_object_runtime_test` and `shader_program_cache_behavior_test` cover clock/text
  corruption, persistent shader-cache metadata, cache invalidation after include
  edits, corrupt-cache recovery, parent-aware compose-background sampling, and
  SceneScript AM/PM sprite-frame selection. They create no window and no GPU
  device.
- **Clocks** — `ShaderValueUpdaterCompat.DayTimeUniformFollowsLocalClockAndWrapsAtMidnight`
  injects a wall clock and checks `g_Daytime` and the compatible `g_DayTime`
  spelling as the local fraction of a day.
  `ScriptRuntimeCompat.EngineTimeOfDayFollowsTheLocalClock` checks that
  SceneScript's `engine.timeOfDay` is the same fraction (`Utils/TimeOfDay.hpp`
  serves both). It is a getter that reads the clock only when a script asks.
  While it was missing, scripts that blend day and night layers by the hour
  computed `NaN` and drew the layer black.
- **Text a script writes** — `text_object_runtime_test`.
  `TextObjectRuntime.ScriptTextWrittenInUpdateIsKeptWhenUpdateReturnsNothing` is a
  text script that writes `thisLayer.text` only when its string changes and returns
  nothing: three ticks later the layer shows the string, not the scene file's
  placeholder (the bound value, republished by the undefined return, used to be put
  back over the write on the same tick). `.ScriptReadsTheTextItWroteOnTheNextUpdate`
  steps through two writes, each reached only when the previous one became the
  `value` the next `update(value)` is given, and
  `.ScriptReturnValueStillReplacesTextTheScriptWrote` keeps a returned string
  winning over a write. Those three are the owning script's own writes; only the
  first is compared with a Wallpaper Engine frame (a 12-hour clock), the other two
  pin the same rule's edges. `.TextWrittenByAnotherScriptDoesNotReplaceWhatTheTextScriptReturns`
  and `.TextScriptWritingAnotherLayersTextKeepsItsOwnValue` pin what was not
  changed: a visibility script or another layer's script writing a layer whose text
  script returns a value, and a text script writing another layer's text, leave the
  text property's own value on screen, while a text nothing is bound to takes what
  is written. The first is the shape of a media widget's title layer whose frame
  shows the text script's empty value; which script Wallpaper Engine lets win in
  general is not established, so these two are chosen, not evidenced. An earlier form
  of this change made every script's write the property's value, and the widget
  drew the sound layer's name where Wallpaper Engine draws nothing.
- **Raster caches and revisions** — text raster caches hold neutral glyph
  coverage. Color and alpha bindings reach uniforms, including text
  under effects, without relayout or uploads
  (`MetalSceneDraw.TextStylingChangesPixelsWithoutRerasterizingGlyphs`); a
  brightness binding does too, but only in the HDR pipeline, where it is read at all
  (`TextObjectRuntime.TextBrightnessAppliesOnlyInTheHdrPipeline`). Text
  scripts first run on the normal ordered tick, not while objects are still being
  parsed. The layout queue is FIFO and coalesces updates in place;
  `TextObjectRuntime.AWaitingClockIsNotStarvedByNewerReadoutUpdates` blocks the
  worker deterministically to verify that newer readouts cannot overtake a
  waiting clock. Completed glyph images publish in revision order even when a
  newer value is pending, so continuously changing labels never stay blank
  waiting for an exact-current revision; the test compares the published glyph
  pixels before and after catching up. An effect's buffers are the card's size in
  texels, so a change of the text that gives the card another size requests one graph
  rebuild (see "Text effect buffers are the card").
- **Text layers on the native backend** — `MetalSceneDraw.ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend`:
  a parsed text object, the text program translated to Metal, the rasterised
  glyphs imported and the card drawn into the scene's own target. A text layer
  must reach the backend through the ordinary parser, not through a hand-built
  mesh.
- **Unchanged text costs nothing** — `MetalSceneDraw.TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`:
  twelve frames of an unchanged string measure nothing and upload nothing, a new
  string costs at most one upload per in-flight frame and reaches the drawn
  picture, and it then goes quiet again. The script keeps running throughout;
  "quiet" must never be achieved by stopping it.
- **Text layers under an effect chain** — `MetalSceneDraw.ATextLayerWithAnEffectChainKeepsBothOfItsCards`:
  a text layer with effects has three meshes the relayout rewrites — its own
  card, the chain's final card and the node the chain resolves its last pass onto
  — and all of them have to be accepted and updated, or the scene falls back as a
  whole or freezes at its first layout. Use text whose glyphs differ from the first
  text, so that a relayout that never reached the chain is a picture that did not
  change.
- **Headless run of a script-driven text scene** — `TextClockScene.ASynthesisedClockSceneRunsHeadlessWithoutScriptErrors`
  in `text_object_behavior_test`. A clock-like scene built in memory (a time text driven by a script, two
  children, user-bound origin, scale and visibility) is parsed, ticked three frames and turned into a render
  graph; it needs no local package and no environment variable, and requires no script error and the text
  each layer should hold. The earlier diagnostic that loaded a real package from environment variables is gone.

## Animation and puppets

- **Non-additive layer weights** — `PuppetPose.NonAdditiveLayersShareOneUnitOfPoseWeight`
  (normalized and partial weights, rotation, scale, loop wrap, repeated samples)
  and `.DistinctMotionMixesAndAdditiveOffsetsRideOnTop` (distinct
  animations, additive overlays, live blend/visibility changes) in
  `puppet_pose_tests`. Non-additive puppet animation layers use their effective
  blend weights for the entire pose (translation, scale and rotation), including
  offsets from the reference pose; otherwise overlapping layers double
  character-sheet assembly offsets and separate attached pieces. Additive layers
  keep their authored weights. The prepared weights are reused: no per-frame work
  or GPU resources are added.
- **Puppet lighting** — `MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly`
  covers all eight combinations of puppet/card, effects/direct and lit/unlit over
  repeated draws. Puppet layers with effects light their assembled geometry only
  in the final skinned pass; the input texture-sheet pass is unlit, so lighting
  is neither multiplied twice nor baked into the separate cut-out pieces.
  Unskinned layers, effect-free puppets and unlit materials keep their lighting
  paths.
- **Colour blend modes** — `MetalSceneDraw.AColorBlendLayersColourAndAlphaApplyOnce`
  draws a tinted, half-transparent layer through a stand-in passthrough over a
  coloured background: the tint and alpha are taken once, by the layer's own
  pass. `MetalSceneDraw.AnAddColorBlendLayerIsAddedOntoTheScene`
  requires mode 31 to add the layer at its alpha, and
  `RenderGraph.addColorBlendLayersAddOntoTheSceneWithoutSamplingIt` that a mode 31
  layer, with and without an effect, draws additively onto the scene with no
  passthrough, no screen copy and no pass sampling the screen.
- **Scripted effect visibility** — `MetalSceneDraw.AnEffectAScriptSwitchesIsFollowedWhileTheSceneRuns`
  switches an effect on and off again with a script, ahead of an effect that is
  always on: the picture must follow each switch, and the later effect must read
  the buffer the effect before it wrote, so the chain is resolved again from its
  placeholders. `MetalSceneDraw.ALayerWhoseEffectsAScriptHasAllSwitchedOffIsStillDrawn`
  switches a layer's only effect off: the passthrough at the end of the chain
  must still draw the layer, inside its bounds.
- **Particle emitter origin** — `EmitterOrigin.AnEmitterOriginScalesWithItsLayerUnlessTheParticleFileIsWorldSpace`
  (`scene_schema_part07_test`) parses a still emitter at a local offset under a layer scaled by two and reads
  where it is drawn: a layer-space file's offset is scaled by the model matrix,
  and a `worldspace` file's is the world offset.
- **Worldspace particle files** — a `worldspace` system is in scene units from its
  layer's origin and is drawn through that origin alone.
  `ParticleBillboardSize.WorldSpaceBillboardKeepsItsAuthoredSizeWhateverTheLayerDoes`
  (`particle_billboard_size_test`) draws one billboard under a layer scaled 0.25, 24 by 1 and flipped, and turned,
  and requires the authored size and an identity draw matrix apart from the origin;
  `ParticleControlPoints.WorldSpaceMatrixStretchesPlacementAndHeadingButNotSpeed`
  (`particle_control_point_test`) gives the emitter a layer matrix and requires the spawn offset and the heading
  stretched, the origin not, and the speed as authored;
  `ParticleMouseControlpoint.AWorldspaceLayersMatrixScalesTheVelocityInitializersDraw`
  requires a `velocityrandom` velocity scaled by that matrix in a worldspace system
  and left alone in a layer-space one;
  `StretchedLayer.SpawnOffsetsStretchAndSpeedStretchesOnlyInLayerSpace`
  (`scene_schema_part07_test`) parses a layer 24 times wider than tall and compares the drawn first step of a
  layer-space file (about 17 times the authored length, the speed stretched with the
  layer) with a `worldspace` one (the authored length);
  `ParticleMouseControlpoint.AWorldspaceSystemsControlpointsAreWhereItsLayersMatrixPutsThem`
  turns and scales a layer and requires an authored control point offset to be the
  layer's matrix applied to it, a cursor-linked one the cursor less the layer's origin,
  and one pinned to the world (never the first) the scene place less the origin with
  none of the layer's matrix; `ParticleMouseControlpoint.AWorldspaceEmitterOnAPinnedControlpointIsNotStretchedByItsLayer`
  requires an emitter on such a control point to spread and launch its particles as
  authored, and one on an ordinary control point to follow the layer;
  `WorldSpace.ARotatingOrScalingLayerLeavesLiveParticlesAndTheirVelocityAlone`,
  `WorldSpace.AFollowerHangsWhereItsLayersMatrixPutsAWorldspaceParentsParticle`,
  `WorldSpace.EveryRendererOfAFileIsDrawnFromItsLayersOriginAloneOrThroughItsWholeMatrix`
  and `WorldSpace.ALayerUnderAScaledGroupIsDrawnFromItsOriginAndSpreadByTheWholeChain`
  (in `particle_parity_test`) keep live particles and velocities as they are when the
  layer turns or is rescaled, hang a follower where the layer's matrix puts the
  parent's particle, give a file's second renderer the same draw matrix as its first,
  and spread the particles of a layer under a scaled group by the group too;
  `Prewarm.AWorldspaceSystemIsPrewarmedAgainstTheMatrixItsLayerEndsUpWith` and
  `Prewarm.AStaticChildIsPrewarmedOnceItsLayerHasJoinedItsGroup` require the particles
  a prewarm spawns to sit where the layer's finished matrix, its groups' included,
  puts them; `Movement.FlagOneGravityOfAWorldspaceSystemNeedsNoTurningByItsLayer`
  requires gravity to be left as written.
- **Particle size override** — `ParticleMouseControlpoint.ASizeOverrideScalesTheBirthSizeAndEverySizeRamp`
  gives a particle born at 40 an override of 1, 2.5 and 0.4 and none to three
  `sizechange` ramps that each hold 0.5: it must come out at 40 times the override times
  (0.5 times the override) for every ramp, so a ramp is scaled by the override too;
  `ParticleMouseControlpoint.EachSizeRampScalesTheRunningSizeByItsOwnValueTimesTheOverride`
  runs the two ramps of a petal preset (0 to 1 over the first 5 percent of the life, 1
  to 0 from 20 percent) through their moments and requires the product of both,
  override included; `ParticleMouseControlpoint.AFileThatIgnoresTheSizeOverrideKeepsItOutOfTheBirthSizeAndEveryRamp`
  and `InstanceOverride.TheSizeOverrideScalesTheBirthSizeAndEachSizeRampUnlessTheFileIgnoresIt`
  (in `particle_parity_test`, through the scene parser) require a file with flag 128 to
  keep the override out of the draw and the ramps, and a file with only the speed flag
  to take it in both; `ParseLevel.TheIgnoreSizeOverrideFlagIsTheOneHundredTwentyEightBitOfTheFilesFlags`
  pins the bit.
- **Particle child system origin** — `ChildOrigin.AChildSystemsOriginScalesWithTheLayerByTheTypeAndFlagsOfTheTwoFiles`
  (`scene_schema_part07_test`) hangs a static and an `eventfollow` child at a local offset under a layer scaled
  by two, with every combination of the parent's and the child file's `worldspace`
  flag: the child's place is scaled with the layer unless the parent is
  `worldspace`, whatever an event child's own flag says. A static child whose own
  file is `worldspace` is the one combination no reference settles, and the test
  holds it at the world offset it had before.
- **Text with every effect off** — `MetalSceneDraw.ATextLayerWhoseEffectsAreAllOffIsDrawnAsPlainText`
  draws a caption whose only effect is off and requires the same lit pixels as the
  caption without effects; it used to draw nothing.
- **Hidden layers scripts reach** — `MetalSceneDraw.AHiddenLayersScriptsStillRun`
  drives an effect from a value a hidden layer's script writes to `shared`, and
  `MetalSceneDraw.AScriptCanShowAHiddenLayerItNames` shows a hidden
  layer another layer's script names: both layers must be built, hidden, though
  nothing draws them at first.
- **`colorBlendMode` on puppets** — `RenderGraph.puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen`
  in `rendergraph_smoke`. A layer's `colorBlendMode` mixes it with the screen
  behind it, so only the pass that draws onto the screen may sample it. On a
  puppet with bones that is the final skinned pass, which takes `BLENDMODE`
  itself; the separate passthrough that cards and mesh-only puppets end with
  would otherwise run before it, over the texture sheet, and paint a shrunken
  copy of the whole wallpaper inside the layer. The passthrough is dropped, not
  added to. The test parses a one-bone puppet and requires the only
  screen-sampling pass to be the one writing the scene.
- **Four-light shaders** — `ShaderValueUpdaterCompat.FourLightColorsRoundTripThroughPackedUniforms`
  in `script_runtime_compat_test`: legacy four-light shaders pack the fourth
  light's RGB into the `w` lanes of three color uniforms; zero through five
  lights, channel order, radius/intensity premultiplication, the four-light limit
  and clearing after lights are removed.
- **`origin.animation`** — `OriginSlide.*`, `TransformTimeline.*`, `OriginOnParent.*` and
  `PausedStart.*` in `scene_schema_part05_test` (aligned images,
  text/groups, absolute/relative keys, loop duration, paused playback,
  seek/replay, completed timelines releasing animation demand),
  `MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen` (pixels
  before, during and after a reveal on direct and effect-chain layers) and the
  `generated-origin-animation` case in `check_renderer.py`, which verifies both
  halves after the intro under pooled and isolated allocation. Authored layer
  `origin.animation` uses one playback clock for its three curves. Relative keys
  offset the authored origin, not the previous tick; unkeyed axes keep their
  values. Scripts and user properties keep precedence, anchors and effect-final
  cards follow the existing transform path, and orthographic shots keep their
  shared origin/zoom clock. Static origins add no tick binding, and held
  animation frames do not re-evaluate curves.
- **`wraploop`** — `ScriptRuntimeCompat.WrapLoopClosesACurveOnItsFirstKeyAtTheTimelinesLength`
  (the curve is cut at the length and closed there on its first key's value, keys past
  the length go but never below two, a flag-less loop still holds its last key),
  `.WrapLoopSeamMirrorsTheFirstKeysHandle` and
  `WrapLoop.WrapLoopReturnsTheCurveToItsFirstKeyByTheEndOfTheLength` in
  `scene_schema_part05_test`. `ResolveScalarAnimation` does it once, so origin, alpha,
  scale, angles, colour, light intensity and shader constants all follow.
- **`scale.animation`, `angles.animation` and `color.animation`** —
  `ScaleAndAnglesTimeline.ReadsLikeAnOriginTimeline` (absolute and
  relative keys, unkeyed axes, a single play ending and releasing animation demand,
  replay by name) and, all in `scene_schema_part05_test`,
  `PausedStart.ATimelineThatStartsPausedShowsItsFirstKeyUntilPlayed`
  (the frame-0 pose from the first frame, found by `FindAnimationByName` as
  `getAnimation` does), `TransformTimeline.ALoopingScaleTimelineHoldsAShortCurveAndLeavesAnUnkeyedAxis`,
  `.OriginAnglesAndScaleKeyedTogetherShareTheRootsClock` (a paused parent holds
  the origin, angles and scale keyed under it, through a two-link `options.parent`
  chain), `BoundTransform.AScaleOrAnglesSettingBoundToAScriptOrAPropertyIgnoresItsTimeline`,
  `AnchoredTransform.AScaleTimelineKeepsALeftAnchoredLayersEdgeInPlace`,
  `ScaleOnParent.ScalingTheParentScalesTheChild` (a group and a drawn parent),
  `TransformTimeline.TextParticleAndLightLayersTakeScaleAndAnglesTimelines`,
  `.AModelLayerTakesScaleAndAnglesTimelines` and
  `.ATextLayersTimelinePlaysOnTheNodeItsChildHangsFrom` (the other
  registration sites of `RegisterNodeTransformSettings`, and a text parent whose child
  stays under it),
  `KeyedLayerColour.TheTimelineTintsTheLayerAndEveryEffectPassAndAPausedOneWaitsForPlay`
  (the layer's material and its effect pass, alpha kept, start-paused colour held),
  `LayerColourPrecedence.AScriptOrAPropertyOwnsTheColourAndHdrBrightnessScalesOnlyTheTint` in
  `scene_schema_part10_test` (script,
  user property and timeline on one colour: a binding is the only writer and registers
  no clock, the timeline plays where there is none, and the HDR brightness multiplies
  whichever applies on the layer's material and its effect pass), and in pixels on both
  renderers `MetalSceneDraw.AnAnimatedScaleAndAnglesTimelineMoveALayer`
  (the card's edge before, during and after a growth and a quarter turn of pi/2 radians, the unit of angles) and
  `.AnAnimatedLayerColourTintsTheLayer` (the colour drawn at the
  playhead's frame, direct and through an effect chain). The origin, scale and
  angles of one layer go through `RegisterNodeTransformSettings`; one
  `NodeVec3Animation` (three curves on one playback) serves all four properties, and a
  colour reaches its materials through `RegisterMaterialColorAnimation`. A static
  setting still allocates no binding.
- **Puppet attachments and poses** — puppet attachments use the animated bone
  affine each frame while preserving the child layer's authored/script
  transform. Character-sheet reference poses are decoded separately from cut-up
  bind geometry so additive and non-additive animations reassemble correctly, and
  puppet animation deltas use the skeleton reference pose, not the first
  animation sample, preserving initially collapsed eyelids and authored
  rotations. Synthetic regressions cover declaration order, animated
  translation/rotation/scale, repeated same-time samples and local edits.
- **Scalar material timelines** preserve paused first keys and authored Bezier
  handles; SceneScript named animation controls drive play, replay, pause, stop,
  seek and rate.

## Shader pipeline

Rust regressions in `Renderer/Shader` (`src/*/tests/` for the preprocessor, the dialect
converter, the legalizer and the pipeline, and `tests/`) cover these paths with synthetic
shader sources; the corpus sweeps skip asset-dependent cases with a printed reason.

- **One declarator per array suffix (`Renderer/Shader`)** — `tests/declarator_lists.rs`:
  in `float color[4], f;` only `color` is an array, for locals, globals, constants,
  constructor and brace initializers and uniform lists (reflection lists every member);
  naga would type `f` as the array and drop the effect. A `for` initializer with an array
  declarator keeps its declarations (they move into a block around the loop); a plain
  `for (int i = 0, j = 1; ...)` list is untouched. Kernels are evaluated on the GPU with
  `WM_SHADER_GPU_PROBES=1`.
- **Integer `clamp`, `min` and `max` stay integer (`Renderer/Shader`)** —
  `tests/integer_clamp_min_max.rs`: an `int`/`ivecN` operand keeps literals integer, so
  `clamp(index, 0, BANDS - 1)` can index an array again (`clamp(7, 0, 5)` selects element
  5); `uint` operands get unsigned literals; a float operand still promotes them.
- **Scalar swizzles (`Renderer/Shader`)** — `tests/scalar_swizzles.rs`: `f.x`, `f.rr`,
  `f.xxx` repeat a scalar of any kind, in any position, after scope resolution, and feed
  the usual width rules; a vector swizzle keeps its mapping. A scalar initialised from a
  vector expression takes the first component of the finished expression (checked with
  reordering consumers on the GPU and with a texture sample reaching `max`/`mix` whole).
  Pipeline revision 2 (see `Renderer/Shader/NOTES.md`, note 122).
- **A `#if` about run-time values is false (`Renderer/Shader`)** —
  `tests/runtime_if_conditions.rs`: `#if g_Texture0Resolution.x < g_Texture0Resolution.y`
  takes its `#else` (or a later `#elif`) with a `Preprocess` diagnostic instead of failing
  the effect; conditions made only of preprocessor tokens evaluate, or are refused, as
  before.

- **Scalar component swizzles** — `legalize_type_coercion::scalar_swizzles_*`
  compiles scalar splats through both backends and checks Naga IR component types,
  widths, vector selection, lexical shadowing and downstream width conversions.
  A scalar's repeated component zero broadcasts; a genuine vector swizzle keeps
  its authored component mapping. Shader pipeline revision 18 invalidates older
  cached programs.
  `scalar_initializer_selects_first_component_of_nested_texture_arithmetic`
  also covers scalar initialization from a sampled vector inside arithmetic and
  component-wise builtins: narrowing selects the completed expression's first
  component, not the sample before its consumers run.

- **Built-in simulation uniforms** —
  `ShaderValueUpdaterCompat.SimulationEffectsSeeFrameTimeCursorTravelAndButtons`
  checks that a shader declaring `g_Frametime`, `g_PointerPositionLast`,
  `g_PointerState` or `g_TextureReductionScale` receives the frame's step, the
  previous frame's cursor, the primary button (held in x and y, z only on the
  frame it went down, as Wallpaper Engine pushes a ripple once per click) and 1,
  and that such a pass counts as following the clock or the cursor. Left at zero,
  Wallpaper Engine's cursor ripple and fluid simulation effects never moved and
  `blend` with `TRANSFORMUV` divided by zero.
  `.EffectModelMatrixAndInverseProjectionMatchTheEffectProjection` checks
  `g_EffectModelMatrix` and `g_EffectModelViewProjectionMatrixInverse` against
  the effect projection, and `.EffectTextureProjectionMapsTheLayerCardOntoTheScreen`
  that `g_EffectTextureProjectionMatrix(Inverse)` maps the layer card onto the
  screen wherever the card is moved, turned or flipped, so a cursor effect lands
  under the cursor on a layer that does not fill the canvas; both also run with a
  screen anchor's draw offset on the layer, which the matrices follow.
- **Trailing commas** — `LenientAssetFiles.StrayCommasInEffectAndMaterialFilesAreTolerated`
  (`scene_schema_part04_test`) loads an effect and material whose arrays and objects end with a comma, as
  Wallpaper Engine's own `effects/fluidsimulation/effect.json` does; strict
  parsing had dropped every fluid simulation effect.
- **Pipeline revision** — `PIPELINE_REVISION`
  (`Renderer/Shader/src/identity.rs`) is part of the cache key, and a golden test
  (`src/pipeline/tests/golden.rs`) fails when the output changes without a new identity. Bump it
  whenever codegen can produce different output for source that already
  compiled; each bump invalidates previously compiled programs.
- **`HLSL` is true, as in Wallpaper Engine** — a stage sees `GLSL`, `HLSL` and
  `HLSL_SM40` defined as 1 (`Renderer/Shader/src/preprocess/mod.rs`).
  Wallpaper Engine compiles its shaders as HLSL: it prepends `#define HLSL 1` and
  `#define HLSL_SM40 1` and never defines `GLSL`, which stays defined here so the
  `#if GLSL` paths shaders pick for the backend language stay picked. `HLSL`
  used to be 0, which `#ifdef HLSL` cannot tell from 1 but `#if HLSL` can: every
  such block was skipped. The first pass of each compositing effect
  (`effectcomposebackground`, and the `COPYBG` and `TEX` paths of the god rays,
  shine and clipping mask effects) turns `v_ScreenCoord.y` over only there, so a
  layer composed over the screen sampled it mirrored vertically
  (`MetalSceneDraw.ACompositingEffectSeesTheScreenUpright` reads
  a red-over-blue screen back through such an effect). Taking those blocks put
  the others in play, each handled by a rule that is not tied to a shader:
  - A stage-qualified declaration of a builtin variable the backend provides
    (`in uint gl_VertexID;` and `in uint gl_InstanceID;`, which Wallpaper
    Engine's morph, instancing and shadow stages write) is dropped
    (`PlannedDeclaration::BuiltinRedeclaration`). It had become a vertex
    attribute of that name, which compiles and reads whatever sits at its
    location. The `builtin_variables` strategy spells the uses `gl_VertexIndex`
    and `gl_InstanceIndex`, which Naga types `uint` as the declaration did, so
    `gl_VertexID + g_MorphOffsets[1]` and `CASTF(gl_InstanceID)` need no
    conversion, and the compiled program lists neither as a vertex input. A
    `gl_` builtin the backend lacks (`gl_ViewportIndex`) keeps its former
    handling, so the shadow caster stages (their shadow maps are not drawn) still
    compile.
  - The `mat3 inverse(mat3)` of `common_perspective.h` is an ordinary user
    function: Naga calls it in place of its builtin on both targets, and a stage
    that declares any `inverse` gets no generated Metal helper, as before. It is
    the exact adjugate-over-determinant inverse.
  - The `pow(falloff + FLT_MIN, exponent)` light falloff of `common_pbr_2.h` has
    a positive base even where the falloff is 0, so it is defined and finite. It
    differs from the earlier `mix`/`step` form, which offset the base by 6.1e-5,
    by at most 0.1 for exponents of 0.25 and above and by under 0.001 from 1 to
    16; with a zero exponent it lights beyond the radius, as it does there.
  - A brace-list array initializer (the kernel of `bokeh`) is read by Naga as it
    stands, on both targets.
  Pipeline revision 15 recompiles programs built while the macro was 0. Across
  the 1,269 (scene, shader, combos) programs of the local scene library, compiled
  for SPIR-V and MSL (2,538 compilations, when both targets existed), every program that compiled still
  compiles and none that failed was fixed; 2,126 outputs are unchanged and the
  other 412 differ only in those blocks (author `inverse` 224, light falloff 164,
  bokeh kernel 20, screen coordinate 8, four of them in two). With the dialect's
  cast macros defined, the shipped `generic3`, `generic4` and `shadowcaster`
  vertex stages with `MORPHING`, and `fur4` with its instancing, compile where
  they stopped at `gl_VertexID` and `gl_InstanceID`. Known and not handled: the compiler does
  not supply the dialect's own prelude macros `CASTI`, `CASTU`, `CASTF`,
  `CAST4U`, `DECLARE_SAMPLER2D_PARAMETER` and `MAKE_SAMPLER2D_ARGUMENT`, so those
  stages, and the morph-target stages that pass a sampler to a function
  (`foliage4`, `chroma4`), do not compile on their own; and Naga has no
  `gl_ViewportIndex`. Tests: `preprocess`
  (`default_macros_are_wallpaper_engines_direct3d_dialect_plus_glsl`,
  `every_spelling_of_the_hlsl_test_takes_the_direct3d_branch`), `legalize`
  (`a_redeclared_vertex_builtin_makes_no_attribute_and_its_uses_reach_the_builtin`
  and the macro, qualifier and brace-list cases beside it), `naga_metal` (the
  vertex and instance index as `[[vertex_id]]`/`[[instance_id]]`; the author's `inverse`) and `pipeline` (the screen
  coordinate, the kernel, the falloff, the vertex inputs, and the shipped
  `effectcomposebackground` and `generic4` stages when the assets are present).
- **A vertex input the shader writes keeps its mesh binding** — Wallpaper Engine's
  HLSL lets a vertex shader assign to its inputs (`a_TexCoord *= atFactor` in the
  workshop Shadow effect, whose default `AT=1` combo makes the factor 1). The
  legalizer reads such an input through a local copy: it declares `_we_in_<name>`
  and keeps `<name>` as the local, and Naga names the entry-point argument after
  the declaration, so reflection reported `_we_in_a_TexCoord`. The renderer binds
  a vertex attribute to the mesh by its reflected name and give a name the mesh
  does not provide the first buffer at offset 0 (the position), so a layer under
  such an effect read its texture coordinate from the vertex position: a text card
  sampled empty texels and vanished, an image layer sampled at the wrong place, and
  a solid layer hid it by being one colour. Reflection now reports the source name
  (`StageInterface::source_name`); nothing else about the compiled stage changes,
  so the MSL stays byte-identical and there is no extra pass, buffer or
  per-frame work. Pipeline revision 16 recompiles stored programs, whose cached
  reflection carries the old name. A read-only input was never renamed.
  A local scene that put text layers under the Shadow effect's default combo
  shows them again on the native renderer. Tests: `pipeline`
  (`a_vertex_input_the_shader_writes_keeps_the_attribute_name_the_mesh_provides`:
  both targets, a written position, a written texture coordinate and a read-only
  colour keep their names and locations) and
  `MetalSceneDraw.AVertexShaderThatWritesItsInputsStillReadsTheMesh`
  (a card showing its texture coordinates, alone and behind a single-pass effect,
  drawn with a shader that writes `a_Position` and `a_TexCoord` unchanged and one
  that does not: byte-equal pictures on each renderer).
- **A boolean multiplied into a `step` mask converts like any float** — Wallpaper
  Engine's HLSL promotes a bool to a number, and an author masks with `int bar =
  step(y, h); bar *= isLeftChannel;`. `step` returns a float, so the legalizer's
  `IntStepInitializer` rewrites that declaration to `float`, but the symbol facts
  every other control-flow repair reads are built from the unrepaired source, where
  `bar` is still an `int`: `FloatBoolAssignment` left the bool bare, Naga rejected
  `Float * Bool` and the whole effect was dropped (`Rust shader compile failed`). The
  workshop Simple Audio Bars effect without anti-aliasing does this in its circle
  and centre shapes (`SHAPE` 4 to 7), so a layer using one lost the bars whatever
  played, which a silent frame cannot show. `SymbolFacts` now types an `int`
  declarator initialised by a two-argument `step` as a float, from the predicate the
  repair itself uses (`int_step::float_step_names`), so the bool becomes `(flag ?
  1.0 : 0.0)` and the other repairs read the rewritten type too: `int level = bar +
  1` is cast, `if (bar)` compares with `0.0` and `bar % 2` is a float remainder. A
  declarator in another scope with the same name keeps its own type. Compile time
  only: no pass, buffer or per-frame work. No pipeline revision bump: a compile
  that failed is never stored (`WPShaderParser` writes a program only after its
  compile succeeded), so the effects that compile now meet no stale entry. A program
  that compiled before can read differently in two forms, `bar % 2` (now
  `_we_Fmod(bar, float(2))`) and a condition `if (bar)` (now `bar != 0.0`, was
  `bar != 0`), and both mean the same as before, so a stored program stays correct.
  Known and not handled: a bool stored into a genuine `int` or `uint`, and a number
  as an operand of `!`, `&&` or `||`, are still rejected
  ([Known limitations](renderer.md#known-limitations)). The corpus sweep
  `shader_corpus_test` (`*ParsesCorpus*`) compiled only the material's own
  combos, so it never saw a scene's choice of `SHAPE`; it now overlays the effect
  file's pass combos and the scene's entry for the pass, in the engine's order, so
  it reaches this defect. Tests: `legalize`
  (`control_flow_coercion_strategy_lowers_bool_stored_into_step_repaired_int`, the
  per-declarator, composition, scope and stereo-centre-path cases beside it, each
  compiled for both targets),
  `MetalSceneDraw.ABooleanMultipliedIntoAStepMaskClipsIt` (a card
  masked white above and below a black band by `int` step masks cut apart by
  booleans: the same picture) and
  `ShaderCorpusScene.EffectIsCompiledUnderTheCombosTheSceneSetsOnItsPasses`; the
  first two fail without the change.
- **Source-defined multiplication helpers** —
  `MetalSceneDraw.ASourceDefinedMulDrawsItsOwnResultWhileTheOtherStageUsesTheBuiltin`
  compiles original overloaded helpers, a prototype and nested calls and draws
  their analytically known RGB result and card coverage through both production
  renderers. A function named `mul` in the source is not the HLSL compatibility
  builtin: its declaration and calls must keep the author's arithmetic. The
  vertex stage, which declares no helper, still uses builtin `mul` to place the
  card. A dropped material or substituting ordinary multiplication cannot pass
  the color and coverage assertions.
- **Repairs for permissive-path shaders** — the pipeline handles undersized
  cross-stage varying declarations, conditional helper headers, source-defined
  `log10`, legacy scalar/vector argument conversion, compound assignment
  narrowing and scalar initializer conversion. Floating remainder uses a
  generated typed helper accepted by Naga, preserving truncating remainder and
  single evaluation of its operands. Active `#undef` directives remove macros
  across includes; inactive branches leave them intact. A directive keyword ends
  at its first non-identifier character, so `#if(A == B)` and `#endif// note`
  are conditionals, and only an `#include <path>` body opens angle brackets, so
  a `<` comparison keeps a trailing `//` comment out of its `#if` expression.
  Generated NV12 members
  create and bind a uniform block even when a material has no authored scalar
  uniforms. It also absorbs idioms author shaders inherit from the permissive
  path they were written against, each of which otherwise drops a whole effect
  rather than one expression: a texture annotation's `"default":""` means the
  slot has no default; `CAST2`/`CAST3`/`CAST4` are vector constructors before
  `legacy_builtins` renames them; mixed-width vector operands inside a call
  argument truncate to that expression's narrowest operand, while sampler
  coordinate arguments stay with the texture strategy that narrows them to the
  sampler's dimensionality; a declaration or assignment truncates its wider
  operands whether they sit next to a call, a constructor or a parenthesized
  group (`round(v2) * v4`, `(CAST2(500) / res4) * s`); a scalar operand of `pow`,
  `mix` and the other broadcasting builtins broadcasts when it is a
  component-wise builtin of known scalars or a one-component read
  (`pow(abs(c), color)`, legacy `saturate`/`lerp`/`fmod` spellings included);
  a whole call of a builtin that always returns a scalar (`dot`, `length`,
  `distance`) is a scalar unless a user overload of that name says otherwise,
  so `vec2 proj = dot(a, b);` broadcasts;
  a scalar stored into a vector by plain `=` broadcasts, and a returned value
  converts to the declared return type the same way (`vec3 f() { vec4 c; return
  c; }` keeps `.xyz`); a comparison stored into a float lvalue (`x += a < b;`,
  `x = a < b;`) becomes `1.0`/`0.0`, while a conditional whose condition
  compares (`a < b ? 1.0 : 2.0`) stays the number it selects; and a parenthesized
  comparison used as an arithmetic operand is converted with `float(...)`.
  A global initializer that reads a runtime value (a uniform, a texture, a stage
  input, a mutable global or a user function) runs at the start of `main`:
  strict GLSL rejects it on a `const` global and silently drops it on a mutable
  one, which then reads zero. Constant initializers stay constant expressions.
  A statement that follows a JSON annotation or a `#define` is analyzed like any
  other; before, it took that token for its type and every repair skipped it.
  Known and not handled: logical-not applied to a float (`!someFloat`), which
  still rejects Wallpaper Engine's own `clipping_mask` effect.
- **An array suffix declares one name, and an integer `clamp` stays integer** —
  `pipeline` tests `array_suffix_declares_only_its_own_declarator` and
  `integer_clamp_keeps_integer_literals`, each compiled for SPIR-V and MSL; both
  fail without the change. Naga's GLSL frontend applies an array suffix to the
  type a declarator list shares, so in `float color[4], f;` the scalar `f` became
  `float[4]` and the effect failed to load (a Workshop procedural noise effect).
  The `array_declarators` strategy ends the statement after each declarator with
  a suffix and restates the qualifiers and type for the rest
  (`float color[4]; float f;`); `for` initializers and stage interface or uniform
  lists are left alone. Integer literals in `clamp` become floats for float
  operands, which legacy shaders rely on, but an `int` or `ivecN` operand selects
  the integer overload, so `clamp(index, 0, BANDS - 1)` on an `int` keeps its
  literals; with only `uint` or `uvecN` operands they gain a `u` suffix, as do
  those of `min` and `max`. Before, the float literals made an integer index
  float and an audio line effect failed to load. The coercion now reads a
  binding's component kind (`int`, `uint`, `float`) as well as its width, and
  sees an `int` that the step repair turns into a `float` as a float. No pipeline
  revision bump: a failed compile is never stored, and a program that compiled
  before keeps its meaning. A split list only restates a name it never used, and
  an integer `clamp` whose result is used as a float (`clamp(i, 0, 5) * 0.5`),
  which Naga had compiled as a float clamp of `float(i)`, now clamps as `int`,
  the same value for integer bounds. Over the 15 local scenes the SPIR-V corpus
  sweep went from 3 failures to none, and on native Metal no other scene's last
  frame changed beyond its run-to-run variation; generated SPIR-V and MSL were
  not compared.
  Known and not handled: in `uniform float a[4], b;` the generated source still
  declares no `b`, and a declarator list whose array takes a
  brace initializer (`= {…}, b`) is not recognized as a declaration, so it is not
  split.
- **Legacy effect shader interfaces** — `pipeline` tests: array varyings reserve
  all element locations; unambiguous user function parameters narrow wider vector
  arguments; a whole vector variable assigned to a narrower one keeps its leading
  components (`pipeline_narrows_whole_vector_identifier_assigned_to_narrower_target`,
  the shipped `cloudmotion` effect's `v_NoiseCoord = v_TexCoord`); custom
  scalar/vector uniforms across stages share a vector block with stage-local
  prefix views. Engine `g_*` uniform type conflicts remain errors.
- **Varying arrays sized by a numeric combo** resolve the macro before generated
  interface declarations are emitted and reserve one location per element, like
  literal-sized arrays. Location planning and emission use the same
  `interface_array_size` resolver at each declaration's source position: all
  earlier active directives count (including macros changed between ordinary
  items or inside earlier function bodies), later changes do not resize an
  earlier array, and bounds must be positive integer literals or visible
  object-like macros with positive integer values. Expressions, missing
  definitions (including those defined only after the declaration), zero and
  negative sizes produce an explicit diagnostic rather than silently reserving one
  location. `pipeline_resolves_macro_array_bounds_at_each_declaration` and
  `pipeline_rejects_unresolved_interface_array_bounds_before_layout` cover both
  backends; `pipeline_compiles_macro_sized_varyings_without_overlapping_locations`
  and `pipeline_legalizes_nested_legacy_calls_in_macro_replacements` compile the
  analysis and MSL targets and cover annotation defaults, explicit counts, consecutive
  arrays and nested object/function macros. Legacy builtin calls in `#define`
  replacements are rewritten inside function bodies too. These are compile-time
  repairs for rejected shaders, not brightness adjustments: restoring a dropped
  effect restores its authored GPU work and target allocation, with no new
  per-frame CPU path or compensating render pass.
- **Uniform array layout is a contract** — a scalar or narrow-vector array in the
  generated uniform block is declared `vec4 name[N]` and every subscripted read is
  swizzled back. std140 pads each element to 16 bytes, which is what the host
  packs and the reflection reports, while the MSL backend emits the natural tight
  stride; without the repair every member after such an array is read from a
  different address on Metal than the host wrote it to. The swizzle follows reads
  reached through `#define` aliases (written inside `main` by the audio-bars
  shader family) and through array-parameter specialization, not just direct
  ones. A `float` element is one component, so a further subscript
  (`g_AudioSpectrum64Left[i / 4][i % 4]`) selects the element itself.
- **Matrix `inverse` reaches Metal through a generated helper** — Naga's MSL
  writer has no `inverse()`, so a stage that inverted a matrix failed native
  translation (`metal translation of '<shader>' failed`), which dropped the
  effect or held the whole wallpaper: the stock
  `perspective` and `lightshafts` effects with any combos, and `reflection`,
  `clouds` and `waterwaves` with `PERSPECTIVE=1`, which undo `squareToQuad` in
  the vertex stage. The `compatibility_functions` strategy renames builtin
  `inverse` calls to `_we_Inverse` and emits mat2/mat3/mat4
  adjugate-over-determinant overloads behind `#ifdef _WE_POLYFILL_INVERSE`,
  else `#define _we_Inverse inverse`.
  `NagaCompiler` defines the macro for MSL only (the SPIR-V target that once kept
  `GLSL.std.450` `MatrixInverse` has since been removed), and no pipeline revision bump was
  needed. A shader that declares its own `inverse` keeps it.
  `matrix_inverse_of_every_square_size_compiles_to_metal`
  (`naga_metal`) covers the translation;
  `MetalSceneDraw.MatrixInversesOfEverySizeAreTranslatedAndDrawnExactly` draws
  each size's round-trip residual on the native backend, where one wrong
  cofactor sign turns its channel black.
- **A sampler slot's `combo` answers whether the material bound a texture there**,
  which is not the same as whether the slot is bound. An annotation's `default`
  exists so an unused sampler still reads something sane; `WPSceneParser` binds
  it, then reports the slot as unbound to the compiler so the combo stays 0.
  Feeding the defaulted list back turns every `{"combo":…,"default":…}` sampler
  permanently on (a `rounded_mask` then reads its corner radius from a white
  default instead of `u_Radius`). A slot the combo leaves unsampled is cleared
  afterwards, so nothing holds a texture it never reads.
- **Texture-driven switches are discovered before stripping conditional
  branches**: `#if USE_MASK` can contain the sampler annotation that defines
  `USE_MASK`, and discovering it only after preprocessing drops authored masks
  and lets localized brightness pulses affect the whole image. Only
  texture-derived switches are seeded this way; ordinary combo defaults still
  follow evaluated branches, and explicit material overrides still win. This is
  compile-time work with no added passes, temporal filtering or quality
  reduction; an active mask keeps its texture and sampling cost.
  `conditional_texture_annotations_enable_the_sampled_mask_on_both_backends`
  covers includes, cross-stage switches, absent/default-only textures and explicit
  overrides for the analysis and MSL targets.
