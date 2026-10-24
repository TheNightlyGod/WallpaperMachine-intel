// D01-D10: synthetic, device-free descriptor and identity contracts.
// Mounted by the parent as a #[cfg(test)] child of display.
use super::*;

fn assert_exact_scale(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() <= f64::EPSILON,
        "scale differs: actual={actual:?}, expected={expected:?}"
    );
}

// D01
#[test]
fn plain_descriptor_retains_its_supplied_geometry() {
    let display = DisplayDesc::new(113, -281, 463, 2560, 1600, 1.25);

    assert_eq!(display.display_id, 113);
    assert_eq!((display.x, display.y), (-281, 463));
    assert_eq!((display.width, display.height), (2560, 1600));
    assert_exact_scale(display.scale_factor, 1.25);
    assert_eq!(display.identity, DisplayIdentity::default());
    assert!(display.identity.is_empty());
    assert_eq!(display.refresh_rate_hz, 60);
}

// D02
#[test]
fn dense_metric_report_retains_pixels_and_requested_frequency() {
    let display = DisplayDesc::from(DisplayMetrics {
        display_id: 263,
        identity: DisplayIdentity::default(),
        origin_x: -137.25,
        origin_y: 48.0,
        logical_width: 1280.0,
        logical_height: 900.0,
        pixel_width: 2560,
        pixel_height: 1800,
        primary_logical_height: 1440.0,
        refresh_rate_hz: 144,
        is_primary: false,
    });

    assert_eq!(display.display_id, 263);
    assert_eq!((display.x, display.y), (-137, 492));
    assert_eq!((display.width, display.height), (2560, 1800));
    assert_eq!(display.identity, DisplayIdentity::default());
    assert_exact_scale(display.scale_factor, 2.0);
    assert_eq!(display.refresh_rate_hz, 144);
}

// D03
#[test]
fn shorter_and_taller_secondaries_land_on_opposite_vertical_sides() {
    let shorter = DisplayDesc::from(DisplayMetrics {
        display_id: 347,
        identity: DisplayIdentity::default(),
        origin_x: 1024.0,
        origin_y: 0.0,
        logical_width: 1024.0,
        logical_height: 640.0,
        pixel_width: 1024,
        pixel_height: 640,
        primary_logical_height: 1000.0,
        refresh_rate_hz: 75,
        is_primary: false,
    });
    let taller = DisplayDesc::from(DisplayMetrics {
        display_id: 349,
        identity: DisplayIdentity::default(),
        origin_x: -1024.0,
        origin_y: 0.0,
        logical_width: 1024.0,
        logical_height: 1440.0,
        pixel_width: 1024,
        pixel_height: 1440,
        primary_logical_height: 1000.0,
        refresh_rate_hz: 75,
        is_primary: false,
    });

    assert_eq!((shorter.x, shorter.y), (1024, 360));
    assert_eq!((taller.x, taller.y), (-1024, -440));
    assert_exact_scale(shorter.scale_factor, 1.0);
    assert_exact_scale(taller.scale_factor, 1.0);
}

// D04: invalid logical bounds, invalid primary height, width/height fallback,
// lower scale bound, and rounded/saturated fallback origins.
#[test]
fn unusable_metric_bounds_have_finite_fallback_results() {
    for (logical_width, logical_height) in [
        (0.0, 0.0),
        (-50.0, -25.0),
        (f64::NAN, f64::NAN),
        (f64::NEG_INFINITY, f64::INFINITY),
    ] {
        let display = DisplayDesc::from(DisplayMetrics {
            display_id: 401,
            identity: DisplayIdentity::default(),
            origin_x: 12.75,
            origin_y: -22.75,
            logical_width,
            logical_height,
            pixel_width: 1600,
            pixel_height: 1200,
            primary_logical_height: 800.0,
            refresh_rate_hz: 90,
            is_primary: false,
        });
        assert_exact_scale(display.scale_factor, 1.0);
        assert_eq!((display.x, display.y), (13, -23));
        assert_eq!((display.width, display.height), (1600, 1200));
        assert_eq!(display.refresh_rate_hz, 90);
    }

    for invalid_height in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let bad_primary = DisplayDesc::from(DisplayMetrics {
            display_id: 403,
            identity: DisplayIdentity::default(),
            origin_x: -17.5,
            origin_y: 18.5,
            logical_width: 800.0,
            logical_height: 600.0,
            pixel_width: 1600,
            pixel_height: 1200,
            primary_logical_height: invalid_height,
            refresh_rate_hz: 90,
            is_primary: false,
        });
        let bad_display = DisplayDesc::from(DisplayMetrics {
            display_id: 409,
            identity: DisplayIdentity::default(),
            origin_x: -17.5,
            origin_y: 18.5,
            logical_width: 800.0,
            logical_height: invalid_height,
            pixel_width: 1600,
            pixel_height: 1200,
            primary_logical_height: 1000.0,
            refresh_rate_hz: 90,
            is_primary: false,
        });
        assert_eq!((bad_primary.x, bad_primary.y), (-18, 19));
        assert_eq!((bad_display.x, bad_display.y), (-18, 19));
        assert_exact_scale(bad_primary.scale_factor, 2.0);
        assert_exact_scale(bad_display.scale_factor, 2.0);
    }

    let height_only = DisplayDesc::from(DisplayMetrics {
        display_id: 419,
        identity: DisplayIdentity::default(),
        origin_x: 0.0,
        origin_y: 0.0,
        logical_width: 0.0,
        logical_height: 400.0,
        pixel_width: 1600,
        pixel_height: 1200,
        primary_logical_height: 1000.0,
        refresh_rate_hz: 90,
        is_primary: false,
    });
    assert_exact_scale(height_only.scale_factor, 3.0);
    assert_eq!(height_only.y, 600);

    let subunit = DisplayDesc::from(DisplayMetrics {
        display_id: 421,
        identity: DisplayIdentity::default(),
        origin_x: f64::MAX,
        origin_y: -f64::MAX,
        logical_width: 500.0,
        logical_height: 200.0,
        pixel_width: 400,
        pixel_height: 100,
        primary_logical_height: 0.0,
        refresh_rate_hz: 90,
        is_primary: false,
    });
    assert_exact_scale(subunit.scale_factor, 1.0);
    assert_eq!((subunit.x, subunit.y), (i32::MAX, i32::MIN));
}

