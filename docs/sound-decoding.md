# Sound decoding

How a scene's sounds become audio for the output device, and what the project
writes itself versus asks the system for. The code is `Renderer/Sound` (`wmSound`,
a static library the scene engine's CMake includes) plus a thin layer in the
engine's `src/Audio`. Nothing here plays audio in a test: every test reads
samples from a stream or uses miniaudio's null backend, which discards them.

## The path

A scene sound reaches the device in four steps.

1. **`CreateSceneSoundStream`** (`src/Audio/SoundStreamFactory`) is the only
   place that decides which decoder serves a file. The package hands it the
   file's bytes through the engine's virtual file system; the factory reads the
   first four bytes, not the file name, and sends an Ogg file (`OggS`) to the Ogg
   Vorbis decoder and everything else to AudioToolbox.
2. **A decoder** (`Renderer/Sound`, a `PcmDecoder`) turns the file into
   interleaved 32-bit float frames at the file's own channel count and sample
   rate, from the first frame to the last, and back to the first on `rewind()`.
   It does nothing else.
3. **`PcmPipeline`** converts those frames to the device: channels first when
   mixing down, resampling at the smaller channel count, channels last when
   mixing up; a loop rewinds the decoder and starts over. One pass of a sound is
   its decoded frames resampled with the tail finished, so a loop is that pass
   over and over with no gap and no overlap at the seam. A sound with no frames
   ends even when it loops.
4. **`PcmSoundStream`** (`src/Audio`) is the `SoundStream` the output worker
   reads: it zero-fills what the pipeline did not produce, restarts the sound
   from its first frame when the device layout changes, and logs a failure once.

A sound the engine cannot decode (an unsupported codec, a file that is not
audio, a file whose headers are cut off) is not played: the layer stays silent
and the log names the reason. A file cut short in its audio plays what is there.
FFmpeg decodes no sound at all: neither a scene's sounds nor a video's.

The audio track of a plain video wallpaper does not come through here: the app's own players
play it (AVFoundation for MP4 and MOV, and for WebM and Matroska the track decoded by
`Matroska/MatroskaAudio`, below). The scene engine no longer builds a video's sound; its
`CreateMediaSoundStream` and the FFmpeg stream behind it were deleted on 2026-10-17.

## What is ours and what is the system's

| Piece | Where | Notes |
|---|---|---|
| Channel remix | `ChannelRemix` | The conventional downmix: matching positions pass through, the centre folds into left and right (and left and right into a mono centre) at -3 dB, surrounds fold forward at -3 dB, the low-frequency channel is dropped when it has nowhere to go. Layouts for 1 to 8 channels. Mono to stereo is therefore -3 dB per channel, as FFmpeg's resampler did |
| Resampling | `Resampler` | A polyphase windowed-sinc filter (Kaiser window, beta 9, 32 taps per output frame when raising the rate and proportionally more when lowering it, up to an input rate of about 62 times the output's: `Resampler::Supports` and `PcmPipeline::Supports` say no beyond that, and the sound stays silent with a log line rather than build a filter table of gigabytes). The cutoff is 97 percent of the output Nyquist frequency or the input's, whichever is lower, so raising the rate keeps the whole input band. Positions are integers: ratios such as 44.1 to 48 kHz use exact filter phases and nothing drifts. A pass of `n` frames produces exactly `ceil(n * out / in)` frames, and the first output frame lines up with the first input frame |
| Looping, end of sound | `PcmPipeline` | As above |
| WAV, AIFF, CAF, MP3, FLAC, AAC and the rest of AudioFile's formats | `Apple/AppleDecoder` | `AudioFileOpenWithCallbacks` over the package's bytes (a `media::ByteSource`, read on demand), then `ExtAudioFile` with a 32-bit float client format at the file's own layout, so the system changes the sample format and nothing else. A file whose format is not recognised by sniffing is retried with each likely type named. With `audioOptional`, an MP4 or MOV with no audio track returns no decoder and no error (a silent video is not a failure); anything else AudioToolbox cannot read is an error |
| Ogg Vorbis | `Vorbis/VorbisDecoder` | stb_vorbis 1.22 (public domain or MIT; vendored unchanged in `ThirdParty/stb_vorbis`, with its README recording the pinned commit and hash), because the system has no Vorbis decoder. The file is read into memory and decoded with the pull API. The length is the last Ogg page's granule position, so a loop has no extra tail (stb_vorbis would decode up to a block past it, and FFmpeg did: 192 frames in the test file). Channel order is rearranged from Vorbis's (left, centre, right, ..., low frequency last) to WAV's for 3 and 5 to 8 channels. stb_vorbis trusts the lengths in the comment header (vendor string, comment count, each comment), so a file that states two billion comments would crash it; `OpenVorbisDecoder` walks the first Ogg pages itself and checks every length against the header's bytes before stb_vorbis sees the file, and refuses a sample rate above 768 kHz (the file states its own rate, and the resampler's filter grows with it). A file that is Ogg but not Vorbis (Opus or FLAC in Ogg), whose headers are cut off or lie about their lengths, is refused; a file cut off in its audio plays what is there |

## The audio track of a WebM or Matroska video

`Matroska/MatroskaAudio` opens one audio track of a `MatroskaReader` as a `PcmDecoder`, so the
desktop's WebM player reads a video's sound through the same interface as a scene sound. It takes
packets from the reader's index and never opens an audio device.

- **Opus, AAC and MP3** go through an AudioToolbox `AudioConverter`, one packet at a time. Opus
  needs the packet's frame count for the converter, read from its table-of-contents byte
  (`OpusPacketFrames`, RFC 6716). The pre-skip in the `OpusHead` record is dropped from the start
  (less what the system's decoder has already trimmed from the first packet, measured on that
  packet so it does not depend on a constant), a block's DiscardPadding from its end, and the
  header's output gain applied. Opus above stereo (a channel mapping family other than 0) and more
  than two channels in the other codecs are refused, and the video plays silently with the reason
  logged. AAC takes its AudioSpecificConfig wrapped in the elementary-stream descriptor Core Audio
  expects as a magic cookie. A rewind makes a fresh converter, because a reset one does not trim the
  first packet again. AAC and MP3 decoder delay is not trimmed (a few tens of milliseconds).
- **Vorbis** has no system decoder. Matroska stores the three header packets laced in CodecPrivate
  and bare packets in the blocks, and stb_vorbis reads Ogg pages, so `OggVorbisFraming` writes an
  in-memory Ogg stream (RFC 3533: the identification packet alone on the first page, comment and
  setup after it, one page per audio packet, a correct page checksum) and the ordinary
  `OpenVorbisDecoder` reads that. Only the last page carries a granule position, the end of the
  last packet by its time, which is what makes the length exact; earlier pages state none, so
  stb_vorbis trims nothing from the start. The packets are held in memory while the track plays, so
  a track of more than 64 MiB is not decoded.

AudioToolbox's MP3 decoder is 16-bit and saturates at full scale; FFmpeg's float
decode kept peaks above full scale. Of the 87 MP3 sounds in the local library, 25
decode above 1.0 in FFmpeg (by up to 3 dB), and AudioToolbox clips those peaks at
1.0. It only matters when the wallpaper's volume is below full: the device clips
the same samples at full volume. There is no AudioToolbox setting for it, so a
decoder that keeps those peaks would have to be written.

## MP3 gapless playback

AudioToolbox follows the file's own gapless tag: the encoder delay and padding of
a LAME/Xing header give the length (`frames * 1152 - delay - padding`) and the
start, so a loop has no silence at the seam. A file without a tag decodes in full
with the decoder's own delay removed. FFmpeg's answer differed for files whose
tag claims too little padding to flush the decoder (it lost the last 529 frames)
and for the odd file whose tag it ignored. On the local library (103 scene sounds)
the decoded length equals FFmpeg's for 94; the other 9 are MP3s whose tag claims
no padding (AudioToolbox is 529 frames longer, the frames FFmpeg dropped) and one
whose tag FFmpeg ignored (AudioToolbox is 2160 frames shorter, as the tag says).

## Tests

- `audio_tests` (`tests/audio/sound_stream_test.cpp`): what a scene sound decodes
  to, through `CreateSoundStream`, whichever decoder sits behind it. WAV in every
  sample format, remixing, resampling lengths and tone, loop seams, end of file,
  refused and cut-short input, and the output worker on the null backend. The
  tiny MP3, Ogg Vorbis and FLAC files are in `sound_fixture_data.hpp`; their
  expectations were recorded from the FFmpeg decoder that served scene sounds
  before (the Ogg file's length is the granule's, which FFmpeg overshot). The Ogg
  file is a 440 Hz tone in both channels because FFmpeg's experimental Vorbis
  encoder writes streams that decoders disagree on once the channels differ; the
  three real libvorbis files in the local library decode to within -101 dB of
  FFmpeg's output with the same length.
- `sound_core_tests` (`Renderer/Sound/tests`): the resampler (including which
  ratios are supported and a ratio that skips more input than one push brings),
  the remix and the pipeline over synthetic decoders, with no Apple framework or
  file.
- `sound_vorbis_tests` (`Renderer/Sound/tests`): the Ogg Vorbis decoder over a tiny
  generated file: layout and exact length, any chunk size, rewind, files cut off
  inside the headers (refused) and inside the audio (played to the cut), refused
  input, 600 damaged variants that must neither crash nor produce a non-finite
  sample, 4000 more damaged in the identification and comment headers, comment
  headers of every shape (empty, long, continued on a second page) that must still
  open and ones that lie about their lengths (two billion comments, a vendor
  string longer than the file) that must be refused, sample rates no format
  uses, and the channel order. Run once under AddressSanitizer and UBSan: clean
  apart from one float-to-int conversion on a damaged codebook inside stb_vorbis
  itself, which is vendored unchanged.
- `sound_matroska_tests` (`Renderer/Sound/tests`): the Matroska audio decoders on real encoder
  output embedded as bytes (Opus, AAC and MP3 in a short clip each, Vorbis in WebM): format, length,
  a 440 Hz tone measured by zero crossings, a rewind that repeats the sound, Opus trimming by an exact
  frame count, Opus with an unsupported channel mapping refused, Vorbis packets in Matroska decoding
  sample for sample like the Ogg file they were cut from, and the Ogg framing (CodecPrivate
  splitting, page numbers, flags, checksums, a packet longer than a page).
- `sound_apple_tests` (`Renderer/Sound/tests`): the AudioToolbox decoder over a
  generated WAV and two tiny MP4 files: the reported layout, frames in any chunk
  size, rewind, the audio track of a video, and what it says about input that is
  not audio or has none.
