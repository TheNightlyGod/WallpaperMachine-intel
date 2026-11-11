use super::localization::*;
use super::*;
use crate::{BridgeError, BridgeErrorKind, BridgePropertyEdit, BridgePropertyValue};
use serde_json::{Map, Value, json};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use wallpaper_core::project::WallpaperProjectType;

fn parse_properties(entries: &str) -> ProjectModel {
    ProjectModel::parse(
        "synthetic/id",
        &format!(r#"{{"general":{{"properties":{entries}}}}}"#),
    )
    .unwrap()
}

fn property<'a>(model: &'a ProjectModel, id: &str) -> &'a ProjectProperty {
    model
        .properties
        .iter()
        .find(|property| property.id == id)
        .unwrap()
}

fn record(
    id: &str,
    kind: PropertyKind,
    metadata: PropertyMetadata,
    default_value: PropertyValue,
) -> ProjectProperty {
    ProjectProperty {
        id: id.to_owned(),
        kind,
        metadata,
        default_value,
        default_is_host_supplied: false,
        label_html: String::new(),
        order: 0.0,
        index: 0,
        condition: None,
    }
}

fn with_records(properties: Vec<ProjectProperty>) -> ProjectModel {
    ProjectModel {
        workshop_id: "invented".to_owned(),
        title: String::new(),
        description_html: String::new(),
        project_type: WallpaperProjectType::Unknown,
        preview_file: None,
        entry_file: None,
        properties,
        localization: Arc::new(ProjectLocalization::default()),
    }
}

fn slider_metadata() -> PropertyMetadata {
    PropertyMetadata::Slider {
        min: -2.0,
        max: 4.0,
        step: 0.75,
        precision: 0,
        fraction: true,
    }
}

fn combo_metadata() -> PropertyMetadata {
    PropertyMetadata::Combo {
        options: vec![ComboOption {
            label: "not a key".to_owned(),
            value: "chosen".to_owned(),
            json_value: json!(17),
        }],
    }
}

fn json_map(entries: &[(&str, Value)]) -> BTreeMap<String, Value> {
    entries
        .iter()
        .map(|(id, value)| ((*id).to_owned(), value.clone()))
        .collect()
}

fn project_failure<T: std::fmt::Debug>(result: Result<T, BridgeError>) {
    assert_eq!(result.unwrap_err().kind(), BridgeErrorKind::Project);
}

