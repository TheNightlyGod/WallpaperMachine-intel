# Runtime regressions

Regression areas for how the renderer runs: the native Metal backend, video,
continuous-playback work, frame timing and idle, audio, the host's half of
rendering, and startup. Each bullet names the test that guards a behavior and
the invariant or trap it protects; keep them covered when touching that area.
The commands, probes and by-hand test binaries are in
[renderer.md](renderer.md), which also holds the rules that apply to every
entry ([Regression areas that must stay covered](renderer.md#regression-areas-that-must-stay-covered)).
Scene-content areas are in [scene-regressions.md](scene-regressions.md).

## Native Metal backend

All in `metal_scene_draw_smoke` unless noted; `metal_backend_test` needs no
device.

- **Native backend admission** — `metal_backend_test`: every refused construct
  keeps its own distinct reason; a plain sheet, a sprite particle layer and a
  skinned mesh under a `g_Bones` shader are accepted; a skinning shader on a mesh
  without bone weights and a bone stride that cannot hold a 4x4 matrix are
  refused; a puppet under an effect chain is judged by the chain's final mesh,
  and only on the chain's last node. An unused perspective camera does not
  reject; a supported layer that names a perspective camera, or an active
  perspective camera with supported layers, is accepted. Scene lights are
  accepted (`MetalCapability.ASceneWithLightsIsAccepted`), and so is a graph
  that reads a target before it writes it
  (`MetalGraph.ReadingATargetThatIsOnlyWrittenLaterIsAcceptedAsHistory`).
- **No target or mesh the draw path cannot allocate** —
  `MetalSceneDraw.ParserBuildsOnlyTargetsTheDrawPathCanAllocate`: plain, layered,
  feedback, history, effect-chain, text and every particle layout the parser writes
  (sprite, sprite trail, rope, rope trail, one particle, none) leave no multisampled
  target, no depth-only target and no per-frame mesh with several streams or no
  storage, before and after the graph lowering, so the native backend has no gate for
  them; `TheCheckForStatesTheDrawPathCannotAllocateSeesEachOfThem` sets each by hand
  to show the check reports it.
- **Lighting** — `MetalSceneDraw.ASceneLightReachesTheAuthorsLightingUniforms`:
  a point light's premultiplied colour (colour x intensity x radius squared)
  and position reach the author's `g_LightsColorPremultiplied` and
  `g_LightsPosition` through the shared value updater, read back as pixels.
- **Previous-frame reads** — `MetalSceneDraw.ALayerReadingThePreviousFrameSeesExactlyThePreviousFrame`:
  a card sampling `_rt_MipMappedFrameBuffer` sees the cleared buffer on the
  first frame and the frame before on every later one, byte-identical with
  scene optimisation off and on, and the loop is reported as `Feedback` demand
  so updating only on change cannot stop a trail mid-fade.
- **An input nothing produces** — `MetalSceneDraw.AStepSamplingAnImageNothingProducesIsSkipped`:
  a step whose sampled slot the graph left without a name (a layer texture
  whose layer draws no composite) neither draws nor clears, as on
  Compatibility, instead of refusing the scene. An image that has a name and
  does not load still sends the whole scene to Compatibility.
- **Intentionally unbound samplers** — `UnboundSlot.*` in `unbound_texture_slot_test`:
  omitted texture lists and explicit null slots sample zero in every RGBA channel,
  following [Direct3D null-resource sampling](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/sample--sm4---asm-),
  rather than dropping the draw. The shared material loader fills only active
  unbound slots after annotation defaults and texture-presence combos settle;
  authored textures still win and their presence switches remain unchanged.
  `WPTexImageParser` supplies one immutable 1x1 RGBA image under `$nullTexture`,
  reused by the ordinary image caches, with no new per-frame work or render pass.
  Named missing assets and unresolved layer links are not null bindings and keep
  the failure/skip behavior above.
- **Face culling** — `MetalSceneDraw.ADepthTestedDrawCullsTheFacesItsMaterialAsksFor`:
  a card under a perspective camera, turned towards and away, with back, front
  and no culling and with and without a depth attachment, drawn by both
  renderers through `SceneRendererHandle`; the pictures must be byte-identical,
  and the cases must differ (one side culled, the other kept). A pass into a
  depth-attached target takes its material's cull mode with counter-clockwise
  front faces, as Compatibility does; every other pass culls nothing. Native
  Metal culled nothing, so a planet's ring drew its unlit back over its front.
- **A screen read before any draw** — `MetalSceneDraw.AScreenReadBeforeAnyDrawSeesTheBackgroundEveryFrame`:
  the only layer blends with the screen, so the first thing each frame does to
  the scene's image is copy it for that layer. Compatibility clears the image
  to the background at the start of every frame; Native Metal clears it in the
  first pass that draws into it, so it copied an image nothing had cleared --
  empty and transparent on the first frame, the previous frame's picture after
  it -- and the layer vanished. Native Metal now clears the scene just before a
  pass that copies or samples it ahead of any draw. Three frames are drawn; both
  renderers must agree and show the background plus the blend's quarter red.
- **The host's frame step** — `MetalSceneDraw.TheParallaxEasingStepsOnceForEachFrameTheHostDraws`:
  `WPShaderValueUpdater::FrameBegin` (the parallax cursor's smoothing, puppet
  attachments) is the host's, once per frame before it draws, on either
  backend. `MetalRender::drawFrame` used to call it again, which stepped the
  smoothing twice per frame: the parallax on Native Metal chased the cursor
  twice as fast and a frame earlier than on Compatibility. Test loops that
  drive `drawFrame` directly take the step themselves, as `SceneWallpaper`'s
  draw does.
- **Perspective cameras** — `MetalProjection.PerspectiveUsesFovAspectNearFarAndAHomogeneousDivide`,
  `.UnprojectingNdcHitsTheLayerPlane` and `.CameraAxesFollowTheAttachedNode` in
  `metal_backend_test`; `MetalSceneDraw.APerspectiveCameraDrawsThroughTheAuthoredShader`
  (see also the 2D scene's perspective camera in
  [scene regressions](scene-regressions.md)).
  Projection is the scene camera's own FOV/aspect/near/far, not an orthographic
  scale; a rotated card must foreshorten.
- **Depth writes** — `MetalSceneDraw.ADepthWritingDrawHidesLaterDraws`:
  a half-transparent card, then an opaque card behind it, authored with
  translucent, additive and normal blending, with and without `depthtest` and
  `depthwrite`, and with and without a depth attachment, each drawn through
  `SceneRendererHandle` (`DrawWithRenderer`); the nearer card must hide the
  overlap exactly when it depth-tests and writes into a depth-attached target.
  The depth state comes from `ResolveSceneDepthState` (`SceneMaterial.h`). Native
  Metal used to drop depth writes for translucent and additive materials, and
  depth-tested into targets with no depth attachment, where Wallpaper Engine draws in
  painter's order. A layer drawn through effects takes the same state from the layer, not
  its effect pass, except that a layer Wallpaper Engine sorts (blending `translucent` or
  `additive`) in a scene that sorts takes no write from it
  (`MetalSceneDraw.ALayerDrawnThroughEffectsKeepsItsOwnDepthTestAndWrite`,
  [scene regressions](scene-regressions.md#layers-textures-and-compositing)).
- **Render passes** — `MetalSceneDraw.LayersSharingATargetShareOneRenderPassAndHiddenLayersCostNone`:
  consecutive passes into one image share one render pass, a hidden layer starts
  none, a hidden card draws exactly what a dropped one does, and showing it
  changes the picture. A pass starts a new render pass only for another image,
  another depth attachment, a read of its own image, or a clear, unless the open
  render pass began with that same clear and has drawn nothing yet. A draw
  sharing a render pass sets every binding the previous draw may have left, nil
  included. On a real scene, `WE_TEST_METAL_PROJECTS` prints render passes and
  blits per frame and CPU per `drawFrame`, and its PPM must stay byte-identical to
  a build without the change.
- **Shared target images** — `MetalSceneDraw.TargetsThatAreNeverAliveTogetherShareImagesAndDrawTheSamePicture`:
  traded copies of the scene (two lenses, scene optimisation on) and the effect
  buffers of two layers drawn one after the other (optimisation off, so nothing is
  pinned) are drawn with sharing off and on (`MetalRender::SetTargetSharingForTests`);
  with it on the targets must take fewer bytes, every frame must be
  byte-identical, and the copies must still be traded rather than blitted. Only a
  target whose first touch in a frame is a clear that runs, that no copy writes or
  reads, and that is not carried over, pinned, mip-mapped, depth-attached or the
  output shares; a pooled copy gives its image back only after its last reader is
  encoded, and an abandoned frame puts every pooled name back.
- **Feedback copies** — `MetalSceneDraw.AFeedbackCopyTradesTexturesAndDrawsTheSamePicture`:
  two lenses that each sample `_rt_FullFrameBuffer` over a card, drawn with scene
  optimisation off (the graph's copies are made) and on (the image and its copy
  trade textures, and the reader's render pass opens with a texel-exact copy of
  the image as it stood). Every frame must be byte-identical across three frames
  (the trades carry over) with no blits when on; removing the opening copy fails
  all three. The trade is planned only for a copy whose reader is the next pass
  to touch the image, draws into it without reading it, and loads it (or clears
  it, which needs no opening copy), with both textures private to one name, one
  size, `RGBA8Unorm`, one mip level, no depth and neither image reused; an
  abandoned frame undoes its trades. On a real scene,
  `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` makes the copies again, and the harness
  PPM must match either way.
  `.InterleavedFeedbackCopiesPreserveEachReadersImage`: `copy A→Ac`, unrelated B
  work, `copy B→Bc`, then B's reader before A's reader; both target images match
  the blit path over four frames with both blits removed. Opening copies are
  retained separately by destination texture, not in one overwritable pending
  slot, and graph release and abandoned frames clear that state.
- **Per-frame geometry upload** — `MetalSceneDraw.GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot`,
  across more frames than there are in-flight slots. Zero live particles must
  draw nothing rather than fail.
- **Skinning** — `MetalSceneDraw.APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces`:
  a 64-byte reflected bone stride, the skinned quad translating by the distance
  its bone did with its width unchanged (what rules out a transposed matrix), the
  unskinned quad still, no reuse while the pose moves, `pause()` freezing and
  `play()` resuming. `.TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend`
  repeats the translation and draw with the author's `genericimage2` and skips
  without the shipped shaders.
- **Trail and rope layouts** — `MetalSceneDraw.ARopeLayoutMeshReachesTheTarget`,
  `.ASpriteTrailMeshReachesTheTarget` and
  `.TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively`,
  which runs the editor's own preview projects through the real parser and
  shaders and skips without the shipped assets.
- **Scene optimisation applied at runtime** — `MetalSceneDraw.TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff`
  and `.AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn`:
  turning the setting on must reach a graph that was compiled while it was off,
  on that graph's next frame, without reusing pixels no plan recorded.
- **Program reuse** — `MetalSceneDraw.TheSameProgramIsCompiledOnceAndReusedByTheNextSurface`:
  a second renderer on the same device must not hand an identical translated
  program to the Metal compiler again. The pipeline key identifies the program by
  content, never by the address of the object holding it.
- **Imported pictures shared between displays** — `SharedPictures.TwoDisplaysLoadingTogetherBindOneTextureAndUploadItOnce`
  and `.TheTextureLivesWhileEitherDisplayShowsItAndIsGoneWhenBothUnloaded` in `scene_shared_pictures_test`:
  two renderers compiling one scene at the same moment, each from its own parse,
  bind one texture for its image and upload it once
  (`MetalRender::ImageUploadsForTests`), the process cache holds one display's bytes
  for both (`SharedImageBytesForTests`), both draw the same picture, and the texture is
  kept while either display still shows it and gone once both have unloaded.
  `.ADisplayThatKeepsAnotherMipRangeGetsItsOwnTexture` and
  `.AFileRewrittenWithOtherPixelsUnderTheSameNameIsLoadedFresh`: a surface that
  drops a leading mip gets its own texture, and a file rewritten with other pixels
  under the same name and layout is loaded fresh while the old picture is still
  shown. A texture is handed to a further display only after its pixels compare
  equal to that display's parse; the name and layout alone are never trusted.
- **Optional programs** — `.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader`
  asserts the parse compiled nothing optional before asking for it, and
  `.AVideoLayerKeepsConvertingWhileTheSettingIsOff` asserts the program was never
  even claimed while the switch was off: preparing an optional variant during a
  parse is a first-frame cost, not a free one.
  `.AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch`: after the
  in-memory caches are cleared, the stored entry must reproduce the Metal source,
  the reflection *and* the per-stage binding plan without the compiler running;
  truncated entries fall back to a normal compile. Restoring MSL alone is not a
  restored program.
- **Pipeline archive on the production path** — `MetalSceneDraw.PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath`:
  pipelines are offered to the archive, published, reopened from disk and
  satisfied strictly, and a scene with no archive path still draws. A written
  archive that is never attached to a production descriptor proves nothing.
- **Archive stores that were let go stay let go** — `MetalArchiveStores.*` in `metal_memory_test`
  (test-only hooks hold the archive's queue, so "later" is a point in the test, and read the
  open store, record and descriptor counts). A pipeline is built, nine stores are opened
  while the queue is held and the first is let go, and the queue is released: no store is
  brought back, stores stay at eight or fewer and records never outnumber stores
  (`AnEvictedStoreIsNotRevivedByItsLateCompletion`, `ManyEvictionsKeepTheBookkeepingWithinTheBound`).
  A store let go and opened again under the same folder keeps only its own pipelines and its own
  collector when the older work runs, and an older scheduled write publishes nothing of it
  (`AnOldCompletionDoesNotFeedAStoreOpenedAgainUnderTheSamePath`,
  `AnOldScheduledWriteDoesNotPublishAStoreOpenedAgain`).
- **Displays share the pictures of one scene** — `SharedPictures.*` in `metal_memory_test`:
  two renderers loading one scene at the same moment bind one texture, the cache holds one
  display's bytes for both and the second display uploaded nothing, both draw the same
  picture, and the texture is gone once both have unloaded (a dead key is dropped by the next
  import). A display that keeps another mip range gets its own texture; a file rewritten with
  other pixels under the same name and layout while the old picture is still shown, a change
  to the very last texel included (the readback is in bands, so it is the last band that must
  be compared), and another wallpaper's file of the same name, are loaded fresh and neither
  display's picture changes. A text layer's runtime image never enters the cache.
- **A store folder deleted mid-write** — `MetalSceneDraw.AStoreFolderDeletedWhileItsArchiveIsWrittenCostsOnlyThatWrite`:
  eight scenes, each with its own store, write while every store folder is deleted
  and made again in a loop; the process survives and no scratch file is left in
  the temporary folder. Metal's `serializeToURL:` writes a scratch file beside its
  destination and corrupts the heap when that folder vanishes (a double free in its
  error path): serialised beside the store, this test crashed every run, and
  **Clear shader cache** could do the same to the app. The archive is serialised
  in `NSTemporaryDirectory()`, moved beside the store, then over it.
- **Who owns the first frame** — `MetalSceneDraw.ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone`:
  a backend reports presentation through `drawFrame`'s `presented` out-parameter
  and leaves `Scene::first_frame_ok` to the frame handler. A backend that sets the
  flag satisfies the handler's own check before the handler runs, the host is
  never told the wallpaper started, and the startup deadline tears down a
  wallpaper that is drawing correctly.
- **Posters** — `metal_poster_capture_test` covers on-request poster readback,
  busy coalescing and invalidation.
  `MetalSceneDraw.APannedWallpaperIsComposedAtTheChosenPositionInTheDrawableAndThePoster`
  fits a 3:2 scene into a square layer and reads the poster for a position at the top,
  the middle and the bottom: the first and last rows that are not the bars' black must
  be the layout function's, in the frame that presents the change and in a poster served
  from the retained output without drawing (`ServicePosterRequest`), and the two posters
  must be byte-identical. It skips visibly without a Metal device. The poster is the
  only place the composition can be read, the drawable being released at present.

## Video decode, color and import

- **A scene's video reaches the decoder without whole-file copies** — `VideoInput.*` and
  `Sha1Stream.*` in `scene_video_input_test`, against clips the project's synthetic encoder
  writes, with the temp directory pointed at a private folder and a counting file-space hook.
  For a loose clip on the host disk and one on a physical mount, the image carries the file's
  own path and no slots, the mount is asked for nothing and no cache file appears. A clip in a
  package is read through the mount in pieces of at most 1 MiB into exactly one file named by
  the content's SHA-1; a second open reuses it (same inode and modification time), and six
  openers at once never show a watcher a file of the wrong size at that name and leave no
  staging file. A clip packed into a `.tex`, plain and lz4, keeps its bytes in the first level
  and its header is probed from the byte range. Each shape's size, length and first picture
  equal what decoding the file itself gives, and a truncated, garbage or empty clip fails in
  every shape and leaves no cache entry. `Sha1Stream` gives the one-shot digest however the
  input is cut (known answers included). `DISABLED_PeakResidentGrowthOfOpeningAHundredMegabyteClipFromAPackage`
  measures the open in a child process: a 154 MiB clip grew the peak resident size by 1.1 MiB.
- **Decode state machine** — `video_decode_pump_test` pins the send/receive
  contract and includes reproductions of the two orders to avoid:
  feeding input before draining output loses a packet the decoder rejected with
  `EAGAIN`, and seeking at end of input instead of draining loses the reordered
  tail of every loop. It also covers cancellation during a drain, a bounded
  no-progress budget, and releasing a held packet exactly once on seek, stop or
  failure.
- **Color range** — `video_color_conversion_test` pins known pixels for
  BT.601/709/2020 in both ranges, studio black and white with clamping, 75%
  color bars round-tripped from their RGB primaries, matrix separation,
  resolution-based inference for unspecified metadata, and bit-depth scaling.
  Limited-range chroma has its own 224 code-value excursion; reading it as
  `sample - 0.5` desaturates every studio-swing frame, and that has a case of its
  own. `MetalVideoTexture.ConvertedNv12MatchesTheCpuColorReference` compares the
  Metal `nv12_to_bgra` kernel against the same CPU reference so the two paths
  cannot drift apart.
- **10-bit and HDR scene video** — `MetalVideoTexture.P010ConvertedMatchesCpuReference`
  in `metal_video_texture_test` imports synthetic `x420` frames through the real
  Core Video cache and compares the GPU's BGRA with `Renderer/Testing/hdr_reference.hpp`,
  a double-precision reference written from BT.2100, ST 2084 and BT.2390 with
  its gamut rotation derived from chromaticities (PQ and HLG greys across the
  range, saturated BT.2020 colour, P3-D65, full range, display-referred 10-bit, and
  BT.2020 primaries on an SDR curve), within three code values. Beside it:
  `PqTransferToneMapsPeakBelowOne` (the stated peak lands on white and no higher, greys
  stay grey, the sequence below it is ordered), `HlgTransferToneMaps`,
  `SdrTenBitSkipsToneMap` (the same codes tagged PQ come out differently, so the choice is
  the transfer function's and not the bit depth's), `TenBitPeakComesFromTheStreamsOwnMetadata`
  (content light level over mastering display over the 1000-nit default),
  `TenBitForcesConvertedPathEvenWhenPlanesAreDemanded` (one conversion, no planes offered,
  a demand change re-imports nothing), `TenBitFramesApplyEveryDisplayOrientationToTheirPixels`,
  `AFormatChangeFromEightToTenBitSwitchesPathWithoutLosingTheTexture`, and
  `EightBitVideoNeverBuildsTheTenBitPipeline`, which is the proof that an 8-bit scene pays
  nothing for any of it. `VideoColorConversion.GamutRotationIntoBt709IsDerivedFromThePrimaries`
  pins the derived BT.2020 and P3-D65 rotations against the published matrices.
  `MetalSceneDraw.ATenBitVideoLayerStaysOnNativeMetalAndIsToneMappedToSdr` draws real
  HEVC Main 10 clips (PQ, HLG, BT.709) that the VideoToolbox encoder wrote through the
  readers and the hardware decoder, with plane sampling on, and compares the scene's own
  output pixel with the reference. `VtFrameDecoderTest.TenBitHevcClipsDecodeToTenBitFramesThatCarryTheirTags`
  proves the chain delivers `x420` frames with the curve, primaries and matrix attached,
  and `SyntheticTenBitVideo.*` checks the fixture itself with AVFoundation. The content light
  level an encoder may or may not carry is reported, not required; no real HDR10 file was
  checked.
- **Display matrices** survive metadata probing and frame extraction: the decoded
  buffer keeps its coded dimensions, while output dimensions and sampling use the
  affine display transform. `VideoDisplayTransform.*` in
  `video_color_conversion_test` checks all eight orthogonal orientations plus
  scale and shear, and `Decoders/VideoSourceInput.DisplayMatrixSurvivesMetadataProbeAndFrameExtraction/*`
  (once per decoder) reads ordinary synthetic MP4 metadata. Private-texture Metal checks
  draw four distinct corner colors through BGRA, converted NV12 and direct NV12
  sampling and compare orientation, logical size and transparent uncovered
  corners for shear; converted and direct output may differ by at most two
  channel levels.
- **The native decode path** (project readers plus VideoToolbox; the default for MP4/QuickTime
  and WebM/Matroska payloads) — `vt_frame_decoder_test`, `video_probe_test` and the native
  cases of `video_source_input_test` (`NativePayloads.*`, `Decoders/VideoSourceInput.*/native`).
  Display order is the picture shown, not the decode order: a 60-frame clip with B-frames
  (reorder depth 2) and an H.264-in-Matroska clip with B-frames come out with strictly rising
  times and the right noise frame at every position (`FramesComeOutInDisplayOrderOnAClipWithBFrames`,
  `AnH264ClipWithBFramesFromMatroskaComesOutInDisplayOrder`, `AMatroskaPayloadWithBFramesPlaysInDisplayOrder`).
  Destroying a source mid-decode returns within two seconds
  (`DestroyingADecoderMidDecodeIsPrompt`, `Decoders/VideoSourceInput.DestroyingASourceMidDecodeCancelsPromptly/native`): a
  wait that ignores cancellation, or a pump whose no-progress budget runs out in microseconds
  while the decoder is merely busy, shows here first. A stream that breaks part way stops
  playing and keeps its last picture, and a run of undecodable samples fails the stream instead
  of spinning (`AStreamThatBreaksPartWayStopsPlayingAndKeepsItsLastPicture`,
  `SamplesThatAreNotVideoAreSkippedAndAStreamOfThemFails`). An embedded payload plays from memory
  or an anonymous file and never writes a visible one, and one above the spill threshold leaves
  the process's memory once the stream is known to play
  (`InPackagePayloadIsDecodedFromMemoryAndWritesNoFile`,
  `ReleasingThePayloadBufferKeepsAnOpenSourcePlaying`; the payload leaving is asserted through
  ownership, because a freed block stays counted in `phys_footprint`). Full range stated only in
  the stream (an H.264 or HEVC VUI, an AV1 sequence header; no `colr` box) is decoded as full
  range, never squeezed into 16-235 (`FullRangeStatedOnlyByTheParameterSetsDecodesAsFullRange`,
  `HevcAndAv1RecordsThatStateFullRangeAskForTheFullRangeFormat`, the `Av1SequenceHeader.*`
  vectors in `media_core_tests`). The reorder depth comes from the file's sample table, so a table
  that reorders more than 16 frames is refused rather than holding decoded pictures without
  bound (`AStreamThatReordersMoreThanADecoderMayHoldIsRefused`). A payload the native backend
  refuses (a fragmented MP4, a container it does not read) fails with its reason, holds no decoder
  and stages no file; nothing else is tried (`AFragmentedMp4IsRefusedWithItsReason`,
  `AContainerTheReadersDoNotKnowIsRefusedByName`).
- **Decoded frames carry real timestamps** — `video_source_input_test` against media the tests encode. A frame whose
  timestamp is always zero looks like playback for as long as frames keep
  arriving and then freezes, so a video regression here reads as "the picture
  stopped" rather than as a decode failure. `video_source_input_test` owns a private
  `TMPDIR` and asserts that nothing is written to it; never clear the app's decode cache to make
  a test pass.
- **A decoder survives a rebuild of the graph** -
  `MetalVideoTexture.AVideoSetAsideByARebuildIsTakenBackAsItIsAndNotReadAgain`,
  `.AVideoTheNewGraphDoesNotUseIsClosedWithItsCompile`,
  `.VideosSetAsideAreClosedByClosingThemAndByTheObjectGoingAway` and
  `.AVideoSetAsideThatFailedWhileItWaitedIsOpenedAgainLikeAnyOther` in `metal_video_texture_test`
  (`MetalVideoTextures::hold`, `closeHeld`, `prepare`). A graph built again for the scene that is
  drawing it sets its videos aside instead of closing them. The compile takes back the ones its
  textures name without asking the scene's parser for them (the test hands `prepare` a parser that
  counts and refuses, and requires no call: reading a packaged video copies and hashes the whole
  file), gives them the scene's clock (the source's last `syncPlayback` carries the 4 s of the
  test's scene) and goes on with the frames the same decoder delivers. A video it does not name is
  closed when the compile ends (the weak pointer to the source expires then and not before). A
  plain release or clear closes what was set aside too, and a decoder that fails when it is given
  the clock is dropped and opened as any other (the test sees the parser asked once). With the
  keeping switched off for the run, three of the four tests fail and the failing decoder passes by
  construction. The scenes that show it end to end are in
  [scene regressions](scene-regressions.md#text-fonts-and-clocks).
- **A reopened source is sought once and left to land, and a jump of the clock is one seek** —
  `Decoders/VideoSourceClock.*` (both decoders) and `VideoSeekPolicy.*` in `video_source_input_test`, against media the
  tests encode (a 10 second clip of 30 frames a second whose frames have their own pts). A source
  that is opened while the clip is playing (a scene that falls back to the other renderer) opens at the head, and gives it the clock by the first
  call. `.AReopenedSourceIsSoughtToTheClockOnceAndLeftToLand` requires the open to return the
  head's frame whatever clock it was handed before (it waits for no seek), one seek request by
  the first call with the clock after it (6.5 s of a 10 s clip; 7.2 s of a 3 s clip, which is in
  its third pass), and that call to return with the head still on offer (the display only moves
  inside the call, so a call that waited for the seek is caught), and the frame on offer at the
  clock within two seconds with still one request in all; before the seek policy it made 2 to
  1263 requests where one is asked, in every run it was tried.
  `.AJumpOfTheClockLandsWhileFramesAreAskedForFasterThanASeekTakes` hands a source a clock that
  jumps to 7.5 s and then a draw every millisecond, a seek's decode being several times that,
  and requires the frame at the clock within two seconds and one request: a seek asked for again
  on every call restarts the decode from its keyframe each time (1306 requests in two seconds
  and the display on frame 0 on a cold run before the policy; one request when the seek landed
  inside a step, so this one was red in 2 of 6 runs there).
  `.AClockThatLeavesASeekBehindAsksForAnother` is the other side, a clock that goes back before
  the seek on its way gets its own seek, and `.ASourceThatIsKeptUpWithNeverSeeks` that playing
  on from the start asks for none. `VideoSeekPolicy.*` is the arithmetic of the wait, which a clip
  small enough to test cannot make long: a seek is waited for as long as it takes while the
  clock only runs on (and at a faster clock's pace), is asked for again when the clock jumps past
  that or goes back before its target, and a landing that came late raises the lag the source
  decodes on through before it seeks again. That a seek of seconds lands with one request was
  measured on libx264 clips of 1080p and 4K with a keyframe every 250 frames and on a 4K 60 frame
  one with a keyframe every 600 (landing 0.35 to 4.2 s after the open, one request each). With
  the one second of slack fixed, a seek on its way was asked for again each second, and the
  600 frame clip did not land at 5 s in six seconds (six requests) and took three requests and
  3.2 to 3.7 s from 9.9 s on.
- **Consumption decided before import** — `MetalVideoTexture.PlanesOnlyDemandEncodesNoConversion`,
  `.MixedDemandConvertsOnceAndStillPublishesThePlanes` and
  `.ADemandChangeReImportsTheSameGenerationInsteadOfWaiting`: a frame every
  consumer samples as planes encodes no conversion and allocates no destination;
  a mixed scene converts exactly once.
- **Pixel format decided per frame** — `MetalVideoTexture.ABgraFrameIgnoresAPlaneDemand`
  and `.AFormatChangeSwitchesPathWithoutLosingTheTexture`. Software decode hands
  back BGRA and VideoToolbox hands back NV12 for the same file, either can take
  over mid-playback, and neither may reparse the scene or lose the picture.
- **Direct plane sampling, end to end** — `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader`
  and `.AVideoLayerKeepsConvertingWhileTheSettingIsOff`: an ordinary parsed author
  material, a real decoded video, the variant compiled by the parser, bound
  through its own reflection and drawn. A test-only shader does not cover this.
- **Direct-versus-converted picture** — `MetalSceneDraw.OneToOneSamplingProducesTheSamePictureOnBothPaths`
  (must agree to one code value) and `.ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies`
  (see [performance](../features/performance.md)). The paths are exactly
  equivalent at a one-to-one mapping; under resampling they differ only where the
  stream carries codes outside the range it declares, bounded by that clamp's own
  excursion.
- **Plane variant refusals** — the plane tests of `Renderer/Shader`
  (`src/legalize/tests/`, `tests/gpu_probe.rs`): an explicit-LOD sample, a size
  query, and any other use of the video slot refuse the variant instead of
  mistranslating it, and the ordinary program is unchanged by the option existing.

## Continuous-playback work contracts

- **Clears** — `RenderTargetLifetime.NestedCompositesClearBeforeChildrenWithoutErasingThem`
  keeps every later draw loading and single-sample.
- **Per-frame uniform writes** resolve reflected members through a per-pass memo
  instead of string-keyed maps; every value is still written every frame and the
  upload stays memcmp-gated. The memo relies on two invariants: after parsing, a
  material's `customShader.constValues` only gains keys or is updated in place (a
  runtime erase would have to invalidate the memo), and `RuntimeImageSource`
  never removes a name (`NamesGeneration()` moves when one is added).
- **Puppet copies** reuse a result buffer in their existing shared playback state
  for the exact same finite time until a control mutation; fresh layers sharing an
  asset have independent results and attachments still apply each frame. Audio
  uniforms borrow an owning packing buffer synchronously and read a fresh spectrum
  on every call; particle mouse inverses are skipped only when all current
  controlpoint link flags are off.
- **A destroyed layer's script state** — `ScriptLayerRelease.*` in `scenescript_behavior_test`
  (no device). A script makes a layer and one below it, registers an animation-ended callback
  on each and keeps a weak reference to each callback and each layer object; the test gives the
  layers a one-shot animation and plays it out by hand. While the layers exist both callbacks
  run and both closures and both wrappers are alive; after `destroyLayer` no callback runs, even
  for an animation that ends later, and a tick later every closure and wrapper is collected. The
  behaviour was already there when the test was written; breaking the library's cleanup fails
  the last two cases.
- **Core and bridge tests** additionally cover bounded capability relay delivery,
  renderer-instance replacement, serialized observer replay/publication, retained
  held-button levels and discarded inactive taps, level-only native
  reconciliation, single-turn samples and exact-success input deduplication.
  Native capability and button tests initialize loopers only, not a renderer,
  playback or audio hardware.
- **Performance probes** stay disposable, with fixed simulation time, full output
  checks outside timing, raw samples and per-block median/p95. C++ `new` counters
  do not measure QuickJS `malloc`, worker-thread allocations or whole-process
  memory. Pixel equality and command traces are not synchronization-layer
  validation, desktop equivalence, GPU residency or power measurements; GPU
  elapsed times vary run to run, so treat them as samples, never as proof of a
  GPU-time change and never as power or battery measurements.
- **Frames that would repeat the picture** — `unchanged_present_test`
  (Native Metal, driven through `SceneWallpaper` on a `CAMetalLayer` no window
  owns) and
  `MetalSceneDraw.AFrameThatWouldRepeatThePictureTakesNoDrawableAndPresentsNothing`.
  A static scene presents nothing once every pass is reused
  (`presents_skipped_unchanged` tracks the draws that ran, `present_requests` stays flat),
  and the poster it then exports is byte-identical to the baseline's. A scaling change
  presents exactly once and then repeats again. A previewed property presents once and an
  on-demand scene wakes for exactly that frame. Counters are compared within one draw at the
  window edges, never exactly. A change the comparison cannot see must invalidate the gate; do
  not widen the skip by comparing fewer inputs. The engine is never given a plain video, so
  there are no plain-video cases. `unchanged_present_test` counts
  frames in wall-clock windows, so run it without concurrent builds or benchmarks and keep a
  failing baseline visible rather than excluding the test.

## Frame timing, pacing and idle

- **Frame timing** — frame timing keeps render cost separate from animation time.
  Dropped busy ticks remain included in the elapsed delivered-frame delta;
  restarting excludes paused time. `timer_tests` covers dropped ticks, restart,
  FPS changes and long gaps without desktop surfaces or audio devices.
- **Pacing follows the content, bounded on both sides** — `timer_tests` pins the
  frame clock's content-rate pacing. A pushed `FrameDemand.content_period` may
  only lengthen the tick interval: the configured FPS stays the ceiling, so a
  60 fps video cannot make a 30 fps wallpaper render at 60, and an unknown, zero,
  negative or absurdly long period cannot stall a scene (one hour is clamped to
  the five-second gap the frame clock still treats as continuous playback).
  Dropping the demand restores the fixed cadence rather than inheriting the
  previous scene's, and pacing never changes how many draws may be in flight.
  The suspension threshold scales with the interval the clock is actually using
  and never drops below the five-second floor, so an ordinary frame boundary at
  the pacing clamp reports its real elapsed time instead of one ideal frame,
  while an eight-hour gap is still treated as a resume.
  - Nothing in the app asks for a content period any more. The scene engine never
    plays a plain video, and no authored scene may answer: that needs a positive
    account of every dynamic render-graph input first, and guessing freezes a live
    wallpaper. The clock keeps the capability, and these tests keep it correct,
    until it has a consumer again.
  - The period a source reports is evidence, not metadata. `avg_frame_rate` is
    an average and `r_frame_rate` an estimate, so neither describes a particular
    gap in a variable-frame-rate clip. `video_frame_pacing_test` pins the rules
    for the estimator that reads it: declared rates are an upper bound on the
    period and never stand in for evidence; the shortest gap actually decoded
    does, after enough samples; the result is monotonically non-increasing, so a
    burst that appears once keeps the period short afterwards; deltas across a
    loop seam or a seek are discarded; and repeated, rewound or non-finite
    timestamps are not counted as evidence at all. Rational rates keep their
    exact period (`24000/1001`, not `1/24`).
- **Pointer-driven clock wakes** — `FrameTimerTest.ABurstOfWakeOnceAtTheCeilingDoesNotAddCallbacks`
  and `.AnIdleBurstOfWakeOnceProducesOneCallback` in `timer_tests`. Two hundred
  `WakeOnce` calls in one second at 30 fps stay inside about one callback per
  period (20–40), and an idle burst produces one callback. The configured ceiling
  still produces frames.
- **Renderer work counters** — `OWE_RC_*` counters are incremented by the
  production paths that perform the work: the frame clock's tick, the draw
  handler, the present request and the frame's completion. They are off by default and read by pulling
  `owe_scene_wallpaper_counters`; nothing is pushed or logged per frame.
  `timer_tests` asserts that a tick which found a draw still in flight is counted
  as a suppressed tick rather than a request, that nothing is counted while the
  switch is off, and — running the real thread timer against the real callback —
  that a content period genuinely lowers how many draws the scheduler posts.
  `video_frame_pacing_test` pins the generation accounting behind
  `video_frames_selected`, `video_frames_reused` and `video_frames_skipped`: a gap
  between two displayed generations is exactly the number of decoded frames that
  never reached the screen, which is how a pacing regression is falsified while
  the picture still moves. `present_requests` counts requests; this backend has
  no presentation-feedback source, so the frames a compositor actually displayed
  are reported as unavailable and never approximated by the request count.
- **A scene with nothing left to do** — `MetalSceneDraw.AStaticTextSceneRunsOutOfWorkToDo`,
  `.AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork` and
  `.TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous`: a static caption
  reaches zero demand reasons, having actually drawn, while the renderer still
  reports `EventMesh` and `RuntimeImage` (the reuse cache depends on both, and
  neither is a reason to keep the frame clock). Assert the reasons, not the frame
  rate.
- **Waking from idle, and not waking** — `MetalSceneDraw.AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain`
  and `TextObjectRuntime.PreparedTextWakesWhoeverOwnsTheFrameClock`: a changed
  caption brings the demand back, reaches the output and goes quiet again; the
  text worker asks for the frame that shows its result, because a scene that has
  already idled has no clock to notice; and rewriting the same string wakes
  nothing. A wallpaper that idles and then misses an update is worse than one that
  never idles.
- **Content that must never be called still** — `MetalSceneDraw.TextProducedByAScriptIsNeverCalledStill`:
  a caption computed every tick keeps the clock on every frame, whatever the
  script returns. No script source is read, no repeated result is counted and no
  schedule is inferred.
- **A history loop is never called still** — `UnchangedPresent.AHistoryLoopKeepsTheClockRunningWithoutATimeUniform`
  (it counts draws in a half-second wait, so it is named in `REALTIME_TESTS`):
  a layer sampling a target the graph fills only after it has drawn (the fixture
  uses `_rt_MipMappedFrameBuffer`; a motion-blur trail or an accumulation is the
  same shape) keeps changing the picture with no time uniform. The renderer
  reports `Feedback` for a `carriesPreviousFrame` target their compiled graph
  reads or writes, so the clock keeps running (with pixel reuse off and on), while the
  same card without the loop goes idle.
- **Geometry rewritten on an event** — `SceneDemandMapping.GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing`
  in `static_subgraph_cache_test`: `EventMesh` and `DynamicMesh` must both cost a
  target its cacheability and must differ at the scene level. Collapsing them
  into one bit either stops static text idling or idles a particle system.
- **A stop after a failure is visible, and a still scene is not a stalled one** —
  `surface_health_test` and `UnchangedPresent.AStaticSceneStopsPresentingOnceEveryPassIsReused`:
  the always-on surface health keeps completed and presented frames apart, so a
  scene whose every pass is reused keeps completing frames while presenting none and
  is never called stopped; a draw failure and a graph failure latch different
  reasons, a graph failure is not downgraded by the draw failure that follows it, and
  clearing the stop keeps the failure count. A liveness check built on presents or on
  the present age would misread every static scene. On the Rust side
  `tests::scene_settings` pins the precedence (the user's pause and a suspended
  display outrank a stop, an unread surface is `unknown` and never `stopped`).
  A genuine presentation failure cannot be produced without a desktop, so the latch
  is covered through its setter.
- **A scene that fails after drawing is healed within a budget, once and visibly** —
  `wallpaper-core` `engine::surface_recovery::tests` pin the ladder with injected
  instants (an in-place surface rebuild after 0.5 s, then two renderer rebuilds after 2 s
  and 8 s), the rolling minute (a failure after a quiet minute starts again, one inside it
  does not), giving up without scheduling anything, a failure while an attempt is
  pending being ignored without spending the budget, a stall check not buying back a spent
  one, a lost attempt not blocking recovery for good, and the look at a rebuilt renderer
  (`settle`: drawing, stopped before drawing, still waiting, and left alone after the limit,
  with a stop outranking a presented frame) feeding a rebuild that stopped before it drew to
  the next rung and then to giving up.
  `runtime::tests` cover the relay: a burst raised before the actor runs is one report, a
  report names the renderer that made it so a rebuilt renderer ignores its predecessor's,
  a closed renderer reports nothing, and a request for a display with no scene, or a look at
  a rebuilt renderer whose scene is gone, heals nothing and leaves the engine serving.
  They also pin the render scale a rebuild carries over (`RenderScale`): a renderer opened
  by recovery, a wallpaper switch or a resolution change is handed the reduced scale in force
  (a new renderer starts at full size), a scale turned back up to full size is not sent again,
  a scale the renderer refused does not replace the one in force, and a new renderer that
  cannot take it fails the rebuild so it is rolled back. Whether a live rebuilt scene really
  rasterizes at the reduced size needs a real window and is not covered. `owe::backend::render_failure_callback_tests` pin
  that a rejected registration hands the callback back to be dropped exactly once and that
  a panicking callback does not unwind into C++. In the renderer,
  `UnchangedPresent.ADrawFailureAfterTheFirstFrameIsReportedOnceAndASurfaceRebuildHealsIt`
  and `...BeforeTheFirstFrameIsCountedButNotReported`. The engine's reaction to a report
  on a live scene needs a real window and is not covered by an automated test, and no
  genuine presentation failure is produced anywhere.

## Audio

- **FIFO continuity and overflow** — `audio_tests --gtest_filter='AudioResponseMonoTest.*'`
  includes `CompactedFifoPreservesEveryStereoWindow` (21 back-to-back stereo
  windows from 49 chunks of 700 frames, so windows straddle submissions; 34,300
  accepted frames, 700 retained) and `OversizedStereoSubmitKeepsTheNewestSecondsWithoutAStagingCopy`
  (waits for all 60 windows from each latest-96,000-frame input and bounds the
  largest heap allocation of the submit).
- **Spectrum matches Wallpaper Engine** — `AudioResponseMonoTest.TonesLandInTheBandsWallpaperEngineMeasures`
  (octave tones from 42 Hz to 12 kHz peak inside the bands measured on Wallpaper
  Engine), `.LevelsSpanFortyEightDecibelsBelowAFullScaleTone`,
  `.CoarserResolutionsCoverTheSameFrequencies` and `.EachSpectrumStandsAlone` in
  `audio_tests`. The 48 kHz tap must be filtered before it is reduced (frequencies
  above 6 kHz must not fold into the bands), and the bands are not peak-held,
  log-compressed, spread into their neighbours or release-smoothed: a normally
  mastered track reading 1.0 in every band turns an audio visualizer into a solid
  uniform ring. See [audio response](../features/audio-response.md#what-wallpapers-receive).
- **Frequency mapping** — `audio_tests`, `particle_mouse_controlpoint_test` and
  `script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'` and
  `shader_updater_behavior_test --gtest_filter='ShaderUpdaterAudio.*'` (the vec4-per-band
  uniform arrays, live and gated on the runtime) cover
  physical FFT frequency mapping including DC and Nyquist, silent and stale
  input, box/sphere emission transitions, and typed SceneScript views.
- **Sound output lifecycle** — `audio_tests --gtest_filter='SoundOutputLifecycle*'`
  on miniaudio's null backend: the output device starts only with channels
  mounted, playing and unmuted; muted hosts (the lock-screen extension) never
  start it; positions stay frozen while paused or muted.
  `SoundStreamTest.ResamplingKeepsTheAuthoredDurationExactlyWhenTheRatioIsWhole`
  and `.ALoopIncludesTheCompleteResampledTail` (with `.EncodedSoundsLoopWithoutAGapOrAnOverlap`)
  pin the resampled PCM of a scene sound whichever decoder serves it: the tail keeps
  the authored duration and a looping stream repeats one cycle sample for sample,
  seam included. `sound_core_tests`, `sound_apple_tests` and `sound_vorbis_tests`
  (`Renderer/Sound/tests`) cover the resampler, remix, pipeline and the two decoders
  ([sound decoding](../sound-decoding.md)).
  `SoundLayerControlTest` checks authored random playback delays between clips
  against emitted sample counts, including different callback sizes,
  pause/resume, stop/restart and seeded bounds, on the null backend, which never
  opens an audio device. The same suite drives a layer over scripted in-memory
  streams: a layer built silent reads nothing, play/pause/stop resume or restart
  the file, volume is clamped and mute keeps consuming it, and one-shot, loop and
  zero-delay random layers each end or restart when their file runs out. All sound
  fixtures use the null backend.
- **A muted wallpaper is silent while it loads** — `scene_load_sound_test` (GPU-gated)
  loads a scene with a looping sound through `SceneWallpaper`, with the surface taken
  first so the configuration loads it at once, and counts how often its output started
  (null backend): once for an unmuted wallpaper, never for one configured muted or
  paused (a paused one still reports its first frame), once when the muted one is
  unmuted later. The trap: a mute sent after the configuration
  arrives behind the load, so a wallpaper switch played the start of a muted
  wallpaper's music. Pause, volume and mute travel in `owe_scene_wallpaper_apply_config`,
  and a reopened renderer takes them from the scene's live state, not its descriptor.
- **Output device rebuild** — `wallpaper-core` `media::audio::device_watch::tests`
  (a burst of changes is one report after the quiet period, a change wakes an idle
  watcher, `cancel` drops a pending report without waiting it out, every subscriber
  hears a change until it is dropped) and `capture_controller_tests`
  (`restart_*`, `a_failed_restart_*` and
  `a_pending_restart_is_dropped_once_nobody_wants_capture`: a running tap is
  stopped and started once and still serves every scene; stopped, suspended and
  permission-pending controllers do nothing; a failed start leaves capture
  stopped, is retried without another device change, is healed by the next
  sync, and is forgotten once nobody wants capture). The
  bridge's `web_audio_media::output_device_change::*` replays the worker's
  handlers on a scripted backend: a web-only session is rebuilt, each retry waits
  its own delay and then gives up after a bounded number of attempts, a newer
  change supersedes an older pending retry, and a retry never tears down a tap
  that a demand change has started; `output_device_change::the_output_watcher_exists_only_while_capture_is_wanted`
  and `::a_watcher_that_could_not_start_is_tried_again_only_when_capture_is_wanted_anew`
  pin that no watcher exists until capture is wanted, that one is released when it
  stops being wanted, and that a failed start is not retried on every command. The
  CoreAudio listener registration is not
  covered; see [audio response](../features/audio-response.md#output-device-changes).
- **Audio capture follows what the scene reads** — `SceneAudioRequirement.OnlyContentThatReadsAudioRaisesIt`
  and `SceneAudioReport.TheHostHearsTheRequirementOncePerSceneAndTheReplacementResetsIt` in
  `scene_schema_part11_test`, `Decoders/VideoSourceInput.PlainVideoProjectNeverReportsAnAudioRequirement/*`
  in `video_source_input_test`, and the bridge tests
  `display_presentation::audio_response_alone_does_not_open_the_tap_for_a_scene_that_reads_no_audio`,
  `::replacing_an_audio_scene_with_one_that_reads_nothing_closes_the_tap` and
  `web_audio_media::a_web_listener_counts_beside_a_scene_that_reads_no_audio`.

## Host, bridge and display behavior

Rust tests in `wallpaper-bridge` and `wallpaper-core`, and Swift tests under
`Tests/Unit/`. They guard the host's half of rendering: what the app asks the
engine to redo, and when.

- **Project and cache boundaries** — core's
  `tests::general::independent_project_contract` exercises typed descriptor rejection,
  real manifest/property loading with immutable edits, successful resolver/loader
  controls followed by existing-target path rejection, artifact-backed cache reuse
  and override invalidation, invalid cache-ID isolation and non-scene bypass.
  `project_override_json` separately covers ordered scalar flattening, null
  normalization, nested-array path errors and the retained empty-parent regression.
  The independent unpacked-cache, framing and recovery cases remain in place.
  These are owned-temporary-file and value tests, not native rendering or corpus proof.
- **A kept desktop wallpaper runs on without a load** — core's
  `engine::actor::space_parking_tests` (parking a scene that has drawn instead of replacing it,
  running it again with its handle and no refresh job, replacing in place as before when nothing
  is kept, closing on a shorter list, a new size, an unplugged display and `close_all`, and a
  global resume leaving it paused) and the bridge's `tests::space_parking` and
  `engine::facade::first_frame_tests::a_wallpaper_the_display_keeps_parked_is_not_awaited`. A parked scene
  that came back is never waited on for a first frame it does not report again, which would end
  in the 90-second rollback. Device-free; no window or desktop.
- **Download-speed sampling** — `DownloadTelemetryTests` in `Tests/Unit/Workshop/`:
  real `nettop` streaming over a private PTY with local-socket traffic; CRLF and
  split line endings. LF-only fixtures do not verify live delivery.
- **Pointer sampling is event-armed** — `api_smoke::mouse_polling_samples_only_when_input_arrives`,
  `::mouse_polling_stops_while_the_only_interactive_scene_is_suspended_on_its_display`,
  `::mouse_polling_in_a_monitor_gap_checks_the_cursor_without_engine_work` and
  `engine::snapshot::tests::a_paused_scene_is_not_a_pointer_consumer_and_its_resume_drops_paused_clicks`.
  A consumer with no input is never sampled; a paused scene is not a consumer.
- **A press counts only on the desktop** — in `window::tests`:
  `a_press_over_another_window_reaches_no_wallpaper_and_neither_does_its_release`,
  `a_press_first_seen_by_a_sample_is_judged_once_and_stays_hidden_while_held`,
  `a_press_the_wallpapers_received_is_released_wherever_the_pointer_ends`,
  `a_desktop_tap_and_a_window_press_in_one_sample_deliver_only_the_tap`,
  `a_button_held_through_the_gap_is_adopted_only_over_the_desktop`,
  `a_press_seen_before_the_gap_keeps_its_verdict_through_it` and
  `only_windows_stacked_beneath_application_windows_count_as_the_desktop`. A press over
  another application's window must reach no scene, nor its level or release; a delivered
  press is always released; the hit test runs once per press, never per move or sample.
  The window-server query itself (`press_lands_on_desktop`) needs a live desktop and is
  not exercised by any test.
- **A global resume keeps covered displays paused** — `display_presentation::a_global_resume_never_restarts_a_display_that_is_still_covered`:
  the scene pause log must never show `paused=false` for a display that is still
  suspended.
- **A display refresh keeps an unchanged scene** — `settings_intents::a_display_refresh_does_not_reload_a_scene_whose_audio_response_has_nothing_to_read`,
  `::a_display_refresh_does_not_reload_a_scene_held_to_the_battery_frame_rate`,
  `::a_display_refresh_does_not_reload_a_scene_held_to_the_quality_throttle`,
  `::a_display_refresh_does_not_reload_a_scene_muted_for_other_audio`,
  `::a_display_refresh_does_not_reload_a_scene_paused_by_a_lock_or_a_covered_display`,
  and `DisplayRefreshCoalescerTests` in `Tests/Unit/Desktop/`. A value applied
  live on top of the saved configuration must never read as a different
  wallpaper: every display change refreshes displays, and a mismatch reopens the
  scene behind a white placeholder layer and restarts its animation.
- **A screen change that moves nothing does no work** — `DisplayRefreshCoalescerTests`
  (`testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotRefresh`,
  `testAnUnchangedBurstDuringARefreshEndsWithIt`,
  `testTwoReadingsOfTheSameDisplaysAreEqual`), `WallpaperSpaceMonitorTests.testOnlyAScreenChangeThatMovesADisplayRereadsTheSpaces`,
  `WallpaperPresentationPolicyTests.testOnlyAScreenChangeThatMovesAWorkingAreaIsEvaluated`
  and `WallpaperWindowAuditorTests.testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotCheck`.
  An XDR display posts a screen change for every frame of an EDR headroom ramp;
  each one would run a bridge refresh, republish every snapshot, re-sync the lock
  screen, push the whole control panel and ask the window server for the
  session's lock state twice. A failed refresh is still retried on the next
  change.
- **A display that vanishes for a moment is not closed and reopened** —
  `DisplayRefreshCoalescerTests` (`testADisplayThatComesBackBeforeTheSettleCausesNoRefresh`,
  `testADisplayThatStaysAwayRefreshesOnceWhenTheSettleEnds`,
  `testAFlappingDisplayHoldsOneWaitAndTheSettleIsNeverExtended`,
  `testAChangeToADisplayThatRemainsRefreshesAtOnce`,
  `testAnArrivalDuringTheSettleRefreshesAtOnce`,
  `testADisplayThatComesBackAsTheSettleEndsIsAnnouncedToo`).
  The bridge closes the wallpaper of a display absent from the screen list, so
  refreshing at once turned a link renegotiating or a monitor waking into a full
  scene load or decoder rebuild. Not refreshing for a display that returns also
  means no snapshot follows, so a window the web or native video host closed
  during the gap would stay closed; the coalescer announces the return and both
  hosts reconcile. Only a reading that is the last refresh with displays removed
  and nothing else moved waits (0.8 s, fixed, never extended); everything else
  still refreshes at once, so a real unplug refreshes exactly once and a
  changed remaining display is never left stale.
- **A wanted display the native video host cannot see is said so, not dropped** —
  `NativeVideoWallpaperHostTests` (`testAWantedDisplayTheHostCannotSeeIsReportedNotSilentlyDropped`,
  `testTheUnseenDisplayIsOpenedOnceItAppears`, `testTheWarningIsNotRepeatedEveryPass`,
  `testADisagreementThatComesBackOrChangesIsReportedAgain`,
  `testADisplayThatReturnsInsideTheSettleHasItsWindowBackWithoutARefresh`) and the mirror,
  clamshell and unnumbered-screen fixtures in `DisplayRefreshCoalescerTests`. The bridge
  reads CoreGraphics' displays and the host reads AppKit's screens, so an offer for a display the host's list
  lacks was skipped with no log line, which looked like a wallpaper that never appears. The
  host still draws nothing there and adds no timer, but it logs the disagreement once and
  opens the display as soon as the lists agree. That includes a display that was missing
  only inside the refresh filter's settle, which causes no refresh and so no snapshot: the
  filter announces the return and the host reconciles, which the host test drives through a
  real `DisplayRefreshCoalescer`.
- **The lock state is not asked per evaluation** — `WallpaperPresentationPolicyTests.testTheLockStateIsAskedOnlyWhenItCanHaveChanged`,
  `.testASessionLockedBeforeStartIsSuspendedFromTheStart`,
  `.testWakingDisplaysAskForTheLockStateAgain`,
  `.testSwitchingUsersAsksForTheLockStateAgain` and
  `.testAMissedUnlockClearsAtTheNextEvaluation`, plus
  `.testUnlockIsReportedOnceWhenTheLockClears` and
  `.testAMissedUnlockIsStillReportedAtTheNextEvaluation` for the edge the playlists
  answer. Every snapshot the engine applies
  runs the presentation policy, and `CGSessionCopyCurrentDictionary` is a
  synchronous window-server round trip. It is asked again only at start, on a lock
  or unlock, on display wake, on a user switch and while the session counts as
  locked, so a missed unlock still clears at the next evaluation.
- **No folder probe per panel snapshot** — `WorkshopDownloadIntentTests.testSceneAssetsAreFoundAgainOnlyOnRefresh`.
  Resolving `ClientPaths.assetsURL` probes up to four folders, which is a large
  share of building the page snapshot while a property slider is dragged. The
  folder is found with its readiness: at launch, after locating or installing
  assets, and when the panel becomes key; a refresh that finds nothing new wakes
  no observer.
- **Identical monitors keep their own wallpapers** — `display_identity::*` in the
  bridge (`a_stale_block_for_one_identical_monitor_never_lands_on_the_other`,
  `display_sync_keeps_one_block_per_display_under_its_current_selector`,
  `a_disconnected_display_keeps_only_its_first_block`,
  `identical_monitors_keep_their_own_wallpapers_across_renumbering`) and
  `display::tests::identical_models_sharing_a_unit_number_do_not_match` in core.
  They replay a four-display layout with two displays of one vendor and model,
  without the hardware. macOS renumbers displays and renames identical models
  across reboots and reconnects: a unit number must never pair two displays whose
  UUIDs or serials differ, display sync must keep one `[[monitors]]` block per
  display under its current selector, and a panel display id from before a
  renumbering must still edit that display.
- **A display that reports no pixels is left out of the refresh** — `display::state::tests::a_running_display_that_reports_no_pixels_keeps_its_descriptor_and_runtime`,
  `::a_new_display_that_reports_no_pixels_gets_no_record_until_it_has_a_size` and
  `::transitional_matching_uses_identity_when_the_display_id_changed`, with
  `display::tests::plan_refresh_*` and `engine::tests::a_secondary_display_without_pixels_is_left_out_until_it_reports_a_size`.
  A display that is still connecting can be listed as active with a 0x0 mode, and
  opening a window for it fails the whole reconcile. It must stay out of the
  refresh, yet a display that already runs a scene must keep its descriptor:
  reading it as absent would close the scene and reload it after the glitch. All
  descriptors are synthetic; a real display that reports 0x0 while connecting was
  not reproduced.
- **A scene moved to a display of another shape fills it** —
  `UnchangedPresent.ASceneResizedOntoADisplayOfAnotherShapeFillsItLikeAFreshOne`:
  a scene running on a 16:9 surface at 1x and rebuilt in place on a 16:10 surface at
  2x (the surface reconfigure the host runs when a display changes) is laid out with
  Fill for the new surface, with no rows left unfilled at the top or bottom, exactly
  as a scene opened there. The canvas is about 1.69:1, between the two shapes, so a
  layout that kept the old shape or fell back to Fit would show bars. The host's own
  hot-plug sequence needs real displays and is not covered.
- **A wake repairs only a scene that stopped drawing** — `wake_revalidation::*` in the bridge
  (`a_scene_whose_frames_advanced_is_left_alone`,
  `::a_continuous_scene_with_flat_frames_is_recovered_once`,
  `::a_paused_or_suspended_display_is_never_probed`,
  `::a_waiting_for_event_scene_is_never_recovered_even_with_flat_frames`,
  `::a_stopped_latch_is_recovered_without_waiting_for_the_grace`,
  `::a_replaced_renderer_whose_counter_restarted_is_not_stale`,
  `::the_call_reaches_the_engine_through_both_facade_halves` and
  `::two_checks_at_once_run_one_after_the_other`), and `SystemWakeRevalidatorTests` and the
  resume tests in `WallpaperPresentationPolicyTests` (`testAGlobalResumeIsAnnouncedAndASuspendIsNot`,
  `testResumingOneDisplayIsAnnouncedAndHidingOrNeverHidingIsNot`,
  `testAResumeTheBridgeRefusesIsAnnouncedWhenItLands`). The check reads each continuous,
  unpaused scene's `frames_completed` twice and hands the engine's budgeted recovery only
  the one that stood still, so a Mac that woke well rebuilds nothing. The signal must stay
  completed frames: a still scene completes frames without presenting, so a check built on
  presents would rebuild every static wallpaper. Paused, event-driven and unreadable scenes
  must never be repaired, a counter that went backwards is a replaced renderer, not a stalled
  one, the forward through `ArcEngineFacade` must reach the engine (a missing one answers
  "no scene" to every repair), and two checks must not overlap or one stall spends two rungs
  of the ladder. The readings are scripted: whether a real surface stops across a sleep, and
  whether the reconfigure restores it, needs an authorized sleep and wake.
- **A reconcile keeps an unchanged scene** — `settings_intents::a_reconcile_does_not_reload_a_scene_held_to_the_frame_rate_cap`,
  `::a_reconcile_does_not_reload_a_scene_held_to_the_quality_throttle`,
  `::a_reconcile_does_not_reload_a_scene_muted_for_other_audio` and
  `performance_settings::wallpapers_applied_under_a_frame_rate_cap_start_at_the_capped_rate`.
  A reconcile hands the engine every configured scene and the engine reopens any
  whose descriptor differs from the one it runs, so the descriptor carries the
  live frame-rate ceiling and mute. It is also what holds a scene opened under a
  cap to that cap: nothing lowers the rate after the reconcile.
- **Snapshots do not wait on the service manager** — `login::tests::a_burst_of_snapshots_asks_the_service_manager_once`,
  `::a_change_made_in_system_settings_shows_once_the_last_read_has_aged` and
  `::a_change_made_in_the_app_shows_at_once`. Every snapshot carries the
  launch-at-login status; reading it from `SMAppService` for each one would hold a
  burst of queued bridge requests (Apply and Quit among them) behind service-manager
  round trips.
- **A failed scene replacement keeps the previous layer in the view** —
  `tests::general::desktop_window::reverting_a_layer_swap_restores_the_layer_and_the_geometry` and `::finishing_a_layer_swap_keeps_the_new_layer`
  (`wallpaper-core`, window tests: `WE_RUN_MACOS_WINDOW_TESTS`, an authorized desktop run
  only, listed in `CORE_EXCLUSIONS` of `scripts/check_rust.py`). The window installs the new
  `CAMetalLayer` before the replacement renderer exists. When the replacement then fails, the
  renderer that kept running draws on the layer that was taken out of the view, and the
  bridge's restore sees an unchanged descriptor and rebuilds nothing, so the display stayed on
  the empty replacement layer. A reverted swap must show the original layer pointer and the
  original window, view and layer geometry (changed on purpose by the swap); a finished swap
  keeps the new layer. Nothing routine opens a window, so the revert on a forced `open_scene`
  failure is verified by reading only, and the gated cases have not been run.
- **Every window layer is announced with its display and reason** —
  `window::tests::announcement_carries_display_and_reason` and
  `::install_reason_strings_are_the_swift_contract` (`wallpaper-core`, device-free: a private
  `NSNotificationCenter` and plain `NSObject`s stand in for the window and its layers). The Swift
  host puts content on a window's new layer from `WallpaperMachine.wallpaperLayerInstalled`, and
  matches the name, the `displayID` and `reason` keys and the `open`, `replace` and `reconfigure`
  strings literally, so a rename on one side silently disables the other (the Swift side,
  `WallpaperSwitchHold`, is pinned by `WallpaperSwitchHoldTests`, which post the same spelling).
  One announcement per
  install, in order, the layer as the object, delivered on the posting thread and not on the
  default center. `tests::general::desktop_window::every_installed_layer_is_announced_once_in_install_order` runs the
  real window paths (open, swap, update, reverted swap) under the same gate as the layer-swap
  cases above and has not been run.
- **The lock screen ignores the covered desktop** — `apply_options::lock_screen_export_ignores_the_desktop_display_being_covered`:
  locking covers the desktop and suspends its display, and the exported
  lock-screen scene must stay unpaused unless the user or power policy paused
  playback.

## Startup

- **First-frame wait.** A cold shader and pipeline compile for a large scene can
  take longer than 20 seconds, and a warm shader cache or driver pipeline cache
  does not remove the wait. The apply wait is 90 seconds, with rollback after
  it. It waits only on displays where the engine opens or replaces a scene,
  judged against the engine's live display snapshot: a display refresh moves and
  resizes scenes in place without the facade, and such a scene keeps its
  renderer, which announces its first frame once. Comparing against the
  descriptors the facade last handed over would make the next Apply wait out the
  90 seconds and roll back a playing wallpaper
  (`engine::facade::first_frame_tests`).
- **A wallpaper that kills the app while it loads is held back.** The saved
  configuration is replayed at every launch, so a scene that crashes the
  process on load would crash every launch. The bridge's load journal records
  the scenes about to open (`engine/load_journal.rs`) and keeps them through a
  20 s settle window after the first frame and over the render-scale, audio and
  mute calls that follow the scene (the changelog records a launch crash after
  applying a render scale). Two launches in a row that
  die mid-load hold the wallpaper out of every plan; Apply, the panel's
  Try again, an app update, or its removal from the library releases it, and
  nothing is deleted.
  `engine::load_journal::tests` and `tests::crash_loop_guard` (fake engine, a
  record that never ends playing the crash) must keep covering: a quit while startup holds the actor, one strike per
  dead session and wallpaper, the hold persisting across launches, a failed
  load and a quit during a load leaving no strike, only scenes that really open
  being recorded, Apply reaching the engine for an unchanged draft, a rotation leaving a hold alone, and a Try
  again or an Apply that fails leaving the wallpaper held, with a crash during an Apply counting a
  third strike (`PanelLibraryActionsTests` and `ShellBannersTests`
  cover the banner and the action). Choosing a held wallpaper again must reach
  the bridge even though its display still reads as showing it, while a
  rotation's or rule's activation of it stays a no-op
  (`WallpaperActivationRecoveryTests`). A real
  engine crash is not reproducible headlessly; see
  [crash recovery](../features/crash-recovery.md#verification).