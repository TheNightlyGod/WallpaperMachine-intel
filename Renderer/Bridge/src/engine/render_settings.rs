use crate::config::{MonitorRender, SerializedSelector};
use crate::display::{DisplayDescExt, DisplaySelectorExt, DisplaySnapshotExt};
use wallpaper_core::{DisplayDesc, DisplaySnapshotEntry};

pub(super) fn select_render_setting<'settings>(
    settings: &'settings [MonitorRender],
    selected: &SerializedSelector,
    display: &DisplayDesc,
    inventory: &[DisplaySnapshotEntry],
) -> Option<&'settings MonitorRender> {
    if settings.is_empty() {
        return None;
    }

    if let Some(setting) = settings
        .iter()
        .find(|setting| &setting.selector == selected)
    {
        return Some(setting);
    }

    let representative = inventory
        .iter()
        .find(|entry| entry.desc.same_physical_display(display))?;
    let primary = inventory.first()?;
    let mut primary_match = None;

    settings.iter().find(|setting| match &setting.selector {
        SerializedSelector::Primary => {
            *primary_match.get_or_insert_with(|| representative.matches_primary(primary))
        }
        selector => selector.to_selector().matches_display(representative),
    })
}

#[cfg(test)]
mod tests {
    use super::select_render_setting;
    use crate::config::{FramingCfg, MonitorRender, SerializedSelector};
    use std::ptr;
    use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

    fn identity(
        uuid: Option<&str>,
        vendor_id: Option<u32>,
        model_id: Option<u32>,
        serial_number: Option<u32>,
        unit_number: Option<u32>,
        name: Option<&str>,
    ) -> DisplayIdentity {
        DisplayIdentity {
            uuid: uuid.map(str::to_owned),
            vendor_id,
            model_id,
            serial_number,
            unit_number,
            name: name.map(str::to_owned),
        }
    }

    fn coral_named(name: &str) -> DisplayIdentity {
        identity(
            Some("panel-coral"),
            Some(81),
            Some(144),
            Some(987),
            Some(3),
            Some(name),
        )
    }

    fn coral() -> DisplayIdentity {
        coral_named("Coral")
    }

    fn jade() -> DisplayIdentity {
        identity(
            Some("panel-jade"),
            Some(81),
            Some(144),
            Some(988),
            Some(3),
            Some("Jade"),
        )
    }

    fn unit_only() -> DisplayIdentity {
        identity(None, Some(28), Some(63), None, Some(8), None)
    }

    fn unit_full() -> DisplayIdentity {
        identity(
            None,
            Some(28),
            Some(63),
            Some(501),
            Some(8),
            Some("Unit panel"),
        )
    }

    fn identified(identity: DisplayIdentity) -> SerializedSelector {
        SerializedSelector::Identity {
            uuid: identity.uuid,
            vendor_id: identity.vendor_id,
            model_id: identity.model_id,
            serial_number: identity.serial_number,
            unit_number: identity.unit_number,
            name: identity.name,
        }
    }

    fn live(display_id: u32) -> SerializedSelector {
        SerializedSelector::LiveDisplayId { display_id }
    }

    fn display(display_id: u32, identity: DisplayIdentity) -> DisplayDesc {
        DisplayDesc::with_identity(display_id, identity, -320, 70, 1536, 864, 1.25)
    }

    fn snapshot(display_id: u32, identity: DisplayIdentity) -> DisplaySnapshotEntry {
        DisplaySnapshotEntry {
            desc: display(display_id, identity.clone()),
            identity,
            handle: None,
            accepts_pointer_input: false,
            paused: false,
            window_active: false,
            assignment: None,
        }
    }

    fn setting(selector: SerializedSelector, position: usize) -> MonitorRender {
        let (mode, factor, rate, pan_x, pan_y) = match position {
            0 => ("contain", 1.125, Some(43), 0.23, 0.71),
            1 => ("cover", 1.375, Some(47), 0.37, 0.61),
            _ => panic!("fixture supports two distinct setting positions"),
        };
        MonitorRender {
            selector,
            scaling_mode: mode.to_owned(),
            scaling_factor: factor,
            frame_rate: rate,
            framing: FramingCfg { pan_x, pan_y },
        }
    }

    fn assert_payload(setting: &MonitorRender, position: usize) {
        let expected = match position {
            0 => ("contain", 1.125, Some(43), 0.23, 0.71),
            1 => ("cover", 1.375, Some(47), 0.37, 0.61),
            _ => panic!("unknown expected fixture position"),
        };
        assert_eq!(
            (
                setting.scaling_mode.as_str(),
                setting.scaling_factor,
                setting.frame_rate,
                setting.framing.pan_x,
                setting.framing.pan_y,
            ),
            expected,
        );
    }

