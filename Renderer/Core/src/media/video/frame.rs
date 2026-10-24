// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
/// A decoded video picture, either owned software pixels or a handle to a shared surface.
pub struct VideoFrame {
    width: u32,
    height: u32,
    storage: Storage,
}

enum Storage {
    Software { bytes_per_row: usize, bytes: Vec<u8> },
    /// A surface-backed picture; nothing builds one yet.
    #[allow(dead_code)]
    Surface { id: u32 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VideoFrameUploadFormat {
    Bgra8,
}

impl VideoFrame {
    /// # Errors
    ///
    /// Returns `InvalidInput` for a zero size, a row shorter than the pixels it holds
    /// or a buffer smaller than `bytes_per_row * height`.
    pub fn from_bgra_bytes(
        width: u32,
        height: u32,
        bytes_per_row: usize,
        bytes: Vec<u8>,
    ) -> Result<Self, crate::EngineError> {
        let invalid = |message: &str| crate::EngineError::InvalidInput(message.to_owned());

        if width == 0 || height == 0 {
            return Err(invalid("video frame dimensions must be non-zero"));
        }
        let packed_row = (width as usize)
            .checked_mul(4)
            .ok_or_else(|| invalid("video frame row size overflows"))?;
        if bytes_per_row < packed_row {
            return Err(invalid("video frame rows are shorter than their pixels"));
        }
        let needed = bytes_per_row
            .checked_mul(height as usize)
            .ok_or_else(|| invalid("video frame size overflows"))?;
        if bytes.len() < needed {
            return Err(invalid("video frame buffer is smaller than its rows require"));
        }
        Ok(Self {
            width,
            height,
            storage: Storage::Software { bytes_per_row, bytes },
        })
    }

    #[must_use]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[must_use]
    pub fn height(&self) -> u32 {
        self.height
    }

    #[must_use]
    pub fn upload_format(&self) -> Option<VideoFrameUploadFormat> {
        match self.storage {
            Storage::Software { .. } => Some(VideoFrameUploadFormat::Bgra8),
            Storage::Surface { .. } => None,
        }
    }

    #[must_use]
    pub fn bytes_per_row(&self) -> Option<usize> {
        match self.storage {
            Storage::Software { bytes_per_row, .. } => Some(bytes_per_row),
            Storage::Surface { .. } => None,
        }
    }

    #[must_use]
    pub fn as_bytes(&self) -> Option<&[u8]> {
        match &self.storage {
            Storage::Software { bytes, .. } => Some(bytes),
            Storage::Surface { .. } => None,
        }
    }

    #[must_use]
    pub fn io_surface_id(&self) -> Option<u32> {
        match self.storage {
            Storage::Software { .. } => None,
            Storage::Surface { id } => Some(id),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn software_for_testing(width: u32, height: u32) -> Self {
        let bytes_per_row = width as usize * 4;
        Self {
            width,
            height,
            storage: Storage::Software {
                bytes_per_row,
                bytes: vec![0; bytes_per_row * height as usize],
            },
        }
    }
}
