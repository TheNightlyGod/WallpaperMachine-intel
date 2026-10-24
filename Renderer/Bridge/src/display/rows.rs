mod replacement;

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment,
};

use crate::config::{AppConfig, MonitorCfg, SerializedSelector};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MonitorRow {
    pub selector: SerializedSelector,
    pub config: MonitorCfg,
    pub connected: bool,
    pub display_index: Option<usize>,
}

impl AppConfig {
    /// macOS renumbers displays and renames identical models ("Name (1)",
    /// "Name (2)") across reboots and reconnects, so a connected display's
    /// selector changes while the display does not. Blocks are looked up by
    /// exact selector, so each change used to append a block and leave the
    /// old one behind, still holding a wallpaper that could win for that
    /// display. Each display now keeps one block, renamed to its current
    /// selector: the first one, which is the block the renderer was showing.
    /// Its settings entry and mirror references follow the rename.
    fn merge_display_aliases(&mut self, displays: &[DisplaySnapshotEntry]) {
        let primary = displays.first();
        for (index, display) in displays.iter().enumerate() {
            if index > 0 && primary.is_some_and(|primary| display.matches_primary(primary)) {
                continue;
            }
            let Some(current) = display.stable_identity_selector() else {
                continue;
            };
            let names_display = |selector: &SerializedSelector| {
                matches!(
                    selector.to_selector(),
                    DisplaySelector::Identity(identity)
                        if identity.has_stable_match(&display.identity)
                )
            };

            if let Some(keep) = self
                .monitors
                .iter()
                .position(|monitor| names_display(&monitor.selector))
            {
                collapse_aliases(
                    &mut self.monitors,
                    keep,
                    &current,
                    |monitor| &mut monitor.selector,
                    names_display,
                );
            }
            // The settings panel edits the entry under the current selector.
            if let Some(keep) = self
                .monitor_settings
                .iter()
                .position(|settings| settings.selector == current)
                .or_else(|| {
                    self.monitor_settings
                        .iter()
                        .position(|settings| names_display(&settings.selector))
                })
            {
                collapse_aliases(
                    &mut self.monitor_settings,
                    keep,
                    &current,
                    |settings| &mut settings.selector,
                    names_display,
                );
            }
            for target in self
                .monitors
                .iter_mut()
                .filter_map(|monitor| monitor.mirror_target.as_mut())
                .filter(|target| names_display(target))
            {
                target.clone_from(&current);
            }
        }

        // A disconnected display cannot be renamed yet, but it still keeps
        // only its first block.
        let mut seen = Vec::new();
        self.monitors
            .retain(|monitor| first_for_identity(&monitor.selector, &mut seen));
        seen.clear();
        self.monitor_settings
            .retain(|settings| first_for_identity(&settings.selector, &mut seen));
    }

    fn primary_wallpaper(&self) -> Option<&str> {
        self.monitors
            .iter()
            .find(|monitor| monitor.selector == SerializedSelector::Primary)
            .and_then(|monitor| monitor.wallpaper.as_deref())
    }
}

/// Renames the entry at `keep` to `current` and drops every other entry whose
/// selector `names_display` matches.
fn collapse_aliases<T>(
    entries: &mut Vec<T>,
    keep: usize,
    current: &SerializedSelector,
    selector: impl Fn(&mut T) -> &mut SerializedSelector,
    names_display: impl Fn(&SerializedSelector) -> bool,
) {
    let mut index = 0;
    entries.retain_mut(|entry| {
        let selector = selector(entry);
        let retained = if index == keep {
            selector.clone_from(current);
            true
        } else {
            !names_display(selector)
        };
        index += 1;
        retained
    });
}

/// False for an identity selector naming the same display as one already in
/// `seen` by UUID or serial; any other selector passes and identities are
/// recorded.
fn first_for_identity(selector: &SerializedSelector, seen: &mut Vec<DisplayIdentity>) -> bool {
    let DisplaySelector::Identity(identity) = selector.to_selector() else {
        return true;
    };
    if seen
        .iter()
        .any(|earlier| earlier.has_stable_match(&identity))
    {
        return false;
    }
    seen.push(identity);
    true
}

