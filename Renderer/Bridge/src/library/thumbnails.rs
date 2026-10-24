use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::time::SystemTime;

use image::ImageError;

pub const THUMB_SIDE: u32 = 200;
pub const CACHE_CAPACITY: usize = 512;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ThumbKey {
    pub id: String,
    pub mtime: Option<SystemTime>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThumbnailRgba {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub struct ThumbnailCache {
    capacity: usize,
    entries: HashMap<ThumbKey, ThumbnailRgba>,
    recency: VecDeque<ThumbKey>,
}

impl ThumbnailCache {
    #[must_use]
    pub fn new(cap: usize) -> Self {
        Self {
            capacity: cap,
            entries: HashMap::new(),
            recency: VecDeque::new(),
        }
    }

    #[must_use]
    pub fn get(&mut self, key: &ThumbKey) -> Option<ThumbnailRgba> {
        let thumbnail = self.entries.get(key)?.clone();
        let position = self
            .recency
            .iter()
            .position(|stored| stored == key)
            .expect("cached key has a recency record");
        let owned_key = self
            .recency
            .remove(position)
            .expect("located recency record exists");
        self.recency.push_back(owned_key);
        Some(thumbnail)
    }

    #[must_use]
    pub fn peek(&self, key: &ThumbKey) -> Option<ThumbnailRgba> {
        self.entries.get(key).cloned()
    }

    pub fn insert(&mut self, key: ThumbKey, thumbnail: ThumbnailRgba) {
        if self.capacity == 0 {
            return;
        }
        if let Some(stored) = self.entries.get_mut(&key) {
            *stored = thumbnail;
            let position = self
                .recency
                .iter()
                .position(|stored| stored == &key)
                .expect("cached key has a recency record");
            self.recency.remove(position);
            self.recency.push_back(key);
            return;
        }
        if self.entries.len() == self.capacity {
            let oldest = self
                .recency
                .pop_front()
                .expect("full nonzero cache has a least recent key");
            self.entries.remove(&oldest);
        }
        self.recency.push_back(key.clone());
        self.entries.insert(key, thumbnail);
    }
}

pub fn decode_and_crop(path: &Path) -> Result<ThumbnailRgba, ImageError> {
    use image::{AnimationDecoder, ImageFormat, ImageReader};

    let file = std::fs::File::open(path)?;
    let reader = ImageReader::new(std::io::BufReader::new(file)).with_guessed_format()?;
    let pixels = if reader.format() == Some(ImageFormat::Gif) {
        let decoder = image::codecs::gif::GifDecoder::new(reader.into_inner())?;
        let first_frame = decoder.into_frames().next();
        #[cfg(test)]
        let first_frame = test_controls::first_frame(first_frame);
        first_frame
            .transpose()?
            .ok_or_else(|| {
                ImageError::IoError(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "GIF contains no image frame",
                ))
            })?
            .into_buffer()
    } else {
        reader.decode()?.into_rgba8()
    };

    let side = pixels.width().min(pixels.height());
    let left = (pixels.width() - side) / 2;
    let top = (pixels.height() - side) / 2;
    let square = image::imageops::crop_imm(&pixels, left, top, side, side);
    let resized = image::imageops::resize(
        &*square,
        THUMB_SIDE,
        THUMB_SIDE,
        image::imageops::FilterType::Lanczos3,
    );
    Ok(ThumbnailRgba {
        width: THUMB_SIDE,
        height: THUMB_SIDE,
        rgba: resized.into_raw(),
    })
}

#[cfg(test)]
pub(super) mod test_controls {
    use std::cell::Cell;

    std::thread_local! {
        static EXHAUST_ONCE: Cell<bool> = const { Cell::new(false) };
    }

    struct Restore(bool);

    impl Drop for Restore {
        fn drop(&mut self) {
            EXHAUST_ONCE.with(|active| active.set(self.0));
        }
    }

    pub(crate) fn with_exhausted_first_frame<T>(operation: impl FnOnce() -> T) -> T {
        let previous = EXHAUST_ONCE.with(|active| active.replace(true));
        let _restore = Restore(previous);
        operation()
    }

    pub(crate) fn first_frame<T>(result: Option<T>) -> Option<T> {
        if EXHAUST_ONCE.with(|active| active.replace(false)) {
            None
        } else {
            result
        }
    }
}