// D05
#[test]
fn matching_uuid_dominates_conflicting_manufacturer_fields() {
    let configured = DisplayIdentity {
        uuid: Some("panel-cedar-7".into()),
        vendor_id: Some(271),
        model_id: Some(619),
        serial_number: Some(907),
        unit_number: Some(4),
        name: Some("Cedar".into()),
    };
    let live = DisplayIdentity {
        uuid: Some("panel-cedar-7".into()),
        vendor_id: Some(272),
        model_id: Some(620),
        serial_number: Some(908),
        unit_number: Some(9),
        name: Some("Renamed Cedar".into()),
    };
    assert_eq!(configured.match_score(&live), Some(4));
    assert!(configured.has_stable_match(&live));

    let other_uuid = DisplayIdentity {
        uuid: Some("panel-cedar-8".into()),
        ..configured.clone()
    };
    assert_eq!(configured.match_score(&other_uuid), None);
    assert!(!configured.has_stable_match(&other_uuid));
}

// D06
#[test]
fn serial_identity_survives_unit_renumbering_without_a_uuid_pair() {
    let configured = DisplayIdentity {
        vendor_id: Some(587),
        model_id: Some(971),
        serial_number: Some(1049),
        unit_number: Some(6),
        name: Some("Iris".into()),
        ..DisplayIdentity::default()
    };
    let live = DisplayIdentity {
        uuid: Some("iris-live".into()),
        unit_number: Some(15),
        name: Some("Iris live name".into()),
        ..configured.clone()
    };
    assert_eq!(configured.match_score(&live), Some(3));
    assert!(configured.has_stable_match(&live));

    let different_serial = DisplayIdentity {
        serial_number: Some(1051),
        unit_number: configured.unit_number,
        ..live
    };
    assert_eq!(configured.match_score(&different_serial), None);
}

// D07
#[test]
fn unit_match_is_available_without_a_comparable_serial_pair() {
    let configured = DisplayIdentity {
        vendor_id: Some(733),
        model_id: Some(337),
        unit_number: Some(12),
        ..DisplayIdentity::default()
    };
    let live = DisplayIdentity {
        serial_number: Some(1877),
        name: Some("Unconfigured live label".into()),
        ..configured.clone()
    };
    assert_eq!(configured.match_score(&live), Some(2));
    assert!(!configured.has_stable_match(&live));
}

// D08
#[test]
fn manufacturer_model_and_required_fields_bound_numeric_matches() {
    let configured = DisplayIdentity {
        vendor_id: Some(457),
        model_id: Some(661),
        serial_number: Some(2081),
        unit_number: Some(22),
        name: Some("Larch".into()),
        ..DisplayIdentity::default()
    };
    for nonmatch in [
        DisplayIdentity {
            model_id: Some(673),
            ..configured.clone()
        },
        DisplayIdentity {
            model_id: None,
            ..configured.clone()
        },
        DisplayIdentity {
            vendor_id: None,
            ..configured.clone()
        },
        DisplayIdentity {
            name: configured.name.clone(),
            ..DisplayIdentity::default()
        },
    ] {
        assert_eq!(configured.match_score(&nonmatch), None);
        assert!(!configured.has_stable_match(&nonmatch));
    }
}

// D09
#[test]
fn conversion_keeps_complete_identity_and_prefers_the_width_ratio() {
    let identity = DisplayIdentity {
        uuid: Some("willow-full-identity".into()),
        vendor_id: Some(821),
        model_id: Some(443),
        serial_number: Some(2381),
        unit_number: Some(17),
        name: Some("Willow work surface".into()),
    };
    let display = DisplayDesc::from(DisplayMetrics {
        display_id: 557,
        identity: identity.clone(),
        origin_x: -311.5,
        origin_y: 25.0,
        logical_width: 1200.0,
        logical_height: 800.0,
        pixel_width: 1800,
        pixel_height: 2400,
        primary_logical_height: 1200.0,
        refresh_rate_hz: 165,
        is_primary: false,
    });
    assert_eq!(display.identity, identity);
    assert_eq!(display.display_id, 557);
    assert_eq!((display.x, display.y), (-312, 375));
    assert_eq!((display.width, display.height), (1800, 2400));
    assert_exact_scale(display.scale_factor, 1.5);
    assert_eq!(display.refresh_rate_hz, 165);
}

// D10
#[test]
fn a_unit_only_identity_match_is_explicitly_not_stable() {
    let configured = DisplayIdentity {
        vendor_id: Some(953),
        model_id: Some(127),
        unit_number: Some(28),
        name: Some("Maple configuration".into()),
        ..DisplayIdentity::default()
    };
    let live = DisplayIdentity {
        name: Some("Maple current label".into()),
        ..configured.clone()
    };
    assert_eq!(configured.match_score(&live), Some(2));
    assert!(!configured.has_stable_match(&live));
}
