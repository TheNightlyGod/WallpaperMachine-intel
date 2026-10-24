mod replacement;

pub trait DisplayLabelExt {
    fn title(&self) -> String;
    fn title_with_role(&self, primary: bool) -> String;
    fn title_with_suffix(&self, suffix: &str) -> String;
}
