//! A scene's first frame is drawn with the scaling, zoom and framing the host opened it
//! with, not with the renderer's defaults followed by a corrected second frame. The second
//! frame is the visible jump from "fit" to "fill" right after a wallpaper appears.
//!
//! The scene is a still card whose canvas (3:2) does not match the square surface, so fit
//! and fill draw different pictures. With every pass reusable and frames presented only
//! when the picture changes, a scene whose first frame is already right presents once.

use std::{
    fs,
    path::Path,
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};

use wallpaper_core::{
    DisplayDesc, PlaceholderStyle,
    owe::backend::{FirstFrameCallback, OweBackend},
    project::{ScalingMode, SceneDesc, SceneFraming},
    render::RendererCounterKind,
};

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// One opaque card drawn through its own shaders, with nothing that varies over time.
fn write_still_scene(root: &Path) -> String {
    write(
        &root.join("project.json"),
        r#"{"title":"Still card","type":"scene","file":"layout.json","general":{"properties":{}}}"#,
    );
    write(&root.join("models/card.json"), r#"{"width":160,"height":96,"material":"materials/card.json"}"#);
    write(
        &root.join("materials/card.json"),
        r#"{"passes":[{"shader":"card","blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]}"#,
    );
    write(
        &root.join("shaders/card.vert"),
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n\
         varying vec2 v_TexCoord;\nvoid main() {\ngl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n\
         v_TexCoord = a_TexCoord;\n}\n",
    );
    write(
        &root.join("shaders/card.frag"),
        "varying vec2 v_TexCoord;\nvoid main() {\ngl_FragColor = vec4(v_TexCoord, 0.4, 1.0);\n}\n",
    );
    write(
        &root.join("layout.json"),
        r#"{"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},"general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],"clearcolor":[0.1,0.2,0.3],"cameraparallax":false,"orthogonalprojection":{"width":384,"height":256}},"objects":[{"id":1,"name":"card","image":"models/card.json","origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]}"#,
    );
    root.join("project.json").to_string_lossy().into_owned()
}

fn main() {
    objc2::rc::autoreleasepool(|_| {
        let root = tempfile::tempdir().unwrap();
        let project = write_still_scene(&root.path().join("project"));
        let assets = root.path().join("assets");
        fs::create_dir_all(&assets).unwrap();

        let backend = OweBackend::initialize().unwrap();
        backend.set_counters_enabled(true).unwrap();
        backend.set_scene_optimization_enabled(true).unwrap();
        backend.set_scene_on_demand_enabled(true).unwrap();

        let display = DisplayDesc::new(1, 0, 0, 512, 512, 1.0);
        let layer = display.build_metal_layer(&PlaceholderStyle::default());
        let desc = SceneDesc::builder(display, project)
            .assets_path(assets.to_string_lossy().into_owned())
            .fps(60)
            .audio_muted(true)
            .build()
            .unwrap();

        let first_frame = Arc::new((Mutex::new(false), Condvar::new()));
        let callback: FirstFrameCallback = {
            let first_frame = Arc::clone(&first_frame);
            Arc::new(move || {
                *first_frame.0.lock().unwrap() = true;
                first_frame.1.notify_all();
            })
        };
        let mut scene = backend
            .open_scene(
                &desc,
                objc2::rc::Retained::as_ptr(&layer).cast_mut().cast(),
                ScalingMode::Fill,
                1.0,
                SceneFraming::CENTERED,
                None,
                Some(callback),
                None,
                None,
                None,
                None,
            )
            .unwrap();

        let (shown, changed) = &*first_frame;
        let (shown, timeout) = changed
            .wait_timeout_while(shown.lock().unwrap(), Duration::from_secs(30), |shown| !*shown)
            .unwrap();
        assert!(*shown && !timeout.timed_out(), "the scene never presented a frame");
        drop(shown);
        // Long enough for a corrected frame to follow, had the settings come after the first.
        std::thread::sleep(Duration::from_millis(600));

        let counters = scene.counters().unwrap();
        let presents = counters[RendererCounterKind::PresentRequests.index()];
        println!("presents {presents}, draws {}", counters[RendererCounterKind::DrawsExecuted.index()]);
        assert_eq!(presents, 1, "the first frame was presented with other settings and then corrected");

        scene.close().unwrap();
        backend.set_scene_on_demand_enabled(false).unwrap();
        backend.set_counters_enabled(false).unwrap();
    });
}