    fn assert_selected(
        obligation: &str,
        result: Option<&MonitorRender>,
        settings: &[MonitorRender],
        expected: usize,
    ) {
        let actual = result.unwrap_or_else(|| {
            panic!("{obligation}: expected original settings member {expected}")
        });
        assert!(
            ptr::eq(actual, &settings[expected]),
            "{obligation}: wrong member"
        );
        assert_payload(actual, expected);
    }

    #[test]
    fn exact_equality_precedes_inventory_and_primary_role() {
        let screen = display(401, coral());

        let settings = [setting(live(333), 0)];
        assert_selected(
            "RS02",
            select_render_setting(&settings, &live(333), &screen, &[]),
            &settings,
            0,
        );

        let settings = [setting(identified(DisplayIdentity::default()), 0)];
        let unrelated = [snapshot(552, jade())];
        assert_selected(
            "RS03",
            select_render_setting(
                &settings,
                &identified(DisplayIdentity::default()),
                &screen,
                &unrelated,
            ),
            &settings,
            0,
        );

        let inventory = [snapshot(401, coral())];
        let settings = [
            setting(SerializedSelector::Primary, 0),
            setting(live(401), 1),
        ];
        assert_selected(
            "RS04",
            select_render_setting(&settings, &live(401), &screen, &inventory),
            &settings,
            1,
        );

        let settings = [setting(SerializedSelector::Primary, 0)];
        let inventory = [snapshot(401, coral()), snapshot(552, jade())];
        assert_selected(
            "RS05",
            select_render_setting(
                &settings,
                &SerializedSelector::Primary,
                &display(552, jade()),
                &inventory,
            ),
            &settings,
            0,
        );
    }

    #[test]
    fn equal_selector_duplicates_keep_the_first_payload() {
        let screen = display(401, coral());
        let settings = [setting(live(333), 0), setting(live(333), 1)];
        assert_selected(
            "RS06 live duplicates",
            select_render_setting(&settings, &live(333), &screen, &[]),
            &settings,
            0,
        );

        let settings = [
            setting(identified(coral()), 0),
            setting(identified(coral()), 1),
        ];
        let inventory = [snapshot(552, jade())];
        assert_selected(
            "RS06 identity duplicates",
            select_render_setting(&settings, &identified(coral()), &screen, &inventory),
            &settings,
            0,
        );
    }

    #[test]
    fn fallback_needs_both_a_representative_and_a_matching_setting() {
        let screen = display(401, coral());
        let inventory = [snapshot(401, coral())];
        assert!(
            select_render_setting(&[], &live(777), &screen, &inventory).is_none(),
            "RS01 inventory"
        );
        assert!(
            select_render_setting(&[], &live(777), &screen, &[]).is_none(),
            "RS01 empty inventory"
        );

        let settings = [
            setting(identified(coral()), 0),
            setting(SerializedSelector::Primary, 1),
        ];
        assert!(
            select_render_setting(&settings, &live(777), &screen, &[]).is_none(),
            "RS08"
        );

        let settings = [setting(live(552), 0), setting(identified(jade()), 1)];
        let unrelated = [snapshot(552, jade())];
        assert!(
            select_render_setting(&settings, &live(777), &screen, &unrelated).is_none(),
            "RS09"
        );

        let settings = [setting(live(112), 0), setting(identified(jade()), 1)];
        assert!(
            select_render_setting(&settings, &live(777), &screen, &inventory).is_none(),
            "RS10"
        );
    }

    #[test]
    fn fallback_saved_order_beats_variant_and_identity_strength() {
        let screen = display(401, coral());
        let inventory = [snapshot(401, coral())];
        let settings = [
            setting(identified(coral_named("Coral renamed")), 0),
            setting(live(401), 1),
        ];
        assert_selected(
            "RS07 identity first",
            select_render_setting(&settings, &live(777), &screen, &inventory),
            &settings,
            0,
        );
        let settings = [
            setting(live(401), 0),
            setting(identified(coral_named("Coral renamed")), 1),
        ];
        assert_selected(
            "RS07 live first",
            select_render_setting(&settings, &live(777), &screen, &inventory),
            &settings,
            0,
        );

        let settings = [
            setting(identified(unit_only()), 0),
            setting(
                identified(identity(Some("panel-gold"), None, None, None, None, None)),
                1,
            ),
        ];
        let gold = identity(Some("panel-gold"), Some(28), Some(63), None, Some(8), None);
        let inventory = [snapshot(620, gold)];
        assert_selected(
            "RS19",
            select_render_setting(&settings, &live(777), &inventory[0].desc, &inventory),
            &settings,
            0,
        );

        let settings = [
            setting(identified(coral_named("Coral renamed")), 0),
            setting(identified(coral()), 1),
        ];
        let inventory = [snapshot(401, coral())];
        assert_selected(
            "RS20",
            select_render_setting(&settings, &live(777), &screen, &inventory),
            &settings,
            0,
        );
    }

