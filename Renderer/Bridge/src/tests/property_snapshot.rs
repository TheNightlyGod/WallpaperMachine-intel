use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{
    BridgeErrorKind, BridgePropertyKind, BridgePropertyValue, BridgeWallpaperOptionsSnapshot,
    WallpaperBridge, api::BridgeBuilder, engine::FakeEngineFacade, paths::BridgePaths,
};

#[tokio::test]
async fn combo_snapshot_options_preserve_labels_and_use_editable_value_types() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "choice":{"type":"combo","value":1,"options":[
                        {"label":"English","value":1},
                        {"label":"日本語","value":"2"},
                        {"label":"Enabled","value":true},
                        {"label":"Color-like identifier","value":"0.1 0.2 0.3"}
                    ]}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    let choice = &snapshot.properties[0];
    assert_eq!(choice.kind, BridgePropertyKind::Combo);
    assert_eq!(choice.value, BridgePropertyValue::String { value: "1".into() });
    assert_eq!(choice.default_value, choice.value);
    assert_eq!(
        choice.combo_options.iter().map(|option| (option.label.as_str(), &option.value)).collect::<Vec<_>>(),
        vec![
            ("English", &BridgePropertyValue::String { value: "1".into() }),
            ("日本語", &BridgePropertyValue::String { value: "2".into() }),
            ("Enabled", &BridgePropertyValue::String { value: "true".into() }),
            ("Color-like identifier", &BridgePropertyValue::String { value: "0.1 0.2 0.3".into() }),
        ]
    );

    for option in &choice.combo_options {
        let edited = bridge
            .edit_property("100".to_string(), "choice".to_string(), option.value.clone())
            .await
            .unwrap()
            .wallpaper_options;
        assert_eq!(edited.properties[0].value, option.value);
    }
    let restored = bridge
        .restore_property_default("100".to_string(), "choice".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_eq!(restored.properties[0].value, choice.default_value);
    assert!(!restored.dirty);
}

/// The rows a host lists: every property no visibility rule hides.
fn assert_property_ids(snapshot: &BridgeWallpaperOptionsSnapshot, expected: &[&str]) {
    assert_eq!(
        snapshot
            .properties
            .iter()
            .filter(|property| property.enabled)
            .map(|property| property.id.as_str())
            .collect::<Vec<_>>(),
        expected
    );
}

/// Every property the project defines, listed or hidden, in authored order.
fn assert_defined_ids(snapshot: &BridgeWallpaperOptionsSnapshot, expected: &[&str]) {
    assert_eq!(
        snapshot.properties.iter().map(|property| property.id.as_str()).collect::<Vec<_>>(),
        expected
    );
}

#[tokio::test]
async fn conditional_snapshot_tracks_language_defaults_discard_and_hidden_overrides() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "language":{"type":"combo","value":"1","index":0,"options":[
                        {"label":"English","value":"1"},
                        {"label":"日本語","value":"2"}
                    ]},
                    "english":{"type":"bool","value":true,"index":1,"condition":"language.value == 1"},
                    "japanese":{"type":"text","text":"日本語","index":2,"condition":"language.value == 2"},
                    "dependent":{"type":"text","text":"Disabled","index":3,"condition":"!english.value"},
                    "malformed":{"type":"text","text":"Still visible","index":4,"condition":"language.value = 1"}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let initial = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert_property_ids(&initial, &["language", "english", "malformed"]);
    assert_defined_ids(&initial, &["language", "english", "japanese", "dependent", "malformed"]);

    let edited = bridge
        .edit_property("100".to_string(), "english".to_string(), BridgePropertyValue::Bool { value: false })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&edited, &["language", "english", "dependent", "malformed"]);

    let japanese = bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&japanese, &["language", "japanese", "dependent", "malformed"]);
    assert!(japanese.dirty);

    let restored = bridge
        .restore_property_default("100".to_string(), "language".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&restored, &["language", "english", "dependent", "malformed"]);
    let english = restored.properties.iter().find(|property| property.id == "english").unwrap();
    assert_eq!(english.value, BridgePropertyValue::Bool { value: false });
    assert!(english.dirty);

    bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap();
    let discarded = bridge
        .cancel_wallpaper_options("100".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_eq!(discarded.properties, initial.properties);
    assert!(!discarded.dirty);

    // A hidden property's authored default must still participate in conditions.
    let japanese_default = bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&japanese_default, &["language", "japanese", "malformed"]);
}

