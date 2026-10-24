// P01-P06: device-free button values, edge tracking, and point normalization.
// Mounted by the parent as a #[cfg(test)] child of window.
use super::*;

fn assert_position(actual: Option<NormalizedMousePosition>, x: f64, y: f64) {
    let actual = actual.expect("finite positive geometry must normalize");
    assert!((actual.x - x).abs() <= f64::EPSILON);
    assert!((actual.y - y).abs() <= f64::EPSILON);
}

// P01
#[test]
fn button_levels_cover_all_thirty_two_positions_in_order() {
    let levels = MouseButtons::from_mask(
        (1_u64 << 63)
            | (1_u64 << 31)
            | (1_u64 << 21)
            | (1_u64 << 12)
            | (1_u64 << 6)
            | (1_u64 << 3)
            | 1,
    );
    let expected: Vec<_> = (0_u32..32)
        .map(|button| MouseButtonState {
            button,
            pressed: matches!(button, 0 | 3 | 6 | 12 | 21 | 31),
        })
        .collect();

    assert_eq!(levels.states(), expected);
}

// P02
#[test]
fn one_sample_can_expand_a_complete_tap_in_press_release_order() {
    let tap = MouseButtonEdges::from_masks(0, 1_u64 << 11, 1_u64 << 11);
    let press = MouseButtonState {
        button: 11,
        pressed: true,
    };
    let release = MouseButtonState {
        button: 11,
        pressed: false,
    };
    let mut expected: Vec<_> = (0_u32..32)
        .map(|button| MouseButtonState {
            button,
            pressed: false,
        })
        .collect();
    expected.insert(11, press);

    assert_eq!(tap.down().mask(), 0);
    assert_eq!(tap.transitions().collect::<Vec<_>>(), vec![press, release]);
    assert_eq!(tap.states().len(), 33);
    assert_eq!(tap.states(), expected);
}

// P03
#[test]
fn unconsumed_tap_survives_as_two_edges_then_is_fully_drained() {
    let mut tracker = MouseButtonTracker::new();
    tracker.set_button(29, true);
    tracker.set_button(29, true);
    tracker.set_button(29, false);
    tracker.set_button(29, false);

    let first = tracker.consume_edges();
    assert_eq!(first.down().mask(), 0);
    assert_eq!(
        first.transitions().collect::<Vec<_>>(),
        vec![
            MouseButtonState {
                button: 29,
                pressed: true
            },
            MouseButtonState {
                button: 29,
                pressed: false
            },
        ],
    );

    let second = tracker.consume_edges();
    assert_eq!(second.down().mask(), 0);
    assert!(second.transitions().next().is_none());
    assert_eq!(
        second.states(),
        (0_u32..32)
            .map(|button| MouseButtonState {
                button,
                pressed: false
            })
            .collect::<Vec<_>>(),
    );
}

// P04
#[test]
fn known_level_samples_emit_only_real_changes_and_retain_held_levels() {
    let mut tracker = MouseButtonTracker::new();
    tracker.sync_down_mask(0);
    let baseline = tracker.consume_edges();
    assert_eq!(baseline.down().mask(), 0);
    assert!(baseline.transitions().next().is_none());

    tracker.sync_down_mask(1_u64 << 30);
    let pressed = tracker.consume_edges();
    assert_eq!(pressed.down().mask(), 1_u64 << 30);
    assert_eq!(
        pressed.transitions().collect::<Vec<_>>(),
        vec![MouseButtonState {
            button: 30,
            pressed: true
        }],
    );

    tracker.sync_down_mask(1_u64 << 30);
    let unchanged = tracker.consume_edges();
    assert_eq!(unchanged.down().mask(), 1_u64 << 30);
    assert!(unchanged.transitions().next().is_none());

    tracker.sync_down_mask(0);
    let released = tracker.consume_edges();
    assert_eq!(released.down().mask(), 0);
    assert_eq!(
        released.transitions().collect::<Vec<_>>(),
        vec![MouseButtonState {
            button: 30,
            pressed: false
        }],
    );
}

// P05
#[test]
fn interior_point_uses_fractional_x_and_inverted_fractional_y() {
    assert_position(
        NormalizedMousePosition::from_window_point(90.0, 45.0, 240.0, 120.0),
        0.375,
        0.625,
    );
}

// P06
#[test]
fn point_normalization_clamps_finite_points_and_rejects_invalid_inputs() {
    for (x, y, expected_x, expected_y) in [
        (-40.0, -20.0, 0.0, 1.0),
        (260.0, 100.0, 1.0, 0.0),
        (-40.0, 20.0, 0.0, 0.75),
        (260.0, 20.0, 1.0, 0.75),
        (50.0, -20.0, 0.25, 1.0),
        (50.0, 100.0, 0.25, 0.0),
    ] {
        assert_position(
            NormalizedMousePosition::from_window_point(x, y, 200.0, 80.0),
            expected_x,
            expected_y,
        );
    }

    for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert!(NormalizedMousePosition::from_window_point(invalid, 20.0, 200.0, 80.0).is_none());
        assert!(NormalizedMousePosition::from_window_point(50.0, invalid, 200.0, 80.0).is_none());
        assert!(NormalizedMousePosition::from_window_point(50.0, 20.0, invalid, 80.0).is_none());
        assert!(NormalizedMousePosition::from_window_point(50.0, 20.0, 200.0, invalid).is_none());
    }
    for nonpositive in [0.0, -0.0, -1.0, -f64::MIN_POSITIVE] {
        assert!(
            NormalizedMousePosition::from_window_point(50.0, 20.0, nonpositive, 80.0).is_none()
        );
        assert!(
            NormalizedMousePosition::from_window_point(50.0, 20.0, 200.0, nonpositive).is_none()
        );
    }

    assert_position(
        NormalizedMousePosition::from_window_point(0.0, 0.0, f64::MIN_POSITIVE, f64::MIN_POSITIVE),
        0.0,
        1.0,
    );
    assert_position(
        NormalizedMousePosition::from_window_point(50.0, 20.0, 200.0, 80.0),
        0.25,
        0.75,
    );
}
