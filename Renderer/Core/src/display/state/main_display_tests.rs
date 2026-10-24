//! What a main-display change does to the wallpapers the slots hold.
//!
//! macOS can make another display the main one at any time (a wake, a lid,
//! a new arrangement). The primary slot is a role that follows the main
//! display, but a wallpaper the host reconciled for a concrete display belongs
//! to that display and must stay on it.
use super::{DisplayKey, DisplayStateModel};
use crate::{
    DisplayConfig, DisplayDesc, DisplayIdentity, DisplaySelector, WallpaperAssignment,
    WallpaperEngineConfig,
    project::{SceneDesc, SceneTemplate},
};

fn screen(display_id: u32, uuid: &str, x: i32) -> DisplayDesc {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_owned()),
        vendor_id: Some(1552),
        model_id: Some(40_000 + display_id),
        serial_number: Some(7_000 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Screen {display_id}")),
    };
    DisplayDesc::with_identity(display_id, identity, x, 0, 2560, 1440, 2.0)
}

fn studio() -> DisplayDesc {
    screen(3, "studio-uuid", 0)
}

fn ultrafine() -> DisplayDesc {
    screen(8, "ultrafine-uuid", 1280)
}

fn project(wallpaper: &str) -> String {
    format!("/library/{wallpaper}/scene.json")
}

fn scene(display: &DisplayDesc, wallpaper: &str) -> SceneDesc {
    SceneDesc::builder(display.clone(), project(wallpaper))
        .build()
        .expect("a valid scene descriptor")
}

fn template(wallpaper: &str) -> SceneTemplate {
    SceneTemplate::builder(project(wallpaper))
        .build()
        .expect("a valid scene template")
}

fn blank_model() -> DisplayStateModel {
    DisplayStateModel::from_config(WallpaperEngineConfig::default()).expect("default model")
}

fn wallpaper_of(assignment: Option<&WallpaperAssignment>) -> Option<String> {
    match assignment {
        Some(WallpaperAssignment::Direct(template)) => Some(template.scene_path.clone()),
        _ => None,
    }
}

/// The wallpaper the slot showing `display` holds, and that slot's key.
fn shown_on(model: &DisplayStateModel, display: &DisplayDesc) -> (DisplayKey, Option<String>) {
    let record = model
        .records
        .iter()
        .find(|record| {
            record
                .live_display
                .as_ref()
                .is_some_and(|live| live.display_id == display.display_id)
        })
        .unwrap_or_else(|| panic!("no slot shows display {}", display.display_id));
    (record.key.clone(), wallpaper_of(record.assignment.as_ref()))
}

/// Disconnected slots that still hold `wallpaper`.
fn waiting_with(model: &DisplayStateModel, wallpaper: &str) -> Vec<DisplayKey> {
    model
        .records
        .iter()
        .filter(|record| record.live_display.is_none())
        .filter(|record| wallpaper_of(record.assignment.as_ref()) == Some(project(wallpaper)))
        .map(|record| record.key.clone())
        .collect()
}

/// Studio is the main display, both screens run a wallpaper the host
/// reconciled for them.
fn reconciled_pair() -> DisplayStateModel {
    let mut model = blank_model();
    model
        .refresh_connected(studio(), vec![studio(), ultrafine()])
        .expect("first report");
    model
        .apply_reconcile(&[scene(&studio(), "aurora"), scene(&ultrafine(), "basalt")])
        .expect("reconcile");
    assert_eq!(
        shown_on(&model, &studio()),
        (DisplayKey::Primary, Some(project("aurora")))
    );
    assert_eq!(shown_on(&model, &ultrafine()).1, Some(project("basalt")));
    model
}

#[test]
fn reconciled_wallpapers_stay_on_their_displays_when_another_display_becomes_main() {
    let mut model = reconciled_pair();

    model
        .refresh_connected(ultrafine(), vec![studio(), ultrafine()])
        .expect("main display moved to the UltraFine");

    let (main_key, main_wallpaper) = shown_on(&model, &ultrafine());
    assert_eq!(
        main_key,
        DisplayKey::Primary,
        "the primary slot follows the main display"
    );
    assert_eq!(main_wallpaper, Some(project("basalt")));
    let (studio_key, studio_wallpaper) = shown_on(&model, &studio());
    assert_ne!(studio_key, DisplayKey::Primary);
    assert_eq!(studio_wallpaper, Some(project("aurora")));
}