    #[test]
    fn first_physical_representative_is_fixed_even_when_later_evidence_is_stronger() {
        let screen = display(401, coral());
        let inventory = [snapshot(401, jade()), snapshot(902, coral())];
        let settings = [setting(live(902), 0), setting(live(401), 1)];
        assert_selected(
            "RS11 equal live ID first",
            select_render_setting(&settings, &live(777), &screen, &inventory),
            &settings,
            1,
        );
        let reversed = [snapshot(902, coral()), snapshot(401, jade())];
        assert_selected(
            "RS11 identity first",
            select_render_setting(&settings, &live(777), &screen, &reversed),
            &settings,
            0,
        );

        let settings = [setting(live(902), 0)];
        assert!(
            select_render_setting(&settings, &live(777), &screen, &inventory).is_none(),
            "RS12"
        );

        let inventory = [snapshot(401, coral()), snapshot(902, coral())];
        assert!(
            select_render_setting(&settings, &live(777), &screen, &inventory).is_none(),
            "RS18 old live ID"
        );
        let settings = [setting(identified(coral_named("Coral renamed")), 0)];
        assert_selected(
            "RS18 identity alias",
            select_render_setting(&settings, &live(777), &screen, &inventory),
            &settings,
            0,
        );
    }

    #[test]
    fn primary_fallback_uses_inventory_order_and_accepts_physical_aliases() {
        let settings = [setting(SerializedSelector::Primary, 0)];
        let inventory = [snapshot(902, coral()), snapshot(401, jade())];
        assert_selected(
            "RS13 first record",
            select_render_setting(&settings, &live(777), &display(902, coral()), &inventory),
            &settings,
            0,
        );
        assert!(
            select_render_setting(&settings, &live(777), &display(401, jade()), &inventory)
                .is_none(),
            "RS13 lower ID is not primary",
        );

        let inventory = [snapshot(902, coral()), snapshot(401, coral())];
        assert_selected(
            "RS14 UUID alias",
            select_render_setting(
                &settings,
                &identified(coral_named("Coral renamed")),
                &display(401, coral()),
                &inventory,
            ),
            &settings,
            0,
        );

        let inventory = [snapshot(902, unit_only()), snapshot(401, unit_full())];
        assert_selected(
            "RS15 unit alias",
            select_render_setting(
                &settings,
                &live(777),
                &display(401, unit_full()),
                &inventory,
            ),
            &settings,
            0,
        );
    }

    #[test]
    fn fallback_interoperates_between_unequal_selector_variants() {
        let screen = display(401, coral());
        let inventory = [snapshot(401, coral())];
        let settings = [setting(identified(coral()), 0)];
        assert_selected(
            "RS16 identity setting for Primary assignment",
            select_render_setting(&settings, &SerializedSelector::Primary, &screen, &inventory),
            &settings,
            0,
        );
        let settings = [setting(SerializedSelector::Primary, 0)];
        assert_selected(
            "RS16 Primary setting for identity assignment",
            select_render_setting(
                &settings,
                &identified(coral_named("Coral renamed")),
                &screen,
                &inventory,
            ),
            &settings,
            0,
        );

        let settings = [setting(live(401), 0)];
        assert_selected(
            "RS17 live setting for identity assignment",
            select_render_setting(
                &settings,
                &identified(coral_named("Coral renamed")),
                &screen,
                &inventory,
            ),
            &settings,
            0,
        );
        let settings = [setting(identified(coral_named("Coral renamed")), 0)];
        assert_selected(
            "RS17 identity setting for live assignment",
            select_render_setting(&settings, &live(401), &screen, &inventory),
            &settings,
            0,
        );
    }

