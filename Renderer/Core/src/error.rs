// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    error::Error,
    fmt::{Display, Formatter},
};

#[derive(Debug)]
pub enum EngineError {
    InvalidInput(String),
    Platform(String),
    Render(String),
    Crash(String),
    UnsupportedPlatform(&'static str),
}

impl Display for EngineError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput(message)
            | Self::Platform(message)
            | Self::Render(message)
            | Self::Crash(message) => f.write_str(message),
            Self::UnsupportedPlatform(name) => write!(f, "unsupported platform: {name}"),
        }
    }
}

impl Error for EngineError {}