#[test]
fn reconciled_wallpapers_stay_on_their_displays_when_the_main_display_changes_back() {
    let mut model = reconciled_pair();
    model
        .refresh_connected(ultrafine(), vec![studio(), ultrafine()])
        .expect("main display moved to the UltraFine");

    model
        .refresh_connected(studio(), vec![studio(), ultrafine()])
        .expect("main display moved back to the Studio Display");

    assert_eq!(
        shown_on(&model, &studio()),
        (DisplayKey::Primary, Some(project("aurora")))
    );
    let (ultrafine_key, ultrafine_wallpaper) = shown_on(&model, &ultrafine());
    assert_ne!(ultrafine_key, DisplayKey::Primary);
    assert_eq!(ultrafine_wallpaper, Some(project("basalt")));
}

#[test]
fn the_previous_main_display_keeps_its_wallpaper_while_it_is_disconnected() {
    let mut model = reconciled_pair();

    // The lid closes: the Studio Display goes away and the UltraFine is main.
    model
        .refresh_connected(ultrafine(), vec![ultrafine()])
        .expect("lid closed");

    assert_eq!(
        shown_on(&model, &ultrafine()),
        (DisplayKey::Primary, Some(project("basalt")))
    );
    let waiting = waiting_with(&model, "aurora");
    assert_eq!(
        waiting.len(),
        1,
        "the Studio Display's own slot keeps its wallpaper"
    );
    assert_ne!(waiting[0], DisplayKey::Primary);

    // It comes back as a secondary display and shows what it showed.
    model
        .refresh_connected(ultrafine(), vec![ultrafine(), studio()])
        .expect("lid opened");
    let (studio_key, studio_wallpaper) = shown_on(&model, &studio());
    assert_eq!(studio_key, waiting[0]);
    assert_eq!(studio_wallpaper, Some(project("aurora")));
    assert_eq!(shown_on(&model, &ultrafine()).1, Some(project("basalt")));
}

#[test]
fn a_configured_primary_wallpaper_still_follows_the_main_display() {
    let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
        displays: vec![DisplayConfig {
            selector: DisplaySelector::Primary,
            window_active: true,
            wallpaper: Some(WallpaperAssignment::Direct(template("cascade"))),
        }],
    })
    .expect("configured model");
    model
        .refresh_connected(studio(), vec![studio(), ultrafine()])
        .expect("first report");
    assert_eq!(
        shown_on(&model, &studio()),
        (DisplayKey::Primary, Some(project("cascade")))
    );

    model
        .refresh_connected(ultrafine(), vec![studio(), ultrafine()])
        .expect("main display moved to the UltraFine");

    assert_eq!(
        shown_on(&model, &ultrafine()),
        (DisplayKey::Primary, Some(project("cascade")))
    );
}

#[test]
fn a_reconciled_wallpaper_on_the_new_main_display_gives_way_to_a_configured_primary_wallpaper() {
    let mut model = DisplayStateModel::from_config(WallpaperEngineConfig {
        displays: vec![DisplayConfig {
            selector: DisplaySelector::Primary,
            window_active: true,
            wallpaper: Some(WallpaperAssignment::Direct(template("cascade"))),
        }],
    })
    .expect("configured model");
    model
        .refresh_connected(studio(), vec![studio(), ultrafine()])
        .expect("first report");
    // Only the UltraFine was reconciled; the primary slot keeps the
    // configured role wallpaper.
    model
        .apply_reconcile(&[scene(&ultrafine(), "basalt")])
        .expect("reconcile");

    model
        .refresh_connected(ultrafine(), vec![studio(), ultrafine()])
        .expect("main display moved to the UltraFine");

    assert_eq!(
        shown_on(&model, &ultrafine()),
        (DisplayKey::Primary, Some(project("cascade")))
    );
    let primary = model
        .records
        .iter()
        .find(|record| record.key == DisplayKey::Primary)
        .expect("primary slot");
    assert_eq!(
        wallpaper_of(primary.assignment.as_ref()),
        Some(project("cascade"))
    );
}

#[test]
fn a_wallpaper_set_on_the_primary_selector_is_a_role_even_after_a_reconcile_elsewhere() {
    let mut model = reconciled_pair();
    // Setting the primary selector's wallpaper directly makes it the role's
    // wallpaper again, which follows whichever display is main.
    model
        .set_assignment(
            &DisplaySelector::Primary,
            WallpaperAssignment::Direct(template("cascade")),
        )
        .expect("set primary wallpaper");

    model
        .refresh_connected(ultrafine(), vec![studio(), ultrafine()])
        .expect("main display moved to the UltraFine");

    assert_eq!(
        shown_on(&model, &ultrafine()),
        (DisplayKey::Primary, Some(project("cascade")))
    );
}
