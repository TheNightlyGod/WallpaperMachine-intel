//! Unpacks Steam depot content (chunks and manifests) once the app has decrypted it.
//!
//! Steam's CDN serves three containers, told apart by their first bytes: `VSZa`
//! (zstd), `VZa` (raw LZMA, "VZip") and `PK\x03\x04` (a one-entry zip archive).
//! The app does the network, AES and SHA-1 work in Swift; macOS has no public
//! zstd or raw-LZMA decoder, which is why this step lives in the bridge.

use std::io::Read;

use crate::api::{BridgeError, BridgeErrorKind};

const ZSTD_HEADER: &[u8] = b"VSZa";
const ZSTD_FOOTER: &[u8] = b"zsv";
const VZIP_HEADER: &[u8] = b"VZa";
const VZIP_FOOTER: &[u8] = b"zv";
const ZIP_HEADER: &[u8] = b"PK\x03\x04";
const ZIP_END_OF_DIRECTORY: &[u8] = b"PK\x05\x06";
const ZIP_DIRECTORY_ENTRY: &[u8] = b"PK\x01\x02";

/// The largest chunk or manifest Steam is expected to send once unpacked. A
/// chunk is at most 1 MiB; manifests of large depots reach tens of MiB.
const MAX_UNPACKED: usize = 512 * 1024 * 1024;

/// Unpacks one decrypted Steam content blob and checks its CRC-32 where the
/// container carries one.
///
/// # Errors
///
/// Returns `InvalidInput` when the container is unknown, truncated, fails to
/// decode, or unpacks to a size or CRC other than the one it declares.
#[uniffi::export]
pub fn decompress_steam_content(data: Vec<u8>) -> Result<Vec<u8>, BridgeError> {
    if data.starts_with(ZSTD_HEADER) {
        unpack_zstd(&data)
    } else if data.starts_with(VZIP_HEADER) {
        unpack_vzip(&data)
    } else if data.starts_with(ZIP_HEADER) {
        unpack_zip(&data)
    } else {
        let head: Vec<String> = data.iter().take(4).map(|byte| format!("{byte:02x}")).collect();
        Err(invalid(format!("unknown Steam content container (starts {})", head.join(" "))))
    }
}

fn invalid(message: String) -> BridgeError {
    BridgeError::Error { kind: BridgeErrorKind::InvalidInput, message }
}

fn u16_at(data: &[u8], offset: usize) -> Result<u16, BridgeError> {
    data.get(offset..offset + 2)
        .map(|bytes| u16::from_le_bytes([bytes[0], bytes[1]]))
        .ok_or_else(|| invalid("Steam content is truncated".into()))
}

