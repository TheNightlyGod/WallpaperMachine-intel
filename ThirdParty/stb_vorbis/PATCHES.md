# Patches against stb_vorbis 1.22

`stb_vorbis.c` is upstream's file at `1ee679ca2ef753a528db5ba6801e1067b40481b8` (see
`README.md`) with the changes below, made 2026-10-25. Upstream has not fixed the GitHub
Security Lab findings GHSL-2023-165 to 172 (CVE-2023-45675 to 45682); each change names the
one it closes. The diff against the pinned blob is the whole record: nothing else differs.

1. `Mapping.submap_floor` and `submap_residue` hold 16 entries, not 15. The four-bit submap
   count allows sixteen, and the sixteenth was written past the table (CVE-2023-45678).
2. `DECODE` uses a decoded value as an index into `sorted_values` only when it is not a miss
   (`var >= 0`). A sparse book whose entries all lack a codeword has no `sorted_values`, and
   the miss read before it (CVE-2023-45682).
3. In `start_decoder`, a vendor or comment length that is negative or above `INT_MAX - 8` as
   an `int` (so `len + 1` would be 0, or overflow once `setup_malloc` rounds it up to a
   multiple of 8), and a comment count that does not fit an `int`
   allocation, are an invalid setup (CVE-2023-45675, 45677, 45681). A comment list that is
   refused or cannot be allocated leaves `comment_list_length` at 0, and a new list starts
   zeroed, so `vorbis_deinit` never frees an unset entry or walks a NULL list (CVE-2023-45679,
   45680); `vorbis_deinit` also checks the list itself.
4. `lookup1_values` compares its powers as doubles instead of casting them to `int`, which
   was undefined for a damaged header's large values (found by the decoder tests under UBSan).

`Renderer/Sound/Vorbis/VorbisDecoder.cpp` still checks the comment header's lengths against
its bytes before stb_vorbis reads the file. The engine never passes an `alloc_buffer`, so
`setup_malloc`'s arithmetic for one (CVE-2023-45676) is not reachable and is not changed.
`sound_vorbis_tests` covers 1 and 2 with streams written from the specification.