    #[test]
    fn real_identity_capability_compatibility_table() {
        // Expected outcomes are the packet's independent facts, not a matcher oracle.
        let cases = [
            (
                "RS21 equal UUID overrides lower keys",
                identity(
                    Some("panel-coral"),
                    Some(81),
                    Some(144),
                    Some(987),
                    Some(3),
                    None,
                ),
                identity(
                    Some("panel-coral"),
                    Some(19),
                    Some(205),
                    Some(610),
                    Some(11),
                    None,
                ),
                true,
            ),
            (
                "RS22 conflicting UUID defeats lower keys",
                coral(),
                identity(
                    Some("panel-jade"),
                    Some(81),
                    Some(144),
                    Some(987),
                    Some(3),
                    Some("Coral"),
                ),
                false,
            ),
            (
                "RS23 serial ignores unit and name changes",
                identity(
                    None,
                    Some(42),
                    Some(86),
                    Some(1501),
                    Some(2),
                    Some("Before"),
                ),
                identity(None, Some(42), Some(86), Some(1501), Some(9), Some("After")),
                true,
            ),
            (
                "RS24 conflicting serial defeats equal units",
                identity(None, Some(42), Some(86), Some(1501), Some(2), None),
                identity(None, Some(42), Some(86), Some(1502), Some(2), None),
                false,
            ),
            (
                "RS25 one-sided serial permits unit match",
                unit_only(),
                unit_full(),
                true,
            ),
            (
                "RS25 empty UUID permits unit match",
                identity(Some(""), Some(28), Some(63), None, Some(8), None),
                identity(Some("panel-unit"), Some(28), Some(63), None, Some(8), None),
                true,
            ),
            (
                "RS26 model mismatch defeats equal units",
                unit_only(),
                identity(None, Some(28), Some(64), None, Some(8), None),
                false,
            ),
            (
                "RS26 name alone is insufficient",
                identity(None, None, None, None, None, Some("Coral")),
                identity(None, None, None, None, None, Some("Coral")),
                false,
            ),
            (
                "RS27 present zero values",
                identity(None, Some(0), Some(0), Some(0), None, None),
                identity(None, Some(0), Some(0), Some(0), None, None),
                true,
            ),
            (
                "RS28 UUID case is literal",
                identity(Some("Panel-Coral"), None, None, None, None, None),
                identity(Some("panel-coral"), None, None, None, None, None),
                false,
            ),
        ];

        for (obligation, setting_identity, representative_identity, matches) in cases {
            let settings = [setting(identified(setting_identity), 0)];
            let selected = live(777);
            let inventory = [snapshot(401, representative_identity)];
            let result =
                select_render_setting(&settings, &selected, &inventory[0].desc, &inventory);
            if matches {
                assert_selected(obligation, result, &settings, 0);
            } else {
                assert!(result.is_none(), "{obligation}: expected no setting");
            }
        }
    }

    #[test]
    fn returned_member_outlives_all_non_settings_inputs() {
        let settings = [setting(live(401), 0)];
        let result = {
            let selected = identified(coral_named("Coral renamed"));
            let screen = display(401, coral());
            let inventory = [snapshot(401, coral())];
            select_render_setting(&settings, &selected, &screen, &inventory)
        };
        assert_selected("RS29", result, &settings, 0);
    }

    #[test]
    fn exact_fallback_and_absence_preserve_all_supplied_values() {
        let settings = [
            setting(identified(coral_named("Coral renamed")), 0),
            setting(live(333), 1),
        ];
        for (obligation, selected_id, display_id, display_identity, expected) in [
            ("RS30 exact", 333, 401, coral(), Some(1)),
            ("RS30 fallback", 777, 401, coral(), Some(0)),
            ("RS30 negative", 777, 552, jade(), None),
        ] {
            let selected = live(selected_id);
            let screen = display(display_id, display_identity.clone());
            let inventory = [snapshot(display_id, display_identity)];
            let result = select_render_setting(&settings, &selected, &screen, &inventory);
            match expected {
                Some(index) => assert_selected(obligation, result, &settings, index),
                None => assert!(result.is_none(), "{obligation}: expected no setting"),
            }

            assert_eq!(
                settings[0].selector,
                identified(coral_named("Coral renamed"))
            );
            assert_eq!(settings[1].selector, live(333));
            assert_payload(&settings[0], 0);
            assert_payload(&settings[1], 1);
            assert_eq!(selected, live(selected_id));

            let expected_identity = if display_id == 401 { coral() } else { jade() };
            assert_eq!(screen.display_id, display_id);
            assert_eq!(screen.identity, expected_identity);
            assert_eq!(
                (screen.x, screen.y, screen.width, screen.height),
                (-320, 70, 1536, 864)
            );
            assert_eq!((screen.scale_factor, screen.refresh_rate_hz), (1.25, 60));
            assert_eq!(inventory.len(), 1);
            assert_eq!(inventory[0].identity, expected_identity);
            assert_eq!(inventory[0].desc, screen);
            assert!(inventory[0].handle.is_none());
            assert!(inventory[0].assignment.is_none());
            assert!(!inventory[0].accepts_pointer_input);
            assert!(!inventory[0].paused);
            assert!(!inventory[0].window_active);
        }
    }
}
