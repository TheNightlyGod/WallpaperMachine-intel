#[test]
pub fn case_unwind_returns_crash_error() {
    let error = crate::owe::unwind::testing::panic_across_c_unwind_for_testing()
        .expect_err("unwind should become EngineError::Crash");

    assert!(
        matches!(error, crate::EngineError::Crash(message) if message.contains("test ffi unwind"))
    );
}
