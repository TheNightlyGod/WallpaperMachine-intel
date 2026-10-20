/// Stable identity for compiler options that affect generated SPIR-V.
pub(super) const COMPILER_OPTIONS_CACHE_SALT: &str =
    "naga-29.0.3-spv-no-coordinate-space-adjustment";

/// Typed pipeline revision included in cache key construction.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(transparent)]
pub struct ShaderPipelineRevision(u64);

impl ShaderPipelineRevision {
    /// Current default pipeline revision.
    ///
    /// Bumped whenever codegen can produce different output for source that
    /// already compiled. The on-disk program lookup is keyed on this identity
    /// and the source, before anything is compiled, so a stale entry would
    /// otherwise be served for a shader whose generated form has changed.
    pub const CURRENT: Self = Self(18);

    /// Creates a typed pipeline revision.
    #[must_use]
    pub const fn new(revision: u64) -> Self {
        Self(revision)
    }

    /// Returns the numeric revision.
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }
}
