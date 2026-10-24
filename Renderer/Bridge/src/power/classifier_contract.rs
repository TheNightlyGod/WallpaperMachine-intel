use super::PowerSource;
use objc2_core_foundation::CFString;

#[test]
fn constructed_ac_label_selects_external_supply() {
    let label = CFString::from_str("AC Power");

    assert_eq!(PowerSource::from(&*label), PowerSource::External);
}

#[test]
fn constructed_battery_and_ups_labels_share_battery_class() {
    for text in ["Battery Power", "UPS Power"] {
        let label = CFString::from_str(text);

        assert_eq!(PowerSource::from(&*label), PowerSource::Battery, "{text:?}");
    }
}

#[test]
fn unrelated_and_nonexact_labels_remain_unknown() {
    for text in [
        "Solar DC bus",
        "",
        "ac power",
        "ÅC Power",
        "\u{1D11E}C Power",
        "AC Power ",
        "Battery Power station",
        "UPS",
    ] {
        let label = CFString::from_str(text);

        assert_eq!(PowerSource::from(&*label), PowerSource::Unknown, "{text:?}");
    }
}