#[test]
fn project_envelopes_and_uninterpreted_text() {
    for invalid in ["{", "[]", "null", "7", "true", "\"object?\""] {
        project_failure(ProjectModel::parse("opaque", invalid));
    }
    for tolerated in [
        "{}",
        r#"{"general":null}"#,
        r#"{"general":[]}"#,
        r#"{"general":{"properties":8,"localization":false}}"#,
    ] {
        let model = ProjectModel::parse(" /no validation/ ", tolerated).unwrap();
        assert_eq!(model.workshop_id, " /no validation/ ");
        assert!(model.properties.is_empty());
        assert!(model.localization.is_empty());
        assert_eq!(model.project_type, WallpaperProjectType::Unknown);
        assert_eq!(model.title, "");
        assert_eq!(model.description_html, "");
    }
    let model = ProjectModel::parse("id", r#"{"title":"<b> authored </b>","description":" <i>raw</i> ","general":{"properties":{"retained":{"type":"OddKiNd","text":"<em>label</em>","condition":"  "},"skipped":3,"noType":{"type":false,"text":9,"condition":7}}}}"#).unwrap();
    assert_eq!(model.title, "<b> authored </b>");
    assert_eq!(model.description_html, " <i>raw</i> ");
    assert_eq!(model.properties.len(), 2);
    assert_eq!(
        property(&model, "retained").kind,
        PropertyKind::Unknown("OddKiNd".to_owned())
    );
    assert_eq!(property(&model, "retained").label_html, "<em>label</em>");
    assert_eq!(
        property(&model, "retained").condition.as_deref(),
        Some("  ")
    );
    assert_eq!(
        property(&model, "noType").kind,
        PropertyKind::Unknown(String::new())
    );
    assert_eq!(property(&model, "noType").label_html, "");
    assert_eq!(property(&model, "noType").condition, None);
    for (raw, expected) in [
        (json!("sCeNe"), WallpaperProjectType::Scene),
        (json!("VIDEO"), WallpaperProjectType::Video),
        (json!("Web"), WallpaperProjectType::Web),
        (json!(" web"), WallpaperProjectType::Unknown),
        (json!(8), WallpaperProjectType::Unknown),
    ] {
        let model = ProjectModel::parse(
            "id",
            &json!({"type":raw,"title":false,"description":null}).to_string(),
        )
        .unwrap();
        assert_eq!(model.project_type, expected);
        assert!(model.title.is_empty() && model.description_html.is_empty());
    }
}

#[test]
fn kinds_and_stable_fractional_signed_zero_order() {
    let cases = [
        ("sLiDeR", PropertyKind::Slider),
        ("COMBO", PropertyKind::Combo),
        ("Bool", PropertyKind::Bool),
        ("COLOR", PropertyKind::Color),
        ("TextInput", PropertyKind::TextInput),
        ("TEXT", PropertyKind::Text),
        ("Group", PropertyKind::Group),
        ("FILE", PropertyKind::File),
        ("Directory", PropertyKind::Directory),
        ("SceneTexture", PropertyKind::Texture),
        ("texture", PropertyKind::Texture),
        ("UserShortcut", PropertyKind::Combo),
        (" slider ", PropertyKind::Unknown(" slider ".to_owned())),
    ];
    for (name, expected) in cases {
        let model = parse_properties(&json!({"entry":{"type":name}}).to_string());
        assert_eq!(model.properties[0].kind, expected);
    }
    let model = parse_properties(
        r#"{"zeta":{"order":0.25,"index":2},"alpha":{"order":0.25,"index":2},"indexed":{"order":0.25,"index":-1},"negative":{"order":-0.0},"positive":{"order":0.0},"first":{"order":-0.5},"late":{"order":0.75}}"#,
    );
    assert_eq!(
        model
            .properties
            .iter()
            .map(|p| p.id.as_str())
            .collect::<Vec<_>>(),
        [
            "first", "negative", "positive", "indexed", "zeta", "alpha", "late"
        ]
    );
    assert!(property(&model, "negative").order.is_sign_negative());
    let odd = parse_properties(r#"{"s":{"type":"slider","min":9,"max":-4,"step":0}}"#);
    assert_eq!(
        odd.properties[0].metadata,
        PropertyMetadata::Slider {
            min: 9.0,
            max: -4.0,
            step: 0.0,
            precision: 2,
            fraction: false
        }
    );
}

#[test]
fn numeric_metadata_and_integer_only_fields() {
    for (precision, expected) in [
        ("0", 0),
        ("4294967295", u32::MAX),
        ("4294967296", 2),
        ("-1", 2),
        ("1.5", 2),
        ("3.0", 2),
        ("null", 2),
        ("\"4\"", 2),
    ] {
        let model = parse_properties(&format!(
            r#"{{"s":{{"type":"slider","precision":{precision},"min":"0","max":false,"step":null,"fraction":1}}}}"#
        ));
        assert_eq!(
            model.properties[0].metadata,
            PropertyMetadata::Slider {
                min: 0.0,
                max: 1.0,
                step: 0.01,
                precision: expected,
                fraction: false
            }
        );
    }
    let absent = parse_properties(
        r#"{"s":{"type":"slider"},"fraction":{"type":"slider","fraction":true,"min":-1.5,"max":2.25,"step":-0.3},"badOrder":{"order":"2"}}"#,
    );
    assert_eq!(
        property(&absent, "s").metadata,
        PropertyMetadata::Slider {
            min: 0.0,
            max: 1.0,
            step: 0.01,
            precision: 2,
            fraction: false
        }
    );
    assert_eq!(
        property(&absent, "fraction").metadata,
        PropertyMetadata::Slider {
            min: -1.5,
            max: 2.25,
            step: -0.3,
            precision: 2,
            fraction: true
        }
    );
    assert_eq!(property(&absent, "badOrder").order, 0.0);
    for (index, expected) in [
        ("-9223372036854775808", i64::MIN),
        ("9223372036854775807", i64::MAX),
        ("9223372036854775808", 0),
        ("-9223372036854775809", 0),
        ("2.0", 0),
        ("1.25", 0),
        ("\"2\"", 0),
        ("false", 0),
    ] {
        let model = parse_properties(&format!(r#"{{"item":{{"index":{index}}}}}"#));
        assert_eq!(model.properties[0].index, expected);
    }
}

#[test]
fn combo_option_payload_order_and_collisions() {
    let model = parse_properties(
        r#"{"c":{"type":"combo","value":"unlisted","text":"<b>raw</b>","options":[false,{"label":"<i>boolean</i>","value":true},{"value":"true"},{"label":3,"value":7},{},{"value":null},{"value":[2,false]},{"value":{"z":1,"a":2}}]}}"#,
    );
    let p = &model.properties[0];
    let PropertyMetadata::Combo { options } = &p.metadata else {
        panic!("combo metadata");
    };
    assert_eq!(options.len(), 7);
    assert_eq!(
        options.iter().map(|o| o.value.as_str()).collect::<Vec<_>>(),
        ["true", "true", "7", "", "", "[2,false]", r#"{"z":1,"a":2}"#]
    );
    assert_eq!(options[0].label, "<i>boolean</i>");
    assert_eq!(options[1].label, "");
    assert_eq!(options[2].label, "");
    assert_eq!(options[3].json_value, Value::Null);
    for (selection, expected) in [
        ("true", json!(true)),
        ("7", json!(7)),
        ("", Value::Null),
        ("[2,false]", json!([2, false])),
        (r#"{"z":1,"a":2}"#, json!({"z":1,"a":2})),
    ] {
        assert_eq!(
            p.web_value(&PropertyValue::String(selection.to_owned())),
            expected
        );
    }
    assert_eq!(p.label_html, "<b>raw</b>");
}

#[test]
fn filter_encounter_precedence_modes_and_texture() {
    for spelling in [
        "fileType",
        "FILETYPE",
        "FiLeTyPe",
        "file_type",
        "FILE_TYPE",
        "FiLe_TyPe",
    ] {
        let model =
            parse_properties(&json!({"f":{"type":"file",(spelling):"  ViDeO\t"}}).to_string());
        assert_eq!(
            model.properties[0].metadata,
            PropertyMetadata::File {
                filter: FileFilter {
                    media: FileMedia::Video,
                    raw: Some("  ViDeO\t".to_owned())
                }
            }
        );
    }
    let model = parse_properties(
        r#"{"a":{"type":"file","FILE_TYPE":false,"fileType":"video"},"b":{"type":"directory","fileType":" image ","file_type":"video","mode":" FeTcHaLl "},"c":{"type":"directory","file_type":"unrecognized","mode":"other"},"d":{"type":"directory","MODE":"fetchall"},"t":{"type":"texture","fileType":"video","mode":"fetchall"}}"#,
    );
    assert_eq!(
        property(&model, "a").metadata,
        PropertyMetadata::File {
            filter: FileFilter::default()
        }
    );
    assert_eq!(
        property(&model, "b").metadata,
        PropertyMetadata::Directory {
            filter: FileFilter {
                media: FileMedia::Image,
                raw: Some(" image ".to_owned())
            },
            mode: DirectoryMode::FetchAll
        }
    );
    assert_eq!(
        property(&model, "c").metadata,
        PropertyMetadata::Directory {
            filter: FileFilter {
                media: FileMedia::Image,
                raw: Some("unrecognized".to_owned())
            },
            mode: DirectoryMode::OnDemand
        }
    );
    assert_eq!(
        property(&model, "d").metadata,
        PropertyMetadata::Directory {
            filter: FileFilter::default(),
            mode: DirectoryMode::OnDemand
        }
    );
    assert_eq!(property(&model, "t").metadata, PropertyMetadata::Texture);
    assert_eq!(FileMedia::default(), FileMedia::Image);
    assert_eq!(DirectoryMode::default(), DirectoryMode::OnDemand);
    assert_eq!(
        model.user_asset_property_ids(),
        ["a", "b", "c", "d"]
            .map(str::to_owned)
            .into_iter()
            .collect()
    );
}

#[test]
fn shortcut_suggestion_priority_and_explicit_empty() {
    let cases = [
        ("xPLAYPAUSE_previous", "media:playpause"),
        ("previous_next", "media:previous"),
        ("prev_next", "media:previous"),
        ("next_pause", "media:next"),
        ("pause_play", "media:playpause"),
        ("play_only", "media:playpause"),
        ("other", ""),
        ("", ""),
    ];
    for (id, expected) in cases {
        let mut entries = Map::new();
        entries.insert(id.to_owned(), json!({"type":"usershortcut","value":""}));
        let model = parse_properties(&Value::Object(entries).to_string());
        let p = &model.properties[0];
        assert_eq!(p.default_value, PropertyValue::String(expected.to_owned()));
        assert_eq!(p.default_is_host_supplied, !expected.is_empty());
        let PropertyMetadata::Combo { options } = &p.metadata else {
            panic!("shortcut choices");
        };
        assert_eq!(
            options
                .iter()
                .map(|o| (o.label.as_str(), o.value.as_str()))
                .collect::<Vec<_>>(),
            [
                ("No action", ""),
                ("Play / Pause", "media:playpause"),
                ("Next Track", "media:next"),
                ("Previous Track", "media:previous")
            ]
        );
        let selected = model.apply_edit(BTreeMap::new(), id, PropertyValue::String(String::new()));
        assert_eq!(selected.contains_key(id), !expected.is_empty());
        assert_eq!(
            p.effective_value(&selected),
            PropertyValue::String(String::new())
        );
    }
    let authored = parse_properties(
        r#"{"next":{"type":"usershortcut","value":"authored:custom"},"play":{"type":"usershortcut","value":" "}}"#,
    );
    assert_eq!(
        property(&authored, "next").default_value,
        PropertyValue::String("authored:custom".to_owned())
    );
    assert_eq!(
        property(&authored, "play").default_value,
        PropertyValue::String(" ".to_owned())
    );
    assert!(
        authored
            .properties
            .iter()
            .all(|p| !p.default_is_host_supplied)
    );
}

struct TempProject(PathBuf);
impl TempProject {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        loop {
            let path = std::env::temp_dir().join(format!(
                "project-contract-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("cannot create isolated synthetic directory: {error}"),
            }
        }
    }
}
impl Drop for TempProject {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn load_joins_preview_without_containment_or_entry_resolution() {
    let temporary = TempProject::new();
    let manifest = temporary.0.join("manifest.json");
    for preview in ["thumbnail.png", "", "../outside.png"] {
        let text = json!({"preview":preview,"file":"  entry path  "}).to_string();
        std::fs::write(&manifest, &text).unwrap();
        let parsed = ProjectModel::parse("id", &text).unwrap();
        let loaded = ProjectModel::load("id", &manifest).unwrap();
        assert_eq!(parsed.preview_file, Some(PathBuf::from(preview)));
        assert_eq!(loaded.preview_file, Some(temporary.0.join(preview)));
        assert_eq!(loaded.entry_file.as_deref(), Some("  entry path  "));
    }
    let absolute = temporary.0.join("absolute.png");
    std::fs::write(&manifest, json!({"preview":absolute,"file":""}).to_string()).unwrap();
    let loaded = ProjectModel::load("id", &manifest).unwrap();
    assert_eq!(loaded.preview_file, Some(absolute));
    assert_eq!(loaded.entry_file, None);
    for body in [vec![0xff, 0xfe], b"[]".to_vec(), b"{".to_vec()] {
        std::fs::write(&manifest, body).unwrap();
        let error = ProjectModel::load("id", &manifest).unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::Project);
        assert!(error.message().contains(&manifest.display().to_string()));
    }
    let missing = temporary.0.join("not-created.json");
    let error = ProjectModel::load("id", &missing).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Project);
    assert!(error.message().contains(&missing.display().to_string()));
    for raw in [json!({}), json!({"file":null,"preview":3})] {
        let model = ProjectModel::parse("id", &raw.to_string()).unwrap();
        assert_eq!(model.preview_file, None);
        assert_eq!(model.entry_file, None);
    }
}

#[test]
fn generic_values_json_text_and_binary64_precision() {
    for (raw, value) in [
        (json!(true), PropertyValue::Bool(true)),
        (json!(2.5), PropertyValue::Number(2.5)),
        (json!("word"), PropertyValue::String("word".to_owned())),
        (Value::Null, PropertyValue::Null),
    ] {
        assert_eq!(PropertyValue::from_json(&raw), value);
        assert_eq!(value.to_json(), raw);
    }
    let object: Value = serde_json::from_str(r#"{"later":2,"earlier":1}"#).unwrap();
    for (raw, text) in [
        (object, r#"{"later":2,"earlier":1}"#),
        (json!([false, 3]), "[false,3]"),
    ] {
        let value = PropertyValue::from_json(&raw);
        assert_eq!(value, PropertyValue::String(text.to_owned()));
        assert_eq!(value.to_json(), json!(text));
        assert_eq!(PropertyValue::json_scalar_to_string(&raw), text);
    }
    let large: Value = serde_json::from_str("9007199254740993").unwrap();
    assert_eq!(
        PropertyValue::from_json(&large),
        PropertyValue::Number(9007199254740992.0)
    );
    assert_eq!(
        PropertyValue::json_scalar_to_string(&large),
        "9007199254740993"
    );
    for number in [f64::INFINITY, f64::NEG_INFINITY, f64::NAN] {
        assert_eq!(PropertyValue::Number(number).to_json(), Value::Null);
    }
    assert_eq!(PropertyValue::Null.to_property_string(), "");
    assert_eq!(PropertyValue::json_scalar_to_string(&Value::Null), "");
    assert_eq!(PropertyValue::json_scalar_to_string(&json!(false)), "false");
    assert_eq!(
        PropertyValue::json_scalar_to_string(&json!(" authored ")),
        " authored "
    );
    assert_ne!(PropertyValue::Null, PropertyValue::String(String::new()));
    assert_eq!(
        PropertyValue::String("0 0 0".to_owned()).as_color_rgb(),
        None
    );
    let color = PropertyValue::ColorRgb(0.12345679, 0.5, 1.0);
    assert_eq!(color.as_color_rgb(), Some((0.12345679, 0.5, 1.0)));
    assert_eq!(color.to_property_string(), "0.12345679 0.5 1");
    assert_eq!(color.to_json(), json!("0.12345679 0.5 1"));
}

#[test]
fn color_recognition_rounds_before_range_checks() {
    for invalid in [
        "0 1",
        "0 1 0 1",
        "zero 0 0",
        "NaN 0 0",
        "inf 0 0",
        "-0.01 0 0",
        "1.00000011920928955078125 0 0",
    ] {
        assert_eq!(
            PropertyValue::from_json(&json!(invalid)),
            PropertyValue::String(invalid.to_owned())
        );
    }
    assert_eq!(
        PropertyValue::from_json(&json!("\u{2003}0.25\t0.5\n1\u{a0}")),
        PropertyValue::ColorRgb(0.25, 0.5, 1.0)
    );
    let rounded = PropertyValue::from_json(&json!(
        "-0.000000000000000000000000000000000000000000000000001 1.00000001 0.100000001"
    ));
    let (red, green, blue) = rounded.as_color_rgb().unwrap();
    assert_eq!(red, 0.0);
    assert!(red.is_sign_negative());
    assert_eq!(green, 1.0);
    assert_eq!(blue, 0.1_f32);
    assert_eq!(rounded.to_property_string(), "-0 1 0.1");
}

#[test]
fn authored_paths_of_file_and_directory_properties_are_no_default() {
    // A path in project.json is the author's (or a Workshop preset's), never a pick of the
    // user's: staging it would copy the user's own folder for the page to read. Absolute or
    // relative, it is not the property's default.
    let model = parse_properties(
        r#"{"photos":{"type":"directory","mode":"fetchall","value":"/Users/someone/Pictures"},"cover":{"type":"file","value":"/Users/someone/Pictures/a.png"},"relative":{"type":"directory","value":"Users/someone/Movies"},"veil":{"type":"texture","value":"materials/veil.png"}}"#,
    );
    let none = BTreeMap::new();
    for id in ["photos", "cover", "relative"] {
        let property = property(&model, id);
        assert_eq!(property.default_value, PropertyValue::String(String::new()), "{id}");
        assert_eq!(property.effective_value(&none), PropertyValue::String(String::new()), "{id}");
        // The user choosing that same path is a choice, kept as an override.
        let picked = PropertyValue::String("/Users/someone/Pictures".to_owned());
        assert!(!property.value_is_default(&picked), "{id}");
        let overrides = BTreeMap::from([(id.to_owned(), picked.clone())]);
        assert_eq!(property.effective_value(&overrides), picked, "{id}");
    }
    // A texture's authored value names a picture in the package, and stays its default.
    assert_eq!(
        property(&model, "veil").default_value,
        PropertyValue::String("materials/veil.png".to_owned())
    );
}

#[test]
fn raw_defaults_and_kind_normalization_are_distinct() {
    let model = parse_properties(
        r#"{"combo":{"type":"combo","value":" 0.100000001 0.2 1 "},"input":{"type":"textinput","value":" 0.100000001 0.2 1 "},"file":{"type":"file"},"directory":{"type":"directory","value":null},"texture":{"type":"texture","value":null},"slider":{"type":"slider","value":2},"bool":{"type":"bool","value":true},"color":{"type":"color","value":"0 0.5 1"},"text":{"type":"text","value":"0 0.5 1"},"group":{"type":"group","value":false},"unknown":{"value":[1,2]},"missing":{"type":"bool"}}"#,
    );
    assert_eq!(
        property(&model, "combo").default_value,
        PropertyValue::String(" 0.100000001 0.2 1 ".to_owned())
    );
    assert_eq!(
        property(&model, "combo").default_value(),
        PropertyValue::String(" 0.100000001 0.2 1 ".to_owned())
    );
    assert_eq!(
        property(&model, "input").default_value,
        PropertyValue::ColorRgb(0.1, 0.2, 1.0)
    );
    assert_eq!(
        property(&model, "input").default_value(),
        PropertyValue::String("0.1 0.2 1".to_owned())
    );
    for id in ["file", "directory", "texture"] {
        assert_eq!(
            property(&model, id).default_value,
            PropertyValue::String(String::new())
        );
        assert_eq!(
            property(&model, id).default_value(),
            PropertyValue::String(String::new())
        );
    }
    for (id, expected) in [
        ("slider", PropertyValue::Number(2.0)),
        ("bool", PropertyValue::Bool(true)),
        ("color", PropertyValue::ColorRgb(0.0, 0.5, 1.0)),
        ("text", PropertyValue::ColorRgb(0.0, 0.5, 1.0)),
        ("group", PropertyValue::Bool(false)),
        ("unknown", PropertyValue::String("[1,2]".to_owned())),
        ("missing", PropertyValue::Null),
    ] {
        assert_eq!(property(&model, id).default_value, expected);
        assert_eq!(property(&model, id).default_value(), expected);
    }
    assert_eq!(
        property(&model, "missing").default_value,
        PropertyValue::Null
    );
    for name in ["combo", "textinput", "texture"] {
        let model = parse_properties(&json!({"v":{"type":name,"value":false}}).to_string());
        assert_eq!(
            model.properties[0].default_value(),
            PropertyValue::String("false".to_owned())
        );
    }
    for name in ["file", "directory"] {
        let model = parse_properties(&json!({"v":{"type":name,"value":false}}).to_string());
        assert_eq!(model.properties[0].default_value(), PropertyValue::String(String::new()));
    }
}

#[test]
fn default_tolerance_uses_machine_epsilon_and_ieee_classification() {
    let n = PropertyValue::Number;
    let eps = f64::EPSILON;
    assert!(n(0.0).matches_with_override_semantics(&n(eps)));
    assert!(!n(0.0).matches_with_override_semantics(&n(f64::from_bits(eps.to_bits() + 1))));
    assert!(n(1.0).matches_with_override_semantics(&n(f64::from_bits(1.0_f64.to_bits() + 1))));
    assert!(!n(1.0).matches_with_override_semantics(&n(f64::from_bits(1.0_f64.to_bits() + 2))));
    let large = 2.0_f64.powi(40);
    assert!(n(large).matches_with_override_semantics(&n(f64::from_bits(large.to_bits() + 1))));
    assert!(!n(large).matches_with_override_semantics(&n(f64::from_bits(large.to_bits() + 2))));
    assert!(n(-1.0).matches_with_override_semantics(&n(-f64::from_bits(1.0_f64.to_bits() + 1))));
    assert!(n(-0.0).matches_with_override_semantics(&n(0.0)));
    for infinity in [f64::INFINITY, f64::NEG_INFINITY] {
        assert!(n(infinity).matches_with_override_semantics(&n(infinity)));
        assert!(!n(infinity).matches_with_override_semantics(&n(-infinity)));
        assert!(!n(infinity).matches_with_override_semantics(&n(1.0)));
    }
    assert!(!n(f64::NAN).matches_with_override_semantics(&n(f64::NAN)));
    assert!(!n(1.0).matches_with_override_semantics(&PropertyValue::String("1".to_owned())));
    let zero = PropertyValue::ColorRgb(0.0, 0.0, 0.0);
    let epsilon = f32::EPSILON;
    let above = f32::from_bits(epsilon.to_bits() + 1);
    for channel in 0..3 {
        let mut rgb = [0.0; 3];
        rgb[channel] = epsilon;
        assert!(
            zero.matches_with_override_semantics(&PropertyValue::ColorRgb(rgb[0], rgb[1], rgb[2]))
        );
        rgb[channel] = above;
        assert!(
            !zero.matches_with_override_semantics(&PropertyValue::ColorRgb(rgb[0], rgb[1], rgb[2]))
        );
    }
    assert!(
        PropertyValue::ColorRgb(f32::INFINITY, -0.0, f32::NEG_INFINITY)
            .matches_with_override_semantics(&PropertyValue::ColorRgb(
                f32::INFINITY,
                0.0,
                f32::NEG_INFINITY
            ))
    );
    assert!(
        !PropertyValue::ColorRgb(f32::INFINITY, 0.0, 0.0)
            .matches_with_override_semantics(&PropertyValue::ColorRgb(f32::NEG_INFINITY, 0.0, 0.0))
    );
    assert!(
        !zero.matches_with_override_semantics(&PropertyValue::ColorRgb(epsilon, epsilon, above))
    );
    assert!(
        !PropertyValue::ColorRgb(f32::NAN, 0.0, 0.0)
            .matches_with_override_semantics(&PropertyValue::ColorRgb(f32::NAN, 0.0, 0.0))
    );
    assert!(!zero.matches_with_override_semantics(&PropertyValue::String("0 0 0".to_owned())));
}

#[test]
fn supplied_api_adapter_is_infallible_and_channelwise() {
    assert_eq!(
        PropertyValue::from(BridgePropertyValue::Bool { value: true }),
        PropertyValue::Bool(true)
    );
    assert_eq!(
        PropertyValue::from(BridgePropertyValue::Empty),
        PropertyValue::Null
    );
    assert_eq!(
        PropertyValue::from(BridgePropertyValue::String {
            value: "0 0 0".to_owned()
        }),
        PropertyValue::String("0 0 0".to_owned())
    );
    for number in [-0.0, 0.25, f64::INFINITY, f64::NEG_INFINITY, f64::NAN] {
        let PropertyValue::Number(converted) =
            PropertyValue::from(BridgePropertyValue::Number { value: number })
        else {
            panic!("number variant");
        };
        if number.is_nan() {
            assert!(converted.is_nan());
        } else {
            assert_eq!(converted.to_bits(), number.to_bits());
        }
    }
    let tie = 1.0 + 2.0_f64.powi(-24);
    let inputs = [
        [0.0, 0.5, 1.0],
        [
            tie,
            f64::from_bits(tie.to_bits() - 1),
            f64::from_bits(tie.to_bits() + 1),
        ],
        [-1e-300, 1e-300, -0.0],
        [-0.2, 1.2, f64::MAX],
        [f64::NAN, f64::INFINITY, f64::NEG_INFINITY],
    ];
    for [red, green, blue] in inputs {
        let actual = PropertyValue::from(BridgePropertyValue::ColorRgb { red, green, blue })
            .as_color_rgb()
            .unwrap();
        for (converted, source) in [actual.0, actual.1, actual.2]
            .into_iter()
            .zip([red, green, blue])
        {
            if source.is_nan() {
                assert!(converted.is_nan());
            } else {
                assert_eq!(converted.to_bits(), (source as f32).to_bits());
            }
        }
    }
}

#[test]
fn admission_table_includes_noncanonical_public_records() {
    let kinds = [
        PropertyKind::Slider,
        PropertyKind::Combo,
        PropertyKind::Bool,
        PropertyKind::Color,
        PropertyKind::TextInput,
        PropertyKind::Text,
        PropertyKind::Group,
        PropertyKind::File,
        PropertyKind::Directory,
        PropertyKind::Texture,
        PropertyKind::Unknown("future".to_owned()),
    ];
    for kind in kinds {
        let metadata = match kind {
            PropertyKind::Slider => slider_metadata(),
            PropertyKind::Combo => combo_metadata(),
            _ => PropertyMetadata::Unknown,
        };
        let model = with_records(vec![record(
            "target",
            kind.clone(),
            metadata,
            PropertyValue::Null,
        )]);
        let values = [
            BridgePropertyValue::Bool { value: true },
            BridgePropertyValue::Number { value: 0.3 },
            BridgePropertyValue::String {
                value: "chosen".to_owned(),
            },
            BridgePropertyValue::ColorRgb {
                red: 0.1,
                green: 0.2,
                blue: 0.3,
            },
            BridgePropertyValue::Empty,
        ];
        for (index, value) in values.iter().enumerate() {
            let expected = match kind {
                PropertyKind::Bool => index == 0,
                PropertyKind::Slider => index == 1,
                PropertyKind::Combo
                | PropertyKind::TextInput
                | PropertyKind::File
                | PropertyKind::Directory
                | PropertyKind::Texture => index == 2,
                PropertyKind::Color => index == 3,
                _ => false,
            };
            let outcome = model.check_edit("target", value);
            assert_eq!(
                outcome.is_ok(),
                expected,
                "{kind:?}, public value variant {index}"
            );
            if let Err(error) = outcome {
                assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
                assert!(error.message().contains("target"));
            }
        }
        if matches!(kind, PropertyKind::Slider | PropertyKind::Combo) {
            let mut mismatched = model.clone();
            mismatched.properties[0].metadata = PropertyMetadata::Bool;
            let value = if kind == PropertyKind::Slider {
                BridgePropertyValue::Number { value: 0.3 }
            } else {
                BridgePropertyValue::String {
                    value: "chosen".to_owned(),
                }
            };
            assert!(mismatched.check_edit("target", &value).is_err());
        }
    }
    let model = with_records(vec![
        record(
            "slider",
            PropertyKind::Slider,
            slider_metadata(),
            PropertyValue::Number(0.0),
        ),
        record(
            "color",
            PropertyKind::Color,
            PropertyMetadata::Group,
            PropertyValue::Null,
        ),
    ]);
    let original = model.clone();
    for value in [-2.0, 4.0, 0.314159] {
        assert!(
            model
                .check_edit("slider", &BridgePropertyValue::Number { value })
                .is_ok()
        );
    }
    for value in [
        f64::from_bits((-2.0_f64).to_bits() + 1),
        f64::from_bits(4.0_f64.to_bits() + 1),
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ] {
        assert!(
            model
                .check_edit("slider", &BridgePropertyValue::Number { value })
                .is_err()
        );
    }
    assert!(
        model
            .check_edit(
                "color",
                &BridgePropertyValue::ColorRgb {
                    red: -0.0,
                    green: 0.0,
                    blue: 1.0
                }
            )
            .is_ok()
    );
    for channel in 0..3 {
        for value in [
            -1e-300,
            1.0 + f64::EPSILON,
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
        ] {
            let mut rgb = [0.5; 3];
            rgb[channel] = value;
            assert!(
                model
                    .check_edit(
                        "color",
                        &BridgePropertyValue::ColorRgb {
                            red: rgb[0],
                            green: rgb[1],
                            blue: rgb[2]
                        }
                    )
                    .is_err()
            );
        }
    }
    assert_eq!((1.0 + f64::EPSILON) as f32, 1.0);
    let error = model
        .check_edit("absent", &BridgePropertyValue::Empty)
        .unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    assert!(error.message().contains("absent"));
    assert_eq!(model, original);
    let combo = with_records(vec![record(
        "combo",
        PropertyKind::Combo,
        combo_metadata(),
        PropertyValue::Null,
    )]);
    assert!(
        combo
            .check_edit(
                "combo",
                &BridgePropertyValue::String {
                    value: "not a key".to_owned()
                }
            )
            .is_err()
    );
}

#[test]
fn checked_requests_are_ordered_atomic_and_use_public_precision() {
    let model = with_records(vec![
        record(
            "flag",
            PropertyKind::Bool,
            PropertyMetadata::Unknown,
            PropertyValue::Bool(false),
        ),
        record(
            "rgb",
            PropertyKind::Color,
            PropertyMetadata::Unknown,
            PropertyValue::Null,
        ),
    ]);
    assert!(model.checked_edits(Vec::new()).unwrap().is_empty());
    let original = json_map(&[("stale", json!([1, 2]))]);
    let refused = model
        .checked_edits(vec![
            BridgePropertyEdit {
                property_id: "flag".to_owned(),
                value: BridgePropertyValue::Bool { value: true },
            },
            BridgePropertyEdit {
                property_id: "first_bad".to_owned(),
                value: BridgePropertyValue::Empty,
            },
            BridgePropertyEdit {
                property_id: "second_bad".to_owned(),
                value: BridgePropertyValue::Empty,
            },
        ])
        .unwrap_err();
    assert!(refused.message().contains("first_bad"));
    assert_eq!(original, json_map(&[("stale", json!([1, 2]))]));
    let request = vec![
        BridgePropertyEdit {
            property_id: "flag".to_owned(),
            value: BridgePropertyValue::Bool { value: true },
        },
        BridgePropertyEdit {
            property_id: "rgb".to_owned(),
            value: BridgePropertyValue::ColorRgb {
                red: 0.1,
                green: 0.333333333333,
                blue: 1.0,
            },
        },
        BridgePropertyEdit {
            property_id: "flag".to_owned(),
            value: BridgePropertyValue::Bool { value: false },
        },
    ];
    let edits = model.checked_edits(request).unwrap();
    assert_eq!(
        edits.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
        ["flag", "rgb", "flag"]
    );
    assert_eq!(
        edits[1].1,
        PropertyValue::ColorRgb(0.1_f64 as f32, 0.333333333333_f64 as f32, 1.0)
    );
    let changed = model.edited_overrides(&original, &edits);
    assert!(!changed.contains_key("flag"));
    assert_eq!(changed["rgb"], json!("0.1 0.33333334 1"));
    assert_eq!(original["stale"], json!([1, 2]));
    assert!(
        model
            .checked_edits(vec![BridgePropertyEdit {
                property_id: "rgb".to_owned(),
                value: BridgePropertyValue::ColorRgb {
                    red: 1.0 + f64::EPSILON,
                    green: 0.5,
                    blue: 0.5
                }
            }])
            .is_err()
    );
}

#[test]
fn persisted_values_are_kind_aware_without_edit_admission() {
    let model = parse_properties(
        r#"{"s":{"type":"slider","value":0.5},"b":{"type":"bool","value":true},"c":{"type":"color","value":"0.2 0.3 0.4"},"choice":{"type":"combo"},"input":{"type":"textinput"},"file":{"type":"file"},"dir":{"type":"directory"},"texture":{"type":"texture"},"text":{"type":"text"}}"#,
    );
    let s = property(&model, "s");
    for raw in [json!("-27.5"), json!(-27.5), json!("-2.75e1")] {
        assert_eq!(s.value_from_json(&raw), PropertyValue::Number(-27.5));
    }
    for raw in [
        json!(" 3"),
        json!("3 "),
        json!("NaN"),
        json!("inf"),
        json!(false),
        Value::Null,
        json!([]),
    ] {
        assert_eq!(s.value_from_json(&raw), PropertyValue::Number(0.5));
    }
    let b = property(&model, "b");
    for (raw, expected) in [
        (json!(false), false),
        (json!("FALSE"), false),
        (json!("0"), false),
        (json!("TrUe"), true),
        (json!("1"), true),
        (json!(0), true),
        (json!(" false"), true),
        (json!("false "), true),
    ] {
        assert_eq!(b.value_from_json(&raw), PropertyValue::Bool(expected));
    }
    for id in ["choice", "input", "file", "dir", "texture"] {
        for (raw, text) in [
            (Value::Null, ""),
            (json!([1, true]), "[1,true]"),
            (json!({"x":2}), r#"{"x":2}"#),
            (json!("0 0 0"), "0 0 0"),
        ] {
            assert_eq!(
                property(&model, id).value_from_json(&raw),
                PropertyValue::String(text.to_owned())
            );
        }
    }
    assert_eq!(
        property(&model, "c").value_from_json(&json!("not color")),
        PropertyValue::ColorRgb(0.2, 0.3, 0.4)
    );
    assert_eq!(
        property(&model, "c").value_from_json(&json!("0 0 1")),
        PropertyValue::ColorRgb(0.0, 0.0, 1.0)
    );
    assert_eq!(
        property(&model, "text").value_from_json(&json!(false)),
        PropertyValue::Bool(false)
    );
    let stored = json_map(&[("unknown", json!({"z":1,"a":2})), ("s", json!("30"))]);
    let values = model.override_values(&stored);
    assert_eq!(
        values["unknown"],
        PropertyValue::String(r#"{"z":1,"a":2}"#.to_owned())
    );
    assert_eq!(values["s"], PropertyValue::Number(30.0));
    let invalid = BTreeMap::from([("s".to_owned(), PropertyValue::Bool(false))]);
    assert_eq!(s.effective_value(&invalid), PropertyValue::Bool(false));
    assert_eq!(
        s.effective_value(&BTreeMap::new()),
        PropertyValue::Number(0.5)
    );
}

#[test]
fn direct_edits_prune_only_the_edited_default_and_normalize_existing_json() {
    let model =
        parse_properties(r#"{"s":{"type":"slider","value":0},"b":{"type":"bool","value":false}}"#);
    let values = BTreeMap::from([("unrelated".to_owned(), PropertyValue::Null)]);
    let values = model.apply_edit(values, "s", PropertyValue::Number(0.7));
    assert_eq!(values["s"], PropertyValue::Number(0.7));
    let values = model.apply_edit(values, "s", PropertyValue::Number(f64::EPSILON));
    assert!(!values.contains_key("s"));
    assert!(values.contains_key("unrelated"));
    let values = model.apply_edit(values, "unknown", PropertyValue::Null);
    assert_eq!(values["unknown"], PropertyValue::Null);
    let values = model.apply_edit(values, "s", PropertyValue::Bool(true));
    assert_eq!(values["s"], PropertyValue::Bool(true));
    let mut stored = json_map(&[
        ("s", json!("malformed")),
        ("b", json!("TrUe")),
        ("stale", json!([3, 4])),
        ("unrelated", Value::Null),
    ]);
    model.edit_overrides(&mut stored, "new", PropertyValue::String("raw".to_owned()));
    assert_eq!(stored["s"], json!(0.0));
    assert_eq!(stored["b"], json!(true));
    assert_eq!(stored["stale"], json!("[3,4]"));
    assert_eq!(stored["new"], json!("raw"));
    assert_eq!(stored["unrelated"], Value::Null);
    let untouched = json_map(&[("array", json!([1, 2]))]);
    assert_eq!(model.edited_overrides(&untouched, &[]), untouched);
    let edits = vec![
        (
            "new_color".to_owned(),
            PropertyValue::String("0.100000001 0.2 0.3".to_owned()),
        ),
        ("later".to_owned(), PropertyValue::Bool(true)),
        ("later".to_owned(), PropertyValue::Bool(false)),
    ];
    let changed = model.edited_overrides(&untouched, &edits);
    assert_eq!(changed["new_color"], json!("0.1 0.2 0.3"));
    assert_eq!(changed["later"], json!(false));
    assert_eq!(untouched["array"], json!([1, 2]));
}

#[test]
fn flat_documents_are_sorted_compact_and_use_generic_values() {
    let empty: BTreeMap<String, PropertyValue> = BTreeMap::new();
    assert_eq!(empty.to_override_json(), "{}");
    assert_eq!(scene_property_override_json(None, &BTreeMap::new()), None);
    let values = BTreeMap::from([
        ("z".to_owned(), PropertyValue::Number(f64::NAN)),
        ("a".to_owned(), PropertyValue::ColorRgb(0.1, 0.2, 0.3)),
    ]);
    assert_eq!(values.to_override_json(), r#"{"a":"0.1 0.2 0.3","z":null}"#);
    let model = parse_properties(
        r#"{"next":{"type":"usershortcut","value":""},"authored":{"type":"bool","value":true}}"#,
    );
    assert_eq!(
        scene_property_override_json(Some(&model), &BTreeMap::new()).as_deref(),
        Some(r#"{"next":"media:next"}"#)
    );
    let overrides = json_map(&[
        ("next", json!("")),
        ("unknown", json!([4, false])),
        ("color", json!(" 0.100000001 0.2 0.3 ")),
    ]);
    let expected = r#"{"color":"0.1 0.2 0.3","next":"","unknown":"[4,false]"}"#;
    let preview = scene_property_override_json(Some(&model), &overrides);
    let apply = scene_property_override_json(Some(&model), &overrides);
    assert_eq!(preview.as_deref(), Some(expected));
    assert_eq!(preview, apply);
    assert_eq!(
        scene_property_override_json(None, &overrides).as_deref(),
        Some(expected)
    );
    let authored_only = parse_properties(r#"{"plain":{"type":"bool","value":true}}"#);
    assert_eq!(
        scene_property_override_json(Some(&authored_only), &BTreeMap::new()),
        None
    );
    let slider = parse_properties(r#"{"s":{"type":"slider","value":4}}"#);
    assert_eq!(
        scene_property_override_json(Some(&slider), &json_map(&[("s", json!("invalid"))]))
            .as_deref(),
        Some(r#"{"s":"invalid"}"#)
    );
}

#[test]
fn web_restoration_depends_on_metadata_not_admission_kind() {
    let p = record(
        "odd",
        PropertyKind::Bool,
        combo_metadata(),
        PropertyValue::Bool(true),
    );
    assert_eq!(
        p.web_value(&PropertyValue::String("chosen".to_owned())),
        json!(17)
    );
    assert_eq!(
        p.web_value(&PropertyValue::String("else".to_owned())),
        json!("else")
    );
    assert_eq!(p.web_value(&PropertyValue::Bool(true)), json!(true));
    let combo_without = record(
        "odd",
        PropertyKind::Combo,
        PropertyMetadata::Bool,
        PropertyValue::Bool(true),
    );
    assert_eq!(
        combo_without.web_value(&PropertyValue::String("chosen".to_owned())),
        json!("chosen")
    );
    let fallback = record(
        "fallback",
        PropertyKind::Combo,
        PropertyMetadata::Combo {
            options: Vec::new(),
        },
        PropertyValue::Bool(true),
    );
    assert_eq!(
        fallback.default_value(),
        PropertyValue::String("true".to_owned())
    );
    assert_eq!(
        fallback.web_value(&PropertyValue::String("true".to_owned())),
        json!(true)
    );
    let model = with_records(vec![p, combo_without]);
    assert!(
        model
            .check_edit(
                "odd",
                &BridgePropertyValue::String {
                    value: "chosen".to_owned()
                }
            )
            .is_err()
    );
}

#[test]
fn live_asset_values_follow_committed_presence_not_drafts() {
    let model = parse_properties(
        r#"{"f":{"type":"file"},"d":{"type":"directory"},"t":{"type":"texture"},"ordinary":{"type":"bool"},"removed":{"type":"bool"}}"#,
    );
    let committed = json_map(&[
        ("f", json!("committed-file")),
        ("t", json!("committed-texture")),
        ("ordinary", json!(false)),
        ("removed", json!(true)),
        ("old_unknown", json!(1)),
    ]);
    let current = json_map(&[
        ("f", json!("draft-file")),
        ("d", json!("draft-directory")),
        ("ordinary", json!(true)),
        ("new_unknown", json!({"v":2})),
    ]);
    let live = model.live_property_overrides(&committed, &current);
    assert_eq!(
        live,
        json_map(&[
            ("f", json!("committed-file")),
            ("t", json!("committed-texture")),
            ("ordinary", json!(true)),
            ("new_unknown", json!({"v":2}))
        ])
    );
    assert_eq!(
        model.user_asset_property_ids(),
        BTreeSet::from(["d".to_owned(), "f".to_owned()])
    );
    let second = model.live_property_overrides(
        &json_map(&[("d", json!("kept-directory"))]),
        &json_map(&[("t", json!("new-texture"))]),
    );
    assert_eq!(second, json_map(&[("d", json!("kept-directory"))]));
}

fn expression(input: &str, values: &BTreeMap<String, PropertyValue>) -> bool {
    Condition::parse(input)
        .unwrap()
        .eval(&|id| values.get(id).cloned())
}

fn condition_failure(input: &str) {
    let error = Condition::parse(input).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Project);
    assert!(error.message().starts_with("condition parse error at "));
    assert!(error.message().contains(": "));
}

#[test]
fn expression_binding_operators_keywords_and_lists() {
    let mut values = BTreeMap::from([
        ("a".to_owned(), PropertyValue::Bool(true)),
        ("b".to_owned(), PropertyValue::Bool(false)),
        ("c".to_owned(), PropertyValue::Bool(false)),
        ("level".to_owned(), PropertyValue::Number(4.0)),
        ("true".to_owned(), PropertyValue::Bool(false)),
        ("false".to_owned(), PropertyValue::Bool(true)),
    ]);
    assert!(expression("a.value || b.value && c.value", &values));
    assert!(!expression("(a.value || b.value) && c.value", &values));
    values.insert("a".to_owned(), PropertyValue::Bool(false));
    values.insert("b".to_owned(), PropertyValue::Bool(true));
    values.insert("c".to_owned(), PropertyValue::Bool(true));
    assert!(expression("a.value || b.value && c.value", &values));
    assert!(!expression("!level.value == 4", &values));
    assert!(expression("!!level.value == 4", &values));
    assert!(expression("!!!false", &values));
    assert!(!expression("true.value", &values));
    assert!(expression("false.value", &values));
    for (op, equal, greater) in [
        ("==", true, false),
        ("===", true, false),
        ("!=", false, true),
        ("!==", false, true),
        ("<=", true, false),
        ("<", false, false),
        (">=", true, true),
        (">", false, true),
    ] {
        assert_eq!(expression(&format!("level.value {op} 4"), &values), equal);
        assert_eq!(expression(&format!("level.value {op} 3"), &values), greater);
    }
    assert!(expression(
        "[false, 4, 'four'].includes(level.value)",
        &values
    ));
    assert!(!expression("[].includes(level.value)", &values));
    for invalid in [
        "level.Value",
        "[4].Includes(level.value)",
        "[4].includes(level.VALUE)",
        "[4,].includes(level.value)",
        "[4].includes(level.value || true)",
    ] {
        condition_failure(invalid);
    }
}

#[test]
fn expression_string_and_decimal_grammar_is_not_javascript_or_json() {
    let values = BTreeMap::from([
        (
            "v".to_owned(),
            PropertyValue::String("café\n\\\"quoted\"".to_owned()),
        ),
        ("n".to_owned(), PropertyValue::Number(-0.5)),
    ]);
    assert!(expression("v.value == 'café\n\\\"quoted\"'", &values));
    assert!(expression(
        "v.value == \"café\n\\'other'\"",
        &BTreeMap::from([(
            "v".to_owned(),
            PropertyValue::String("café\n\\'other'".to_owned())
        )])
    ));
    assert!(expression("\t\r\nn.value == -.5 \x0c", &values));
    assert!(expression("n.value == -000.500", &values));
    for invalid in [
        "n.value == .5",
        "n.value == +1",
        "n.value == 1e2",
        "n.value == 1x",
        "n.value == 1_0",
        "n.value == 1.2.3",
        "n.value == 1.",
        "n.value == -.",
        "4",
        "'text'",
        "bare",
        "",
        "   ",
        "n.value == 1 == 1",
        "n.value == other.value",
        "n.value = 1",
        "true trailing",
        "n.value &&",
        "[1]",
        "TRUE",
        "\u{a0}true",
        "true\u{2003}",
        "n.value == 'unterminated",
        "n.value == 'a\\'b'",
    ] {
        condition_failure(invalid);
    }
    let huge = "9".repeat(400);
    let parsed = Condition::parse(&format!("n.value == {huge}")).unwrap();
    assert!(
        matches!(parsed,Condition::Compare(_,CmpOp::Eq,Literal::Number(number)) if number==f64::INFINITY)
    );
    assert!(parsed.eval(&|_| Some(PropertyValue::Number(f64::INFINITY))));
}

#[test]
fn expression_limits_are_bytes_active_depth_and_list_count() {
    let prefix = "v.value=='";
    let suffix = "'";
    let body = "é".repeat((2048 - prefix.len() - suffix.len()) / 2);
    let mut exact = format!("{prefix}{body}{suffix}");
    if exact.len() < 2048 {
        exact.insert(exact.len() - 1, 'x');
    }
    assert_eq!(exact.len(), 2048);
    assert!(Condition::parse(&exact).is_ok());
    exact.push(' ');
    condition_failure(&exact);
    assert!(Condition::parse(&format!("{}true", "!".repeat(24))).is_ok());
    condition_failure(&format!("{}true", "!".repeat(25)));
    assert!(Condition::parse(&format!("{}true{}", "(".repeat(24), ")".repeat(24))).is_ok());
    condition_failure(&format!("{}true{}", "(".repeat(25), ")".repeat(25)));
    let inner = format!("{}[].includes(v.value)", "!".repeat(12));
    assert!(Condition::parse(&format!("{}{inner}{}", "(".repeat(12), ")".repeat(12))).is_ok());
    condition_failure(&format!("{}!{inner}{}", "(".repeat(12), ")".repeat(12)));
    let list = vec!["0"; 256].join(",");
    assert!(!expression(
        &format!("[{list}].includes(v.value)"),
        &BTreeMap::from([("v".to_owned(), PropertyValue::Number(1.0))])
    ));
    condition_failure(&format!("[{list},0].includes(v.value)"));
    let flat = vec!["false"; 200].join("||");
    assert!(!expression(&flat, &BTreeMap::new()));
    assert!(expression(&format!("{flat}||true"), &BTreeMap::new()));
}

#[test]
fn expression_truthiness_and_asymmetric_coercions() {
    let truth = Condition::Truthy("any".to_owned());
    for (value, expected) in [
        (PropertyValue::Bool(false), false),
        (PropertyValue::Bool(true), true),
        (PropertyValue::Number(0.0), false),
        (PropertyValue::Number(-0.0), false),
        (PropertyValue::Number(-0.1), true),
        (PropertyValue::Number(f64::NAN), true),
        (PropertyValue::String(" \n".to_owned()), false),
        (PropertyValue::String(" 0 ".to_owned()), false),
        (PropertyValue::String(" FaLsE ".to_owned()), false),
        (PropertyValue::String("0.0".to_owned()), true),
        (PropertyValue::String("off".to_owned()), true),
        (PropertyValue::ColorRgb(0.0, 0.0, 0.0), true),
        (PropertyValue::Null, false),
    ] {
        assert_eq!(truth.eval(&|_| Some(value.clone())), expected);
    }
    let cases = [
        (
            PropertyValue::Number(1.0),
            CmpOp::Eq,
            Literal::Number(1.0),
            true,
        ),
        (
            PropertyValue::Number(1.0 + f64::EPSILON),
            CmpOp::Eq,
            Literal::Number(1.0),
            false,
        ),
        (
            PropertyValue::Bool(true),
            CmpOp::Eq,
            Literal::Number(1.0),
            true,
        ),
        (
            PropertyValue::Bool(false),
            CmpOp::Lt,
            Literal::Bool(true),
            true,
        ),
        (
            PropertyValue::Bool(true),
            CmpOp::Eq,
            Literal::Bool(true),
            true,
        ),
        (
            PropertyValue::Number(1.0),
            CmpOp::Eq,
            Literal::Bool(true),
            false,
        ),
        (
            PropertyValue::Number(1.0),
            CmpOp::Eq,
            Literal::String("1".to_owned()),
            true,
        ),
        (
            PropertyValue::Bool(true),
            CmpOp::Eq,
            Literal::String("true".to_owned()),
            true,
        ),
        (
            PropertyValue::String("true".to_owned()),
            CmpOp::Eq,
            Literal::Bool(true),
            true,
        ),
        (
            PropertyValue::String("1".to_owned()),
            CmpOp::Eq,
            Literal::Number(1.0),
            true,
        ),
        (
            PropertyValue::String(" 1 ".to_owned()),
            CmpOp::Eq,
            Literal::Number(1.0),
            false,
        ),
        (
            PropertyValue::String(" 1 ".to_owned()),
            CmpOp::Ge,
            Literal::Number(1.0),
            true,
        ),
        (
            PropertyValue::String("garbage".to_owned()),
            CmpOp::Le,
            Literal::String("also garbage".to_owned()),
            true,
        ),
        (
            PropertyValue::ColorRgb(0.1, 0.2, 0.3),
            CmpOp::Eq,
            Literal::String("0.1 0.2 0.3".to_owned()),
            true,
        ),
        (
            PropertyValue::ColorRgb(0.1, 0.2, 0.3),
            CmpOp::Ge,
            Literal::Number(0.0),
            true,
        ),
        (
            PropertyValue::Null,
            CmpOp::Eq,
            Literal::String(String::new()),
            true,
        ),
        (PropertyValue::Null, CmpOp::Eq, Literal::Number(0.0), false),
        (PropertyValue::Null, CmpOp::Le, Literal::Bool(false), true),
        (
            PropertyValue::Number(f64::NAN),
            CmpOp::Eq,
            Literal::Number(f64::NAN),
            false,
        ),
        (
            PropertyValue::Number(f64::NAN),
            CmpOp::Ne,
            Literal::Number(f64::NAN),
            true,
        ),
        (
            PropertyValue::Number(f64::NAN),
            CmpOp::Ge,
            Literal::Number(0.0),
            false,
        ),
        (
            PropertyValue::String("NaN".to_owned()),
            CmpOp::Eq,
            Literal::String("NaN".to_owned()),
            true,
        ),
        (
            PropertyValue::String("NaN".to_owned()),
            CmpOp::Le,
            Literal::Number(0.0),
            false,
        ),
        (
            PropertyValue::String("inf".to_owned()),
            CmpOp::Gt,
            Literal::Number(4.0),
            true,
        ),
        (
            PropertyValue::Number(f64::INFINITY),
            CmpOp::Eq,
            Literal::Number(f64::INFINITY),
            true,
        ),
    ];
    for (value, op, literal, expected) in cases {
        let condition = Condition::Compare("any".to_owned(), op, literal.clone());
        assert_eq!(
            condition.eval(&|_| Some(value.clone())),
            expected,
            "{value:?} {op:?} {literal:?}"
        );
        if op == CmpOp::Eq {
            assert_eq!(
                Condition::In("any".to_owned(), vec![literal]).eval(&|_| Some(value.clone())),
                expected
            );
        }
    }
}

#[test]
fn missing_atoms_short_circuit_and_unreadable_count_are_distinct() {
    for input in [
        "missing.value",
        "missing.value != 4",
        "[].includes(missing.value)",
    ] {
        assert!(expression(input, &BTreeMap::new()));
        assert!(!expression(&format!("!({input})"), &BTreeMap::new()));
    }
    assert!(!expression("missing.value && false", &BTreeMap::new()));
    assert!(expression("missing.value || false", &BTreeMap::new()));
    let calls = RefCell::new(Vec::new());
    let lookup = |id: &str| {
        calls.borrow_mut().push(id.to_owned());
        Some(PropertyValue::Bool(id == "yes"))
    };
    assert!(
        Condition::parse("yes.value || skipped.value")
            .unwrap()
            .eval(&lookup)
    );
    assert_eq!(*calls.borrow(), vec!["yes".to_owned()]);
    calls.borrow_mut().clear();
    assert!(
        !Condition::parse("no.value && skipped.value")
            .unwrap()
            .eval(&lookup)
    );
    assert_eq!(*calls.borrow(), vec!["no".to_owned()]);
    calls.borrow_mut().clear();
    assert!(
        Condition::parse("no.value || yes.value")
            .unwrap()
            .eval(&lookup)
    );
    assert_eq!(*calls.borrow(), vec!["no".to_owned(), "yes".to_owned()]);
    let model = parse_properties(
        r#"{"absent":{"type":"bool"},"blank":{"condition":" \n\t"},"bad":{"condition":"x+"},"alsoBad":{"condition":"v.Value"},"hidden":{"type":"bool","condition":"false","value":true}}"#,
    );
    assert_eq!(model.unreadable_condition_count(), 2);
    let overrides = BTreeMap::from([("hidden".to_owned(), PropertyValue::Bool(false))]);
    assert_eq!(
        property(&model, "hidden").effective_value(&overrides),
        PropertyValue::Bool(false)
    );
    assert!(!property(&model, "hidden").value_is_default(&PropertyValue::Bool(false)));
    assert!(
        model
            .apply_edit(overrides, "absent", PropertyValue::Bool(true))
            .contains_key("hidden")
    );
}

#[test]
fn public_expression_construction_remains_unrestricted_and_matchable() {
    use super::condition::{
        CmpOp as NestedOp, Condition as NestedCondition, Literal as NestedLiteral,
    };
    let id = "not a textual ID / ☂".to_owned();
    let atom = NestedCondition::Compare(
        id.clone(),
        NestedOp::Eq,
        NestedLiteral::String("quoted ' \" and newline\n".to_owned()),
    );
    assert!(atom.eval(&|key| {
        assert_eq!(key, id);
        Some(PropertyValue::String(
            "quoted ' \" and newline\n".to_owned(),
        ))
    }));
    let values = [
        Condition::Const(true),
        Condition::Truthy(id.clone()),
        atom.clone(),
        Condition::In(id.clone(), vec![Literal::Bool(true)]),
        Condition::Not(Box::new(Condition::Const(false))),
        Condition::And(
            Box::new(Condition::Const(true)),
            Box::new(Condition::Const(true)),
        ),
        Condition::Or(
            Box::new(Condition::Const(false)),
            Box::new(Condition::Const(true)),
        ),
    ];
    let mut seen = [false; 7];
    for value in values {
        assert_eq!(value.clone(), value);
        assert!(!format!("{value:?}").is_empty());
        let index = match value {
            NestedCondition::Const(_) => 0,
            NestedCondition::Truthy(_) => 1,
            NestedCondition::Compare(_, _, _) => 2,
            NestedCondition::In(_, _) => 3,
            NestedCondition::Not(_) => 4,
            NestedCondition::And(_, _) => 5,
            NestedCondition::Or(_, _) => 6,
        };
        seen[index] = true;
    }
    assert!(seen.into_iter().all(|seen| seen));
    let ops = [
        CmpOp::Eq,
        CmpOp::Ne,
        CmpOp::Ge,
        CmpOp::Le,
        CmpOp::Gt,
        CmpOp::Lt,
    ];
    let expected = [true, false, true, true, false, false];
    for (op, expected) in ops.into_iter().zip(expected) {
        let copy: NestedOp = op;
        let _still_copy = op;
        assert_eq!(
            Condition::Compare(id.clone(), copy, Literal::Number(f64::INFINITY))
                .eval(&|_| Some(PropertyValue::Number(f64::INFINITY))),
            expected
        );
        let _tag = match copy {
            NestedOp::Eq => 0,
            NestedOp::Ne => 1,
            NestedOp::Ge => 2,
            NestedOp::Le => 3,
            NestedOp::Gt => 4,
            NestedOp::Lt => 5,
        };
    }
    for literal in [
        Literal::Number(3.0),
        Literal::String("x".repeat(3000)),
        Literal::Bool(true),
    ] {
        assert_eq!(literal.clone(), literal);
        assert!(!format!("{literal:?}").is_empty());
        match literal {
            NestedLiteral::Number(value) => assert_eq!(value, 3.0),
            NestedLiteral::String(value) => assert_eq!(value.len(), 3000),
            NestedLiteral::Bool(value) => assert!(value),
        }
    }
    assert!(
        !Condition::Compare(id.clone(), CmpOp::Eq, Literal::Number(f64::NAN))
            .eval(&|_| Some(PropertyValue::Number(f64::NAN)))
    );
    assert!(
        Condition::In(id.clone(), vec![Literal::Number(f64::INFINITY)])
            .eval(&|_| Some(PropertyValue::Number(f64::INFINITY)))
    );
    assert!(
        Condition::Truthy(id.clone())
            .eval(&|_| Some(PropertyValue::String("not false".to_owned())))
    );
    let long = "x".repeat(3000);
    assert!(
        Condition::In(id.clone(), vec![Literal::String(long.clone())])
            .eval(&|_| Some(PropertyValue::String(long.clone())))
    );
    assert!(!Condition::Not(Box::new(Condition::Truthy(id))).eval(&|_| None));
    assert!(
        Condition::And(
            Box::new(Condition::Const(true)),
            Box::new(Condition::Or(
                Box::new(Condition::Const(false)),
                Box::new(Condition::Const(true))
            ))
        )
        .eval(&|_| panic!("constant trees do not look up values"))
    );
}

fn localization_from_tables(tables: Map<String, Value>) -> ProjectLocalization {
    ProjectLocalization::from_general(&Map::from_iter([(
        "localization".to_owned(),
        Value::Object(tables),
    )]))
}

#[test]
fn locale_codes_and_raw_whitespace_lookup_follow_byte_rules() {
    for (input, expected) in [
        ("EN_us", Some("en-us")),
        ("a1", Some("a1")),
        ("--", Some("--")),
        ("12_-", Some("12--")),
        ("abcdefghijkl", Some("abcdefghijkl")),
        ("a", None),
        ("abcdefghijklm", None),
        (" en", None),
        ("en ", None),
        ("éé", None),
        ("en.us", None),
        ("", None),
    ] {
        assert_eq!(normalize_locale(input).as_deref(), expected);
    }
    for general in [
        Map::new(),
        Map::from_iter([("localization".to_owned(), Value::Null)]),
        Map::from_iter([("localization".to_owned(), json!([]))]),
    ] {
        assert!(ProjectLocalization::from_general(&general).is_empty());
    }
    let raw:Value=serde_json::from_str(r#"{"EN_us":{"token":" <b>verbatim</b> "," spaced ":"kept but unreachable","empty":" \n","bad":4," ":"ignored"},"fr-fr":[],"invalid code":{"x":"x"},"--":{"token":"punctuation locale"}}"#).unwrap();
    let tables = localization_from_tables(raw.as_object().unwrap().clone());
    assert!(!tables.is_empty());
    assert_eq!(
        tables.resolve(" token ", &["en-us".to_owned()]),
        Some(" <b>verbatim</b> ")
    );
    assert_eq!(tables.resolve(" spaced ", &["en-us".to_owned()]), None);
    assert_eq!(tables.resolve("empty", &["en-us".to_owned()]), None);
    assert_eq!(tables.resolve("bad", &["en-us".to_owned()]), None);
    assert_eq!(
        tables.resolve("token", &["--".to_owned()]),
        Some("punctuation locale")
    );
    assert_eq!(tables.resolve("<p>token</p>", &["en-us".to_owned()]), None);
}

#[test]
fn localization_key_value_and_locale_capacities_are_inclusive() {
    assert_eq!(
        (
            MAX_LOCALES,
            MAX_KEYS_PER_LOCALE,
            MAX_KEY_BYTES,
            MAX_VALUE_BYTES,
            MAX_TOTAL_BYTES,
            MAX_PREFERRED_LOCALES
        ),
        (64, 4096, 128, 2048, 1_048_576, 4)
    );
    assert_eq!(FALLBACK_LOCALE, "en-us");
    let ascii_key = "a".repeat(128);
    let unicode_key = "é".repeat(64);
    let unicode_value = "é".repeat(1024);
    let mut table = Map::new();
    table.insert(ascii_key.clone(), json!("v"));
    table.insert("b".repeat(129), json!("too long"));
    table.insert(unicode_key.clone(), json!(unicode_value));
    table.insert("é".repeat(65), json!("too many bytes"));
    table.insert("asciiValue".to_owned(), json!("v".repeat(2048)));
    table.insert("asciiOver".to_owned(), json!("v".repeat(2049)));
    table.insert("unicodeOver".to_owned(), json!("é".repeat(1025)));
    let tables =
        localization_from_tables(Map::from_iter([("en-us".to_owned(), Value::Object(table))]));
    let en = vec!["en-us".to_owned()];
    assert_eq!(tables.resolve(&ascii_key, &en), Some("v"));
    assert_eq!(
        tables.resolve(&unicode_key, &en),
        Some(unicode_value.as_str())
    );
    assert_eq!(tables.resolve("asciiValue", &en).unwrap().len(), 2048);
    for token in [
        "b".repeat(129),
        "é".repeat(65),
        "asciiOver".to_owned(),
        "unicodeOver".to_owned(),
    ] {
        assert_eq!(tables.resolve(&token, &en), None);
    }

    let mut many = Map::new();
    many.insert(" ".to_owned(), json!("ignored"));
    many.insert("invalid".to_owned(), json!(3));
    for index in 0..4097 {
        many.insert(format!("k{index}"), json!("kept"));
    }
    let capacity =
        localization_from_tables(Map::from_iter([("en-us".to_owned(), Value::Object(many))]));
    assert_eq!(capacity.resolve("k0", &en), Some("kept"));
    assert_eq!(capacity.resolve("k4095", &en), Some("kept"));
    assert_eq!(capacity.resolve("k4096", &en), None);

    let mut locales = Map::new();
    locales.insert("empty".to_owned(), json!({}));
    locales.insert("blank".to_owned(), json!({"token":" "}));
    locales.insert("broken".to_owned(), Value::Null);
    for index in 0..65 {
        locales.insert(
            format!("x{index:02}"),
            json!({"token":format!("value{index}")}),
        );
    }
    locales.insert("X00".to_owned(), json!({"extra":"alias still accepted"}));
    let capacity = localization_from_tables(locales);
    assert_eq!(
        capacity.resolve("token", &["x63".to_owned()]),
        Some("value63")
    );
    assert_eq!(capacity.resolve("token", &["x64".to_owned()]), None);
    assert_eq!(
        capacity.resolve("extra", &["x00".to_owned()]),
        Some("alias still accepted")
    );
}

#[test]
fn localization_total_budget_skips_large_then_accepts_fitting_entries() {
    let en = vec!["en-us".to_owned()];
    let mut table = Map::new();
    table.insert("blank".to_owned(), json!(" "));
    table.insert(" ".to_owned(), json!("ignored"));
    table.insert("oversized".to_owned(), json!("v".repeat(2049)));
    for index in 0..511 {
        table.insert(format!("k{index:03}"), json!("v".repeat(2044)));
    }
    table.insert("tooBig".to_owned(), json!("v".repeat(2048)));
    table.insert("fit".to_owned(), json!("v".repeat(2045)));
    table.insert("last".to_owned(), json!("x"));
    let tables =
        localization_from_tables(Map::from_iter([("en-us".to_owned(), Value::Object(table))]));
    assert_eq!(tables.resolve("k510", &en).unwrap().len(), 2044);
    assert_eq!(tables.resolve("tooBig", &en), None);
    assert_eq!(tables.resolve("fit", &en).unwrap().len(), 2045);
    assert_eq!(tables.resolve("last", &en), None);

    let mut first = Map::new();
    for index in 0..511 {
        first.insert(format!("k{index:03}"), json!("v".repeat(2044)));
    }
    first.insert("dup".to_owned(), json!("v"));
    let alias = json!({"dup":"replacement","tail":"t".repeat(2040)});
    let tables = localization_from_tables(Map::from_iter([
        ("EN_us".to_owned(), Value::Object(first)),
        ("en-us".to_owned(), alias),
    ]));
    assert_eq!(tables.resolve("dup", &en), Some("v"));
    assert_eq!(tables.resolve("tail", &en).unwrap().len(), 2040);
}

#[test]
fn localization_alias_precedence_and_decoded_duplicate_members_differ() {
    let raw:Value=serde_json::from_str(r#"{"PT_BR":{"key":"first","key":"decoded last","later":"initial"},"pt-br":{"key":"alias loses","new":"alias adds"}}"#).unwrap();
    let tables = localization_from_tables(raw.as_object().unwrap().clone());
    assert_eq!(
        tables.resolve("key", &["pt-br".to_owned()]),
        Some("decoded last")
    );
    assert_eq!(
        tables.resolve("new", &["pt-br".to_owned()]),
        Some("alias adds")
    );
    let mut full = Map::new();
    for index in 0..4096 {
        full.insert(format!("k{index}"), json!("initial"));
    }
    let capacity = localization_from_tables(Map::from_iter([
        ("EN_US".to_owned(), Value::Object(full)),
        (
            "en-us".to_owned(),
            json!({"k0":"not replacement","new":"over capacity"}),
        ),
    ]));
    assert_eq!(
        capacity.resolve("k0", &["en-us".to_owned()]),
        Some("initial")
    );
    assert_eq!(capacity.resolve("new", &["en-us".to_owned()]), None);
}

#[test]
fn locale_preferences_lookup_order_and_model_clone_sharing() {
    let requested = [
        "bad code", "FR_fr", "fr-FR", "DE_de", "EN_us", "ja_JP", "it-it",
    ]
    .map(str::to_owned);
    assert_eq!(
        preferred_locales(&requested),
        ["fr-fr", "de-de", "en-us", "ja-jp"].map(str::to_owned)
    );
    assert_eq!(
        preferred_locales(&["aa", "bb", "cc", "dd", "en-us"].map(str::to_owned)),
        ["aa", "bb", "cc", "dd", "en-us"].map(str::to_owned)
    );
    assert_eq!(
        preferred_locales(&["a", "invalid space", "éé"].map(str::to_owned)),
        vec!["en-us".to_owned()]
    );
    assert_eq!(preferred_locales(&[]), vec!["en-us".to_owned()]);
    let model=ProjectModel::parse("id",r#"{"general":{"localization":{"en-us":{"label":"<b>English</b>"},"fr-fr":{"label":" <i>Français</i> "}},"properties":{"p":{"type":"combo","text":"label","options":[{"label":"missing","value":true}]}}}}"#).unwrap();
    let cloned = model.clone();
    assert!(Arc::ptr_eq(&model.localization, &cloned.localization));
    assert_eq!(
        model
            .localization
            .resolve("label", &["fr-fr".to_owned(), "en-us".to_owned()]),
        Some(" <i>Français</i> ")
    );
    assert_eq!(
        model.localization.resolve("label", &["FR_FR".to_owned()]),
        None
    );
    assert_eq!(model.localization.resolve("label", &[]), None);
    assert_eq!(
        model
            .localization
            .resolve("<p>label</p>", &["en-us".to_owned()]),
        None
    );
    assert_eq!(model.properties[0].label_html, "label");
    let PropertyMetadata::Combo { options } = &model.properties[0].metadata else {
        panic!("combo metadata");
    };
    assert_eq!(options[0].label, "missing");
    assert_eq!(options[0].value, "true");
    assert_eq!(options[0].json_value, json!(true));
}