#[tokio::test]
async fn real_world_visibility_shapes_decide_row_visibility() {
    // Ids are synthetic; the rule shapes are the ones Workshop authors write:
    // trailing `&& true`, constant `false`, `&& false`, and a membership test
    // beside a boolean comparison.
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "master":{"type":"bool","value":true,"index":0},
                    "ske":{"type":"bool","value":true,"index":1},
                    "count":{"type":"slider","value":4,"min":0,"max":40,"step":1,"precision":0,"index":2},
                    "extras":{"type":"text","text":"Extras","index":3,
                        "condition":"ske.value == true && [3, 4, 5].includes(count.value)"},
                    "clock":{"type":"bool","value":true,"index":4,"condition":"master.value&&false"},
                    "never":{"type":"text","text":"Never","index":5,"condition":"false"},
                    "both":{"type":"text","text":"Both","index":6,
                        "condition":"master.value == true && ske.value && true"},
                    "after_clock":{"type":"text","text":"After clock","index":7,"condition":"clock.value"},
                    "opaque":{"type":"text","text":"Opaque","index":8,"condition":"master.value == ske.value"}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let initial = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    // `clock` and `never` are hidden for good, yet `clock`'s authored value
    // still feeds `after_clock`; the rule nobody can read leaves `opaque` shown.
    assert_property_ids(
        &initial,
        &["master", "ske", "count", "extras", "both", "after_clock", "opaque"],
    );
    assert_defined_ids(
        &initial,
        &[
            "master", "ske", "count", "extras", "clock", "never", "both", "after_clock", "opaque",
        ],
    );

    let count_outside_list = bridge
        .edit_property("100".to_string(), "count".to_string(), BridgePropertyValue::Number { value: 9.0 })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(
        &count_outside_list,
        &["master", "ske", "count", "both", "after_clock", "opaque"],
    );

    let count_in_list = bridge
        .edit_property("100".to_string(), "count".to_string(), BridgePropertyValue::Number { value: 5.0 })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(
        &count_in_list,
        &["master", "ske", "count", "extras", "both", "after_clock", "opaque"],
    );

    let master_off = bridge
        .edit_property("100".to_string(), "master".to_string(), BridgePropertyValue::Bool { value: false })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(
        &master_off,
        &["master", "ske", "count", "extras", "after_clock", "opaque"],
    );
    assert!(master_off.dirty);
}

#[tokio::test]
async fn a_property_hidden_by_a_rule_stays_in_the_snapshot_with_its_value_and_modified_state() {
    // A saved preset names properties by id, and the panel's Restore all defaults
    // has to know about values nobody can see, so a closed gate must not make its
    // property disappear from what the bridge reports.
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "gate":{"type":"bool","value":false,"index":0},
                    "detail":{"type":"textinput","value":"plain","index":1,"condition":"gate.value"},
                    "sealed":{"type":"slider","value":3,"min":0,"max":9,"step":1,"precision":0,
                        "index":2,"condition":"gate.value&&false"}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();
    let find = |snapshot: &BridgeWallpaperOptionsSnapshot, id: &str| {
        snapshot
            .properties
            .iter()
            .find(|property| property.id == id)
            .unwrap_or_else(|| panic!("{id} should stay in the snapshot"))
            .clone()
    };

    let closed = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_defined_ids(&closed, &["gate", "detail", "sealed"]);
    assert_property_ids(&closed, &["gate"]);
    let detail = find(&closed, "detail");
    assert!(!detail.enabled);
    assert_eq!(detail.value, BridgePropertyValue::String { value: "plain".into() });
    assert!(!detail.dirty && !detail.can_restore_defaults);

    // A value set while its gate is open is still there, and still modified,
    // once the gate closes; the renderer keeps reading it.
    bridge
        .edit_property("100".to_string(), "gate".to_string(), BridgePropertyValue::Bool { value: true })
        .await
        .unwrap();
    let opened = bridge
        .edit_property(
            "100".to_string(),
            "detail".to_string(),
            BridgePropertyValue::String { value: "typed".into() },
        )
        .await
        .unwrap()
        .wallpaper_options;
    assert!(find(&opened, "detail").enabled);
    let closed_again = bridge
        .edit_property("100".to_string(), "gate".to_string(), BridgePropertyValue::Bool { value: false })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&closed_again, &["gate"]);
    let detail = find(&closed_again, "detail");
    assert!(!detail.enabled);
    assert_eq!(detail.value, BridgePropertyValue::String { value: "typed".into() });
    assert!(detail.dirty && detail.can_restore_defaults);

    // Opening the gate again lists the row with that value, which is how a preset
    // sets a field its own mode switch opens.
    let reopened = bridge
        .edit_property("100".to_string(), "gate".to_string(), BridgePropertyValue::Bool { value: true })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&reopened, &["gate", "detail"]);
    assert_eq!(
        find(&reopened, "detail").value,
        BridgePropertyValue::String { value: "typed".into() }
    );
    bridge
        .edit_property("100".to_string(), "gate".to_string(), BridgePropertyValue::Bool { value: false })
        .await
        .unwrap();

    // A rule that is always false never opens, and the draft can still reach its row.
    let sealed = bridge
        .edit_property("100".to_string(), "sealed".to_string(), BridgePropertyValue::Number { value: 7.0 })
        .await
        .unwrap()
        .wallpaper_options;
    let sealed = find(&sealed, "sealed");
    assert!(!sealed.enabled);
    assert_eq!(sealed.value, BridgePropertyValue::Number { value: 7.0 });
    assert!(sealed.dirty);
}

