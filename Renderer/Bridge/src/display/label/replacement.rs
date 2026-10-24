use super::DisplayLabelExt;
use std::fmt::Write;
use wallpaper_core::{DisplayIdentity, DisplaySnapshotEntry};

fn assembled_label_body(identity: &DisplayIdentity) -> String {
    let hardware_present = identity.vendor_id.is_some() || identity.model_id.is_some();
    let supplied_name = identity.name.as_deref().filter(|name| *name != "Display");
    let mut text = String::new();

    if let Some(name) = supplied_name {
        text.push_str(name);
        if hardware_present {
            text.push_str(" - ");
        }
    } else if !hardware_present {
        text.push_str("Display");
    }

    if let Some(vendor) = identity.vendor_id {
        write!(text, "Vendor {vendor}").expect("writing to a String cannot fail");
        if identity.model_id.is_some() {
            text.push_str(" - ");
        }
    }
    if let Some(model) = identity.model_id {
        write!(text, "Model {model}").expect("writing to a String cannot fail");
    }
    text
}

impl DisplayLabelExt for DisplaySnapshotEntry {
    fn title(&self) -> String {
        let mut text = assembled_label_body(&self.identity);
        write!(text, " ({})", self.desc.display_id).expect("writing to a String cannot fail");
        text
    }

    fn title_with_role(&self, primary: bool) -> String {
        if !primary {
            return self.title();
        }
        let mut text = assembled_label_body(&self.identity);
        write!(text, " ({} - Primary)", self.desc.display_id)
            .expect("writing to a String cannot fail");
        text
    }

    fn title_with_suffix(&self, suffix: &str) -> String {
        let mut text = assembled_label_body(&self.identity);
        text.push(' ');
        text.push_str(suffix);
        text
    }
}
