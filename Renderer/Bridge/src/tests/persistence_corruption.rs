#[test]
fn backup_validation_rejects_corrupt_and_future_renderer_configurations() {
    use crate::{BridgeErrorKind, validate_backup_renderer_configuration};
    use std::collections::HashMap;

    for raw in ["not = [valid", "schema_version = 2\n"] {
        let error = validate_backup_renderer_configuration(Some(raw.into()), HashMap::new())
            .expect_err("an imported config must fail before replacing current settings");
        assert_eq!(error.kind(), BridgeErrorKind::Config);
    }
    for raw in ["{ invalid", r#"{"schema_version":2,"workshop_id":"300","type":"web"}"#] {
        let error = validate_backup_renderer_configuration(
            None, HashMap::from([("wallpapers/300.json".into(), raw.into())]),
        ).expect_err("invalid wallpaper settings must not be published");
        assert_eq!(error.kind(), BridgeErrorKind::Config);
    }
}