#[tokio::test]
async fn user_shortcut_offers_the_actions_this_host_can_carry_out() {
    // The author declares that a shortcut exists and leaves its value empty;
    // what it does is the user's choice, so it has to reach them as a choice.
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test(
        "100",
        "Scene",
        r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "playpausebutton":{"type":"usershortcut","text":"Play/Pause","value":""}
            }}
        }"#,
    ).await;

    let snapshot = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    let property = snapshot
        .properties
        .iter()
        .find(|entry| entry.id == "playpausebutton")
        .expect("the shortcut property is described");

    assert_eq!(property.kind, BridgePropertyKind::Combo,
        "a shortcut the user cannot bind is a button that does nothing");
    let values: Vec<BridgePropertyValue> =
        property.combo_options.iter().map(|option| option.value.clone()).collect();
    assert_eq!(
        values,
        ["", "media:playpause", "media:next", "media:previous"]
            .map(|value| BridgePropertyValue::String { value: value.to_owned() })
            .to_vec()
    );
}

fn text_labels(snapshot: &BridgeWallpaperOptionsSnapshot) -> Vec<(&str, &str)> {
    snapshot
        .properties
        .iter()
        .map(|property| (property.id.as_str(), property.label_html.as_str()))
        .collect()
}

#[tokio::test]
async fn a_wallpapers_own_label_tables_follow_the_chosen_language() {
    // Synthetic ids; the shape is a Workshop project that keeps every label as
    // a `ui_` token with a table per language beside it.
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{
                    "localization":{
                        "en-us":{"ui_size":"Size","ui_mode":"Mode","ui_fast":"Fast","ui_normal":"Normal","ui_hint":"<b>Hint</b>"},
                        "zh-chs":{"ui_size":"大小","ui_mode":"模式","ui_normal":"普通","ui_hint":"<i>提示</i>"}
                    },
                    "properties":{
                        "size":{"type":"slider","text":"ui_size","value":1,"min":0,"max":2,"step":1,"precision":0,"index":0},
                        "mode":{"type":"combo","text":"  ui_mode ","value":"a","index":1,"options":[
                            {"label":"ui_fast","value":"a"},
                            {"label":"Slow","value":"b"},
                            {"label":"ui_normal","value":"c"}
                        ]},
                        "missing":{"type":"bool","text":"ui_missing","value":false,"index":2},
                        "hint":{"type":"text","text":"ui_hint","index":3},
                        "prose":{"type":"bool","text":"ui_size is not replaced mid-sentence","value":false,"index":4}
                    }
                }
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let english = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_eq!(
        text_labels(&english),
        [
            ("size", "Size"),
            ("mode", "Mode"),
            ("missing", "ui_missing"),
            ("hint", "<b>Hint</b>"),
            ("prose", "ui_size is not replaced mid-sentence"),
        ]
    );
    let combo_labels = |snapshot: &BridgeWallpaperOptionsSnapshot| {
        snapshot.properties[1]
            .combo_options
            .iter()
            .map(|option| option.label.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(combo_labels(&english), ["Fast", "Slow", "Normal"]);

    bridge
        .edit_property(
            "100".to_string(),
            "size".to_string(),
            BridgePropertyValue::Number { value: 2.0 },
        )
        .await
        .unwrap();
    // Options are stored by value, so the draft never sees the label text.
    let draft_before = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();

    bridge
        .set_label_languages(vec!["zh-CHS".to_owned(), "en-us".to_owned()])
        .await
        .unwrap();
    let chinese = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_eq!(
        text_labels(&chinese),
        [
            ("size", "大小"),
            // The token had spaces around it in the project; it still matches.
            ("mode", "模式"),
            ("missing", "ui_missing"),
            ("hint", "<i>提示</i>"),
            ("prose", "ui_size is not replaced mid-sentence"),
        ]
    );
    // zh-chs has no ui_fast, so English answers; Slow is no token at all.
    assert_eq!(combo_labels(&chinese), ["Fast", "Slow", "普通"]);
    // Switching language changes nothing but the words.
    assert_eq!(chinese.dirty, draft_before.dirty);
    assert_eq!(
        chinese.properties.iter().map(|p| (&p.id, &p.value, p.dirty)).collect::<Vec<_>>(),
        draft_before.properties.iter().map(|p| (&p.id, &p.value, p.dirty)).collect::<Vec<_>>()
    );

    bridge
        .set_label_languages(vec!["ja-jp".to_owned()])
        .await
        .unwrap();
    let japanese = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_eq!(
        text_labels(&japanese),
        text_labels(&english),
        "a language the project has no table for reads in English"
    );

    // Back to the first language, with no wallpaper reload in between.
    bridge
        .set_label_languages(vec!["en-us".to_owned()])
        .await
        .unwrap();
    let again = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_eq!(text_labels(&again), text_labels(&english));
    assert_eq!(combo_labels(&again), ["Fast", "Slow", "Normal"]);
}

#[tokio::test]
async fn a_project_without_a_label_table_is_unaffected_by_the_language() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "mode":{"type":"combo","text":"ui_mode","value":"a","options":[{"label":"ui_fast","value":"a"}]}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();
    bridge
        .set_label_languages(vec!["zh-chs".to_owned(), "".to_owned(), "!!".to_owned()])
        .await
        .unwrap();

    let snapshot = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    assert_eq!(snapshot.properties[0].label_html, "ui_mode");
    assert_eq!(snapshot.properties[0].combo_options[0].label, "ui_fast");
}

const RESTORE_ALL_PROJECT: &str = r#"{
    "type":"web",
    "title":"Web",
    "file":"index.html",
    "general":{"properties":{
        "flag":{"type":"bool","value":false,"text":"Flag","order":1},
        "size":{"type":"slider","value":10,"min":0,"max":100,"step":1,"precision":0,"text":"Size","order":2},
        "mode":{"type":"combo","value":"a","text":"Mode","order":3,"options":[
            {"label":"A","value":"a"},{"label":"B","value":"b"}]},
        "title":{"type":"textinput","value":"hello","text":"Title","order":4},
        "gate":{"type":"bool","value":false,"text":"Gate","order":5},
        "extra":{"type":"bool","value":false,"text":"Extra","order":6,"condition":"gate.value"},
        "clip":{"type":"file","fileType":"video","text":"Clip","order":7}
    }}
}"#;

