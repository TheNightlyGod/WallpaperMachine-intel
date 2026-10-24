use crate::api::BridgeError;
use crate::config::{AppConfig, SerializedSelector};

impl AppConfig {
    pub fn validate_mirror_change(
        &self,
        selector: &SerializedSelector,
        target: &SerializedSelector,
    ) -> Result<(), BridgeError> {
        if selector == target {
            return Err(BridgeError::invalid_input(
                "A mirror cannot target its exact selector",
            ));
        }
        if self.monitors.is_empty() {
            return Err(BridgeError::invalid_input(
                "No configured monitor relationship is available",
            ));
        }

        // Indices identify effective first rows, not merely selector values: later
        // duplicate records remain uncovered even when their selector was visited.
        let mut covered_rows: Vec<usize> = Vec::new();
        let mut current = target;
        loop {
            if current == selector {
                return Err(BridgeError::invalid_input(
                    "The target relationship reaches the source",
                ));
            }
            let index = match self
                .monitors
                .iter()
                .position(|row| &row.selector == current)
            {
                Some(index) => index,
                None => {
                    return if covered_rows.len() < self.monitors.len() {
                        Ok(())
                    } else {
                        Err(BridgeError::invalid_input(
                            "The missing-ended relationship covers every saved record",
                        ))
                    };
                }
            };
            if covered_rows.contains(&index) {
                return Err(BridgeError::invalid_input(
                    "The target relationship contains a cycle",
                ));
            }
            covered_rows.push(index);
            let row = &self.monitors[index];
            if row.mode != "mirror" {
                return Ok(());
            }
            match row.mirror_target.as_ref() {
                Some(next) => current = next,
                None => return Ok(()),
            }
        }
    }
}