impl MonitorCfg {
    /// Whether the block shows a wallpaper of its own: it is switched on and
    /// does not mirror another display.
    fn shows_own_wallpaper(&self) -> bool {
        self.enabled && !self.mode.eq_ignore_ascii_case("mirror")
    }

    /// Configuration for a display seen for the first time. It starts enabled
    /// so plugging in a monitor needs no trip to Settings: a display the
    /// renderer already mirrors keeps that mirror, any other shows the primary
    /// display's wallpaper. Turning it off saves `enabled = false` under its
    /// selector, which outlives reconnection.
    #[must_use]
    fn for_connected_display(
        selector: SerializedSelector,
        display: &DisplaySnapshotEntry,
        primary_wallpaper: Option<&str>,
    ) -> Self {
        let mut monitor = Self {
            selector,
            ..Self::default()
        };
        if let Some(WallpaperAssignment::Mirror(target)) = display.assignment.as_ref() {
            monitor.mode = "mirror".to_string();
            monitor.mirror_target = Some(SerializedSelector::from_selector(target));
        } else {
            monitor.wallpaper = primary_wallpaper.map(str::to_owned);
        }
        monitor
    }
}

/// Saved-selector helpers for a display the engine reports.
pub trait DisplaySnapshotExt {
    /// The selector to save for a display that is plugged in right now: its
    /// identity when it has a stable one, else its live id for this session.
    fn connected_selector(&self) -> SerializedSelector;

    /// The selector the display's settings are filed under. The first display
    /// of `displays` is always the primary one, whatever its identity.
    fn config_selector(&self, displays: &[DisplaySnapshotEntry]) -> SerializedSelector;

    /// The identity selector, or nothing when the display cannot be told
    /// apart from another of the same model.
    fn stable_identity_selector(&self) -> Option<SerializedSelector>;

    /// Whether this entry and `primary` are one physical display, whatever
    /// ids the system has handed out for each of them.
    fn matches_primary(&self, primary: &Self) -> bool;
}

/// Questions about an identity that do not need a live display.
pub trait DisplayIdentityExt {
    /// Enough is known to recognise the display again later: a uuid, or a
    /// vendor and model together with a serial or unit number.
    fn has_stable_identity(&self) -> bool;

    /// The two identities describe the same panel. Identities with nothing in
    /// common to compare are never the same.
    fn same_physical_identity(&self, other: &Self) -> bool;
}

impl DisplayIdentityExt for DisplayIdentity {
    fn has_stable_identity(&self) -> bool {
        replacement::stable_identity_available(self)
    }

    fn same_physical_identity(&self, other: &Self) -> bool {
        self.match_score(other).is_some()
    }
}

/// Comparison of two display descriptions by the physical display behind them.
pub trait DisplayDescExt {
    /// The same display, by id or by identity. An id can be reused by another
    /// display after a reconnect, so the identity gets a say too.
    fn same_physical_display(&self, other: &Self) -> bool;
}

/// Looking up the display a saved selector stands for.
pub trait DisplaySelectorExt {
    /// Whether the selector currently names the primary display.
    /// `displays` is the whole list, for selectors that go through an id.
    fn matches_primary(
        &self,
        primary: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> bool;

    /// Whether the selector names this particular entry.
    /// The primary selector names no entry in particular, so it never does.
    fn matches_display(&self, display: &DisplaySnapshotEntry) -> bool;

    /// The entry the selector stands for, if that display is connected.
    /// The primary selector resolves to the first entry of the list.
    fn resolve_display<'a>(
        &self,
        displays: &'a [DisplaySnapshotEntry],
    ) -> Option<&'a DisplaySnapshotEntry>;
}