/// A bridge with a web wallpaper applied on one display, so the committed
/// config (what the page is given) can be told apart from the editor's draft.
async fn applied_restore_all_bridge(home: &std::path::Path) -> WallpaperBridge {
    let engine = FakeEngineFacade::default();
    let desc =
        DisplayDesc::with_identity(7, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(BridgePaths::for_home(home))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test("100", "Web", RESTORE_ALL_PROJECT)
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge
}

async fn committed_page_values(bridge: &WallpaperBridge) -> serde_json::Value {
    let web = bridge.web_wallpapers().await.unwrap();
    let properties: serde_json::Value = serde_json::from_str(&web[0].properties_json).unwrap();
    let value = |id: &str| properties[id]["value"].clone();
    serde_json::json!({
        "flag": value("flag"), "size": value("size"), "mode": value("mode"),
        "title": value("title"), "extra": value("extra"), "clip": value("clip"),
    })
}

fn row<'a>(
    snapshot: &'a BridgeWallpaperOptionsSnapshot,
    id: &str,
) -> &'a crate::BridgePropertyDescriptor {
    snapshot
        .properties
        .iter()
        .find(|property| property.id == id)
        .unwrap_or_else(|| panic!("{id} should be offered"))
}

#[tokio::test]
async fn restore_all_stages_every_default_until_reverted() {
    let home = tempfile::tempdir().expect("home");
    let bridge = applied_restore_all_bridge(home.path()).await;
    let id = || "100".to_string();
    let edit = |property: &str, value: BridgePropertyValue| {
        let bridge = &bridge;
        let property = property.to_string();
        async move { bridge.edit_property("100".to_string(), property, value).await.unwrap() }
    };

    // Values the wallpaper is really using: edited, applied, then a file chosen
    // (which is saved the moment it is picked). `extra` is set while its gate is
    // open and left behind a closed one, so it carries an override nobody can see.
    edit("flag", BridgePropertyValue::Bool { value: true }).await;
    edit("size", BridgePropertyValue::Number { value: 42.0 }).await;
    edit("mode", BridgePropertyValue::String { value: "b".into() }).await;
    edit("title", BridgePropertyValue::String { value: "changed".into() }).await;
    edit("gate", BridgePropertyValue::Bool { value: true }).await;
    edit("extra", BridgePropertyValue::Bool { value: true }).await;
    edit("gate", BridgePropertyValue::Bool { value: false }).await;
    bridge.apply_wallpaper_options(id(), true).await.unwrap();
    bridge
        .set_property_path(id(), "clip".into(), Some("/chosen/clip.webm".into()))
        .await
        .unwrap();
    let before = bridge.wallpaper_options_snapshot(id()).await.unwrap();
    assert!(!before.dirty, "everything above is committed");
    let hidden = row(&before, "extra");
    assert!(!hidden.enabled && hidden.dirty, "the override behind the closed gate is reported");
    let committed_before = committed_page_values(&bridge).await;
    assert_eq!(committed_before["size"], 42.0);
    assert_eq!(committed_before["extra"], true);

    let staged = bridge
        .restore_all_property_defaults(id())
        .await
        .unwrap()
        .wallpaper_options;

    for (property, default) in [
        ("flag", BridgePropertyValue::Bool { value: false }),
        ("size", BridgePropertyValue::Number { value: 10.0 }),
        ("mode", BridgePropertyValue::String { value: "a".into() }),
        ("title", BridgePropertyValue::String { value: "hello".into() }),
    ] {
        let restored = row(&staged, property);
        assert_eq!(restored.value, default, "{property} should show its authored default");
        assert!(!restored.dirty, "{property} should no longer read as modified");
    }
    let clip = row(&staged, "clip");
    assert_eq!(
        clip.value,
        BridgePropertyValue::String { value: "/chosen/clip.webm".into() },
        "a chosen file belongs to its own Clear, not to restore all"
    );
    assert!(staged.dirty, "restoring is staged, so Apply and Revert are offered");
    assert_eq!(
        committed_page_values(&bridge).await,
        committed_before,
        "nothing reaches the wallpaper before Apply"
    );

    // The override behind the closed gate went too: it stops reading as modified
    // while still hidden, and opening the gate shows the default.
    assert!(!row(&staged, "extra").enabled && !row(&staged, "extra").dirty);
    let opened = edit("gate", BridgePropertyValue::Bool { value: true }).await.wallpaper_options;
    assert_eq!(row(&opened, "extra").value, BridgePropertyValue::Bool { value: false });
    assert!(!row(&opened, "extra").dirty);

    let reverted = bridge
        .cancel_wallpaper_options(id())
        .await
        .unwrap()
        .wallpaper_options;
    assert!(!reverted.dirty);
    assert_eq!(reverted.properties, before.properties);
    assert_eq!(row(&reverted, "size").value, BridgePropertyValue::Number { value: 42.0 });
    assert!(row(&reverted, "size").dirty, "the Modified state comes back with the value");

    bridge.restore_all_property_defaults(id()).await.unwrap();
    bridge.apply_wallpaper_options(id(), true).await.unwrap();
    let applied = bridge.wallpaper_options_snapshot(id()).await.unwrap();
    assert!(!applied.dirty);
    assert!(applied.properties.iter().filter(|property| property.id != "clip").all(|property| !property.dirty));
    let committed = committed_page_values(&bridge).await;
    assert_eq!(committed["size"], 10.0);
    assert_eq!(committed["flag"], false);
    assert_eq!(committed["mode"], "a");
    assert_eq!(committed["title"], "hello");
    assert_eq!(committed["extra"], false);
    assert_eq!(committed["clip"], "/chosen/clip.webm");
}

#[tokio::test]
async fn restore_all_is_a_no_op_when_nothing_differs_and_refuses_unknown_wallpapers() {
    let home = tempfile::tempdir().expect("home");
    let bridge = applied_restore_all_bridge(home.path()).await;
    let before = bridge.wallpaper_options_snapshot("100".into()).await.unwrap();

    let after = bridge
        .restore_all_property_defaults("100".into())
        .await
        .unwrap()
        .wallpaper_options;
    assert_eq!(after, before);
    assert!(!after.dirty);

    let error = bridge
        .restore_all_property_defaults("missing".into())
        .await
        .expect_err("an unknown wallpaper has no properties to restore");
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
}
