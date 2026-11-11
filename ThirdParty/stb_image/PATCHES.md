# Patches against stb_image 2.30

`stb_image.h` is upstream's 2.30 (nothings/stb `013ac3beddff3dbffafd5177e7972067cd2b5083`,
git blob `9eedabedc45b3e6fd88fae6f14a160b4d53272ec`) with the changes below. The diff against
that blob is the whole record: nothing else differs.

1. `stbi__convert_16_to_8` and `stbi__convert_8_to_16` free their input when the output cannot
   be allocated, and `stbi__load_and_postprocess_8bit` / `_16bit` return on a failed
   conversion before the optional flip. Carried over from the project's 2.26 copy, where it
   was added with `StbImageRegression.BitDepthConversionFailuresReleaseInputBeforeOptionalFlip`;
   upstream has neither.
2. `stbi__tga_load` refuses an uncompressed image whose rows the file does not hold, instead
   of returning the uninitialised rest of its buffer as pixels (CVE-2023-45663, GHSL-2023-147,
   not fixed upstream). The HDR half of that finding is not built here.
3. `stbi__decode_jpeg_image` treats a marker it cannot process as the end of the image only
   once a scan has been decoded (junk after the image still ends it). Before one, it fails:
   upstream reported success and the caller converted the uninitialised component buffers
   into pixels.

`Renderer/Engine/src/Scene/Parse/WPTexImageParser.cpp`, the only production user, builds it
with `STBI_ONLY_PNG`, `STBI_ONLY_JPEG`, `STBI_ONLY_BMP`, `STBI_ONLY_GIF` and `STBI_ONLY_TGA`
(no PSD, PIC, PNM or HDR decoder, the formats of GHSL-2023-149 and CVE-2021-42715), with
`STBI_MAX_DIMENSIONS` 16384 (the largest texture the GPU takes, so a larger picture is refused
before its pixels are allocated) and with `STBI_NEON` on arm64. It decodes only through
`stbi_load_from_memory` and `stbi_info_from_callbacks`, never the animated-GIF or vertical-flip
paths of GHSL-2023-145, 146, 148, 150 and 151.
