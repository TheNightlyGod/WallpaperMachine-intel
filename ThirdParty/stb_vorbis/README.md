# stb_vorbis

Ogg Vorbis decoder by Sean Barrett, version 1.22 (2021-07-11), one C source file.

- Source: https://github.com/nothings/stb, file `stb_vorbis.c` at commit
  `1ee679ca2ef753a528db5ba6801e1067b40481b8` ("update version numbers", 2021-07-12).
- Git blob `3e5c2504c08f76b9d04e4adfbce80818631e835e`, 192790 bytes, SHA-256
  `4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636`.
- License: public domain (Unlicense) or MIT, at the user's choice; `LICENSE` is the
  repository's license file at the same commit, and the file's own notice is at the
  end of `stb_vorbis.c`.
- Patched against the GitHub Security Lab findings upstream has not fixed: see
  `PATCHES.md`. It is built by `Renderer/Engine/Dependencies/CMakeLists.txt` as the static library
  `stb_vorbis` with `STB_VORBIS_NO_STDIO` and `STB_VORBIS_NO_PUSHDATA_API` (the
  decoder reads from memory and uses only the pull API), and used by
  `Renderer/Sound/Vorbis/VorbisDecoder.cpp`.
