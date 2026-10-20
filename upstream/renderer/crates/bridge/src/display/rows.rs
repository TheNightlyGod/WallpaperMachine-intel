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
    #[must_use]
    pub fn normalized(&self, displays: &[DisplaySnapshotEntry]) -> Self {
        let mut next = self.clone();
        next.sync_known_monitors(displays);
        next
    }

    #[must_use]
    pub fn monitor_rows(&self, displays: &[DisplaySnapshotEntry]) -> Vec<MonitorRow> {
        let mut rows = Vec::new();
        let primary = displays.first();

        for (index, display) in displays.iter().enumerate() {
            if index > 0 && primary.is_some_and(|primary| display.matches_primary(primary)) {
                continue;
            }

            let selector = if index == 0 {
                SerializedSelector::Primary
            } else {
                display.connected_selector()
            };
            let row_config = self
                .monitors
                .iter()
                .find(|monitor| monitor.selector == selector)
                .cloned()
                .unwrap_or_else(|| {
                    MonitorCfg::for_connected_display(
                        selector.clone(),
                        display,
                        self.primary_wallpaper(),
                    )
                });

            rows.push(MonitorRow {
                selector,
                config: row_config,
                connected: true,
                display_index: Some(index),
            });
        }

        for monitor in &self.monitors {
            if rows.iter().any(|row| row.selector == monitor.selector) {
                continue;
            }
            if primary.is_some_and(|primary| {
                monitor
                    .selector
                    .to_selector()
                    .matches_primary(primary, displays)
            }) {
                continue;
            }
            rows.push(MonitorRow {
                selector: monitor.selector.clone(),
                config: monitor.clone(),
                connected: false,
                display_index: None,
            });
        }

        rows
    }

    pub fn sync_known_monitors(&mut self, displays: &[DisplaySnapshotEntry]) -> bool {
        let before = self.monitors.clone();
        let settings_before = self.monitor_settings.clone();
        let primary_display_before = self.primary_display.clone();
        self.merge_display_aliases(displays);
        let mut primary = self
            .monitor_index(&SerializedSelector::Primary)
            .map_or_else(
                || MonitorCfg {
                    selector: SerializedSelector::Primary,
                    ..MonitorCfg::default()
                },
                |index| self.monitors.remove(index),
            );

        primary.selector = SerializedSelector::Primary;
        primary.enabled = true;
        primary.mode = "independent".to_string();
        primary.mirror_target = None;
        self.monitors.insert(0, primary);

        let primary_display = displays.first();
        if let Some(primary) = primary_display {
            let mut carried_wallpaper = None;
            self.monitors.retain(|monitor| {
                if monitor.selector == SerializedSelector::Primary {
                    return true;
                }
                if !matches!(monitor.selector, SerializedSelector::LiveDisplayId { .. }) {
                    return true;
                }

                if monitor
                    .selector
                    .to_selector()
                    .matches_primary(primary, displays)
                {
                    if carried_wallpaper.is_none() {
                        carried_wallpaper.clone_from(&monitor.wallpaper);
                    }
                    false
                } else {
                    true
                }
            });

            if let Some(wallpaper) = carried_wallpaper
                && let Some(primary_monitor) = self
                    .monitors
                    .iter_mut()
                    .find(|monitor| monitor.selector == SerializedSelector::Primary)
                && primary_monitor.wallpaper.is_none()
            {
                primary_monitor.wallpaper = Some(wallpaper);
            }

            if let Some(previous) = self.primary_display.as_ref().and_then(identity_of)
                && !previous.same_physical_identity(&primary.identity)
            {
                self.hand_over_primary(&previous, &primary.identity);
            }
            self.primary_display = primary.stable_identity_selector();

            if let Some(identity_selector) = primary.stable_identity_selector()
                && let Some(primary_index) = self.monitor_index(&SerializedSelector::Primary)
                && self.monitors[primary_index].wallpaper.is_none()
                && let Some(identity_index) = self.monitor_index(&identity_selector)
            {
                let identity_wallpaper =
                    self.monitors[identity_index].shown_wallpaper().map(str::to_owned);
                self.monitors[primary_index].wallpaper = identity_wallpaper;
            }
        }

        let primary_wallpaper = self.primary_wallpaper().map(str::to_owned);
        for (index, display) in displays.iter().enumerate() {
            if index == 0 {
                continue;
            }
            if primary_display.is_some_and(|primary| display.matches_primary(primary)) {
                continue;
            }

            let selector = display.connected_selector();
            if self.monitor_index(&selector).is_none() {
                self.monitors.push(MonitorCfg::for_connected_display(
                    selector,
                    display,
                    primary_wallpaper.as_deref(),
                ));
            }
        }

        self.monitors != before
            || self.monitor_settings != settings_before
            || self.primary_display != primary_display_before
    }

    /// Moves the `primary` block off the display that had the role onto the
    /// display macOS made the main one. The block's wallpaper is what the
    /// previous main display showed, so that display's own block keeps it, and
    /// the new main display shows what its own block says, a wallpaper it was
    /// switched off for included. A main display without a block of its own
    /// keeps the role's wallpaper, as a display seen for the first time does.
    fn hand_over_primary(&mut self, previous: &DisplayIdentity, current: &DisplayIdentity) {
        let Some(primary_index) = self.monitor_index(&SerializedSelector::Primary) else {
            return;
        };
        let role_wallpaper = self.monitors[primary_index].wallpaper.clone();
        match self.monitors.iter().position(|monitor| names_identity(monitor, previous)) {
            Some(index) => {
                let block = &mut self.monitors[index];
                if block.shown_wallpaper() != role_wallpaper.as_deref() {
                    if role_wallpaper.is_some() {
                        block.enabled = true;
                        block.mode = "independent".to_string();
                        block.mirror_target = None;
                    }
                    block.wallpaper = role_wallpaper;
                }
            }
            None => {
                if role_wallpaper.is_some() {
                    self.monitors.push(MonitorCfg {
                        selector: SerializedSelector::from_selector(&DisplaySelector::Identity(
                            previous.clone(),
                        )),
                        wallpaper: role_wallpaper,
                        ..MonitorCfg::default()
                    });
                }
            }
        }
        if let Some(own) = self.monitors.iter().find(|monitor| names_identity(monitor, current)) {
            let shown = own.shown_wallpaper().map(str::to_owned);
            self.monitors[primary_index].wallpaper = shown;
        }
    }

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

    pub fn ensure_monitor(&mut self, selector: SerializedSelector) -> &mut MonitorCfg {
        if let Some(index) = self.monitor_index(&selector) {
            return &mut self.monitors[index];
        }

        self.monitors.push(MonitorCfg {
            selector,
            ..MonitorCfg::default()
        });
        let index = self.monitors.len() - 1;
        &mut self.monitors[index]
    }

    fn monitor_index(&self, selector: &SerializedSelector) -> Option<usize> {
        self.monitors
            .iter()
            .position(|monitor| &monitor.selector == selector)
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

fn identity_of(selector: &SerializedSelector) -> Option<DisplayIdentity> {
    match selector.to_selector() {
        DisplaySelector::Identity(identity) => Some(identity),
        DisplaySelector::Primary | DisplaySelector::LiveDisplayId(_) => None,
    }
}

/// Whether `monitor` is the block saved under `identity`'s display, by UUID or
/// serial, the rule display sync renames and merges blocks by.
fn names_identity(monitor: &MonitorCfg, identity: &DisplayIdentity) -> bool {
    identity_of(&monitor.selector).is_some_and(|saved| saved.has_stable_match(identity))
}

impl SerializedSelector {
    #[must_use]
    pub fn mirror_target_id(
        &self,
        entry: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> Option<String> {
        match self {
            Self::Primary => displays
                .first()
                .filter(|display| display.desc.display_id != entry.desc.display_id)
                .map(|_| self.id()),
            Self::Identity { .. } | Self::LiveDisplayId { .. } => displays
                .iter()
                .find(|display| {
                    display.desc.display_id != entry.desc.display_id
                        && self.to_selector().matches_display(display)
                })
                .map(|display| display.config_selector(displays).id()),
        }
    }
}

impl MonitorCfg {
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

    /// The wallpaper this block puts on its display: none while the display
    /// is switched off or mirrors another one.
    fn shown_wallpaper(&self) -> Option<&str> {
        if !self.enabled || self.mode.eq_ignore_ascii_case("mirror") {
            return None;
        }
        self.wallpaper.as_deref()
    }
}

pub trait DisplaySnapshotExt {
    fn connected_selector(&self) -> SerializedSelector;
    fn config_selector(&self, displays: &[DisplaySnapshotEntry]) -> SerializedSelector;
    fn stable_identity_selector(&self) -> Option<SerializedSelector>;
    fn matches_primary(&self, primary: &Self) -> bool;
}

impl DisplaySnapshotExt for DisplaySnapshotEntry {
    fn connected_selector(&self) -> SerializedSelector {
        self.stable_identity_selector()
            .unwrap_or(SerializedSelector::LiveDisplayId {
                display_id: self.desc.display_id,
            })
    }

    fn config_selector(&self, displays: &[DisplaySnapshotEntry]) -> SerializedSelector {
        if displays
            .first()
            .is_some_and(|primary| self.matches_primary(primary))
        {
            SerializedSelector::Primary
        } else {
            self.connected_selector()
        }
    }

    fn stable_identity_selector(&self) -> Option<SerializedSelector> {
        self.identity.has_stable_identity().then(|| {
            SerializedSelector::from_selector(&DisplaySelector::Identity(self.identity.clone()))
        })
    }

    fn matches_primary(&self, primary: &Self) -> bool {
        self.desc.display_id == primary.desc.display_id
            || primary.identity.same_physical_identity(&self.identity)
    }
}

pub trait DisplayIdentityExt {
    fn has_stable_identity(&self) -> bool;
    fn same_physical_identity(&self, other: &Self) -> bool;
}

impl DisplayIdentityExt for DisplayIdentity {
    fn has_stable_identity(&self) -> bool {
        self.uuid.as_deref().is_some_and(|uuid| !uuid.is_empty())
            || (self.vendor_id.is_some()
                && self.model_id.is_some()
                && (self.serial_number.is_some() || self.unit_number.is_some()))
    }

    fn same_physical_identity(&self, other: &Self) -> bool {
        self.match_score(other).is_some()
    }
}

pub trait DisplayDescExt {
    fn same_physical_display(&self, other: &Self) -> bool;
}

impl DisplayDescExt for DisplayDesc {
    fn same_physical_display(&self, other: &Self) -> bool {
        self.display_id == other.display_id || self.identity.same_physical_identity(&other.identity)
    }
}

pub trait DisplaySelectorExt {
    fn matches_primary(
        &self,
        primary: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> bool;
    fn matches_display(&self, display: &DisplaySnapshotEntry) -> bool;
    fn resolve_display<'a>(
        &self,
        displays: &'a [DisplaySnapshotEntry],
    ) -> Option<&'a DisplaySnapshotEntry>;
}

impl DisplaySelectorExt for DisplaySelector {
    fn matches_primary(
        &self,
        primary: &DisplaySnapshotEntry,
        displays: &[DisplaySnapshotEntry],
    ) -> bool {
        match self {
            Self::Primary => true,
            Self::LiveDisplayId(display_id) => {
                *display_id == primary.desc.display_id
                    || displays
                        .iter()
                        .find(|display| display.desc.display_id == *display_id)
                        .is_some_and(|display| display.matches_primary(primary))
            }
            Self::Identity(identity) => primary.identity.same_physical_identity(identity),
        }
    }

    fn matches_display(&self, display: &DisplaySnapshotEntry) -> bool {
        match self {
            Self::Primary => false,
            Self::Identity(identity) => display.identity.match_score(identity).is_some(),
            Self::LiveDisplayId(display_id) => display.desc.display_id == *display_id,
        }
    }

    fn resolve_display<'a>(
        &self,
        displays: &'a [DisplaySnapshotEntry],
    ) -> Option<&'a DisplaySnapshotEntry> {
        match self {
            Self::Primary => displays.first(),
            Self::Identity { .. } | Self::LiveDisplayId { .. } => displays
                .iter()
                .find(|display| self.matches_display(display)),
        }
    }
}