fn u32_at(data: &[u8], offset: usize) -> Result<u32, BridgeError> {
    data.get(offset..offset + 4)
        .map(|bytes| u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        .ok_or_else(|| invalid("Steam content is truncated".into()))
}

fn checked_size(declared: u32) -> Result<usize, BridgeError> {
    let size = usize::try_from(declared).map_err(|_| invalid("declared size does not fit".into()))?;
    if size > MAX_UNPACKED {
        return Err(invalid(format!("declared size {size} is larger than any Steam chunk")));
    }
    Ok(size)
}

fn verify(output: Vec<u8>, size: usize, crc: u32, format: &str) -> Result<Vec<u8>, BridgeError> {
    if output.len() != size {
        return Err(invalid(format!("{format}: unpacked {} bytes, expected {size}", output.len())));
    }
    let mut hasher = flate2::Crc::new();
    hasher.update(&output);
    if hasher.sum() != crc {
        return Err(invalid(format!("{format}: CRC mismatch")));
    }
    Ok(output)
}

/// `VSZa`, 4 bytes of CRC, the zstd frame, then CRC-32, size, 4 zero bytes and `zsv`.
fn unpack_zstd(data: &[u8]) -> Result<Vec<u8>, BridgeError> {
    const FOOTER_LEN: usize = 15;
    if data.len() < ZSTD_HEADER.len() + 4 + FOOTER_LEN || !data.ends_with(ZSTD_FOOTER) {
        return Err(invalid("zstd: missing footer".into()));
    }
    let footer = data.len() - FOOTER_LEN;
    let crc = u32_at(data, footer)?;
    let size = checked_size(u32_at(data, footer + 4)?)?;
    let mut frame = &data[ZSTD_HEADER.len() + 4..footer];
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(&mut frame)
        .map_err(|error| invalid(format!("zstd: {error}")))?;
    let mut output = Vec::with_capacity(size);
    decoder
        .by_ref()
        .take(MAX_UNPACKED as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|error| invalid(format!("zstd: {error}")))?;
    verify(output, size, crc, "zstd")
}

/// `VZa`, 4 bytes of CRC or timestamp, 5 LZMA properties, the raw LZMA stream,
/// then CRC-32, size and `zv`.
fn unpack_vzip(data: &[u8]) -> Result<Vec<u8>, BridgeError> {
    const PROPERTIES_AT: usize = 7;
    const FOOTER_LEN: usize = 10;
    if data.len() < PROPERTIES_AT + 5 + FOOTER_LEN || !data.ends_with(VZIP_FOOTER) {
        return Err(invalid("VZip: missing footer".into()));
    }
    let footer = data.len() - FOOTER_LEN;
    let crc = u32_at(data, footer)?;
    let declared = u32_at(data, footer + 4)?;
    let size = checked_size(declared)?;
    // lzma-rs reads the classic `.lzma` header: the properties, then the size as a u64.
    let mut stream = Vec::with_capacity(footer - PROPERTIES_AT + 8);
    stream.extend_from_slice(&data[PROPERTIES_AT..PROPERTIES_AT + 5]);
    stream.extend_from_slice(&u64::from(declared).to_le_bytes());
    stream.extend_from_slice(&data[PROPERTIES_AT + 5..footer]);
    let mut output = Vec::with_capacity(size);
    lzma_rs::lzma_decompress(&mut stream.as_slice(), &mut output)
        .map_err(|error| invalid(format!("VZip: {error}")))?;
    verify(output, size, crc, "VZip")
}

/// A zip archive with one entry, stored or deflated. Sizes and the CRC come from
/// the central directory, since a local header may defer them to a data descriptor.
fn unpack_zip(data: &[u8]) -> Result<Vec<u8>, BridgeError> {
    const END_LEN: usize = 22;
    let end = data
        .len()
        .checked_sub(END_LEN)
        .and_then(|last| (0..=last).rev().find(|&at| data[at..].starts_with(ZIP_END_OF_DIRECTORY)))
        .ok_or_else(|| invalid("zip: no end of central directory".into()))?;
    let directory = usize::try_from(u32_at(data, end + 16)?).map_err(|_| invalid("zip: bad offset".into()))?;
    if !data.get(directory..).is_some_and(|rest| rest.starts_with(ZIP_DIRECTORY_ENTRY)) {
        return Err(invalid("zip: no central directory entry".into()));
    }
    let method = u16_at(data, directory + 10)?;
    let crc = u32_at(data, directory + 16)?;
    let compressed = usize::try_from(u32_at(data, directory + 20)?).map_err(|_| invalid("zip: bad size".into()))?;
    let size = checked_size(u32_at(data, directory + 24)?)?;
    let local = usize::try_from(u32_at(data, directory + 42)?).map_err(|_| invalid("zip: bad offset".into()))?;
    if !data.get(local..).is_some_and(|rest| rest.starts_with(ZIP_HEADER)) {
        return Err(invalid("zip: no local header".into()));
    }
    let start = local + 30 + usize::from(u16_at(data, local + 26)?) + usize::from(u16_at(data, local + 28)?);
    let body = data
        .get(start..start + compressed)
        .ok_or_else(|| invalid("zip: entry is truncated".into()))?;
    let output = match method {
        0 => body.to_vec(),
        8 => {
            let mut output = Vec::with_capacity(size);
            flate2::read::DeflateDecoder::new(body)
                .take(MAX_UNPACKED as u64 + 1)
                .read_to_end(&mut output)
                .map_err(|error| invalid(format!("zip: {error}")))?;
            output
        }
        other => return Err(invalid(format!("zip: unsupported method {other}"))),
    };
    verify(output, size, crc, "zip")
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::decompress_steam_content;

    fn sample() -> Vec<u8> {
        (0..70_000u32).flat_map(|i| (i % 251).to_le_bytes()).collect()
    }

    fn crc(data: &[u8]) -> u32 {
        let mut hasher = flate2::Crc::new();
        hasher.update(data);
        hasher.sum()
    }

    fn footer(data: &[u8]) -> Vec<u8> {
        let mut footer = crc(data).to_le_bytes().to_vec();
        footer.extend_from_slice(&u32::try_from(data.len()).unwrap().to_le_bytes());
        footer
    }

    fn zstd(data: &[u8]) -> Vec<u8> {
        let frame = ruzstd::encoding::compress_to_vec(data, ruzstd::encoding::CompressionLevel::Fastest);
        let mut packed = b"VSZa\0\0\0\0".to_vec();
        packed.extend_from_slice(&frame);
        packed.extend_from_slice(&footer(data));
        packed.extend_from_slice(b"\0\0\0\0zsv");
        packed
    }

    fn vzip(data: &[u8]) -> Vec<u8> {
        let mut lzma = Vec::new();
        lzma_rs::lzma_compress(&mut &data[..], &mut lzma).unwrap();
        // Drop the `.lzma` header's u64 size: VZip keeps only the 5 property bytes.
        let mut packed = b"VZa\0\0\0\0".to_vec();
        packed.extend_from_slice(&lzma[..5]);
        packed.extend_from_slice(&lzma[13..]);
        packed.extend_from_slice(&footer(data));
        packed.extend_from_slice(b"zv");
        packed
    }

    fn zip(data: &[u8], deflate: bool) -> Vec<u8> {
        let body = if deflate {
            let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
            encoder.write_all(data).unwrap();
            encoder.finish().unwrap()
        } else {
            data.to_vec()
        };
        let method: u16 = if deflate { 8 } else { 0 };
        let compressed = u32::try_from(body.len()).unwrap();
        let size = u32::try_from(data.len()).unwrap();
        let name = b"z";
        let mut archive = b"PK\x03\x04".to_vec();
        // Version, then flag bit 3: sizes deferred to a data descriptor, as streaming writers do.
        archive.extend_from_slice(&[20, 0, 8, 0]);
        archive.extend_from_slice(&method.to_le_bytes());
        archive.extend_from_slice(&[0; 16]);
        archive.extend_from_slice(&u16::try_from(name.len()).unwrap().to_le_bytes());
        archive.extend_from_slice(&[0, 0]);
        archive.extend_from_slice(name);
        archive.extend_from_slice(&body);
        let directory = u32::try_from(archive.len()).unwrap();
        archive.extend_from_slice(b"PK\x01\x02");
        archive.extend_from_slice(&[20, 0, 20, 0, 8, 0]);
        archive.extend_from_slice(&method.to_le_bytes());
        archive.extend_from_slice(&[0; 4]);
        archive.extend_from_slice(&crc(data).to_le_bytes());
        archive.extend_from_slice(&compressed.to_le_bytes());
        archive.extend_from_slice(&size.to_le_bytes());
        archive.extend_from_slice(&u16::try_from(name.len()).unwrap().to_le_bytes());
        archive.extend_from_slice(&[0; 12]);
        archive.extend_from_slice(&0u32.to_le_bytes());
        archive.extend_from_slice(name);
        let directory_len = u32::try_from(archive.len()).unwrap() - directory;
        archive.extend_from_slice(b"PK\x05\x06");
        archive.extend_from_slice(&[0, 0, 0, 0, 1, 0, 1, 0]);
        archive.extend_from_slice(&directory_len.to_le_bytes());
        archive.extend_from_slice(&directory.to_le_bytes());
        archive.extend_from_slice(&[0, 0]);
        archive
    }

    #[test]
    fn unpacks_every_container_steam_serves() {
        let data = sample();
        for (name, packed) in [
            ("zstd", zstd(&data)),
            ("vzip", vzip(&data)),
            ("zip stored", zip(&data, false)),
            ("zip deflated", zip(&data, true)),
        ] {
            assert_eq!(decompress_steam_content(packed).unwrap(), data, "{name}");
        }
    }

    #[test]
    fn rejects_content_whose_crc_does_not_match() {
        let data = sample();
        for mut packed in [zstd(&data), vzip(&data)] {
            let crc_at = packed.len() - if packed.ends_with(b"zsv") { 15 } else { 10 };
            packed[crc_at] ^= 0xFF;
            assert!(decompress_steam_content(packed).is_err());
        }
    }

    #[test]
    fn rejects_unknown_and_truncated_content() {
        assert!(decompress_steam_content(b"nope".to_vec()).is_err());
        assert!(decompress_steam_content(Vec::new()).is_err());
        let packed = vzip(&sample());
        assert!(decompress_steam_content(packed[..packed.len() / 2].to_vec()).is_err());
        let packed = zip(&sample(), true);
        assert!(decompress_steam_content(packed[..40].to_vec()).is_err());
    }
}
