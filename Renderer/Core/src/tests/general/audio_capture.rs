use crate::media::audio::{
    AudioCaptureBackend, AudioCaptureError, AudioInputError, AudioResponseBlock,
    AudioResponseResampler, InterleavedStereoF32, MonoPcmF32, PlatformAudioCaptureBackend,
};

/// Collects emitted blocks as owned samples so assertions can outlive the
/// resampler's borrow.
#[derive(Default)]
struct CollectedBlocks {
    mono: Vec<Vec<f32>>,
    stereo: Vec<Vec<f32>>,
}

impl CollectedBlocks {
    fn collector(&mut self) -> impl FnMut(AudioResponseBlock<'_>) + '_ {
        |block| match block {
            AudioResponseBlock::Mono(frames) => {
                assert_eq!(frames.sample_rate(), AudioResponseResampler::TARGET_SAMPLE_RATE);
                self.mono.push(frames.samples().to_vec());
            }
            AudioResponseBlock::Stereo(frames) => {
                assert_eq!(frames.sample_rate(), AudioResponseResampler::TARGET_SAMPLE_RATE);
                self.stereo.push(frames.samples().to_vec());
            }
        }
    }
}

#[test]
pub fn case_interleaved_stereo_rejects_invalid_buffers() {
    assert!(matches!(
        InterleavedStereoF32::new(0, &[0.0, 0.0]),
        Err(AudioInputError::InvalidSampleRate)
    ));
    assert!(matches!(
        InterleavedStereoF32::new(48_000, &[]),
        Err(AudioInputError::EmptyInput)
    ));
    assert!(matches!(
        InterleavedStereoF32::new(48_000, &[0.0]),
        Err(AudioInputError::OddSampleCount(1))
    ));
}

#[test]
pub fn case_mono_pcm_rejects_invalid_buffers() {
    assert!(matches!(
        MonoPcmF32::borrowed(0, &[0.0]),
        Err(AudioInputError::InvalidSampleRate)
    ));
    assert!(matches!(
        MonoPcmF32::borrowed(AudioResponseResampler::TARGET_SAMPLE_RATE, &[]),
        Err(AudioInputError::EmptyInput)
    ));
}

const TARGET: u32 = AudioResponseResampler::TARGET_SAMPLE_RATE;
const BLOCK: usize = AudioResponseResampler::BLOCK_FRAMES;

#[test]
pub fn case_audio_response_resampler_passes_the_analysis_rate_through() {
    let mut resampler = AudioResponseResampler::new();
    let input = vec![0.5f32; BLOCK];
    let input = MonoPcmF32::borrowed(TARGET, &input).expect("valid mono input");

    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&input, collected.collector());

    assert!(collected.stereo.is_empty());
    assert_eq!(collected.mono.len(), 1);
    assert_eq!(collected.mono[0], vec![0.5f32; BLOCK]);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_audio_response_resampler_converts_96khz_mono_to_the_analysis_rate() {
    let mut resampler = AudioResponseResampler::new();
    #[allow(clippy::cast_precision_loss)]
    let input = (0..BLOCK * 2).map(|frame| frame as f32).collect::<Vec<_>>();
    let input = MonoPcmF32::borrowed(TARGET * 2, &input).expect("valid mono input");

    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&input, collected.collector());

    assert_eq!(collected.mono.len(), 1);
    #[allow(clippy::cast_precision_loss)]
    let expected = (0..BLOCK).map(|frame| (frame * 2) as f32).collect::<Vec<_>>();
    assert_eq!(collected.mono[0], expected);
}

#[test]
pub fn case_audio_response_resampler_buffers_partial_blocks() {
    let mut resampler = AudioResponseResampler::new();
    let first = vec![1.0f32; BLOCK / 2];
    let second = vec![1.0f32; BLOCK / 2];

    let first = MonoPcmF32::borrowed(TARGET, &first).expect("valid first chunk");
    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&first, collected.collector());
    assert!(collected.mono.is_empty());

    let second = MonoPcmF32::borrowed(TARGET, &second).expect("valid second chunk");
    resampler.push_mono(&second, collected.collector());
    assert_eq!(collected.mono.len(), 1);
    assert_eq!(collected.mono[0].len(), BLOCK);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_audio_response_resampler_resets_interpolation_across_rate_changes() {
    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();
    let first = MonoPcmF32::borrowed(TARGET * 2, &[1.0, 2.0, 99.0]).unwrap();
    resampler.push_mono(&first, collected.collector());
    assert!(collected.mono.is_empty());
    let bypass_samples = vec![3.0f32; BLOCK - 2];
    let bypass = MonoPcmF32::borrowed(TARGET, &bypass_samples).unwrap();
    resampler.push_mono(&bypass, collected.collector());
    assert!(collected.mono.is_empty());
    let last = MonoPcmF32::borrowed(TARGET * 2, &[4.0, 5.0]).unwrap();
    resampler.push_mono(&last, collected.collector());

    assert_eq!(collected.mono.len(), 1);
    let block = &collected.mono[0];
    assert_eq!(block[0], 1.0);
    assert_eq!(&block[1..BLOCK - 1], bypass_samples.as_slice());
    assert_eq!(block[BLOCK - 1], 4.0);
}

#[test]
pub fn case_audio_response_resampler_keeps_stereo_channels_independent() {
    // 96 kHz stereo where the two channels never share a value: a downmix
    // would show up immediately as averaged samples.
    let mut source = Vec::with_capacity(BLOCK * 4);
    for frame in 0..u32::try_from(BLOCK * 2).unwrap() {
        source.push(f32::from(u16::try_from(frame).unwrap()));
        source.push(-f32::from(u16::try_from(frame).unwrap()));
    }
    let input = InterleavedStereoF32::new(TARGET * 2, &source).expect("valid stereo input");

    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();
    resampler.push_stereo(&input, collected.collector());

    assert!(collected.mono.is_empty());
    assert_eq!(collected.stereo.len(), 1);
    let block = &collected.stereo[0];
    assert_eq!(block.len(), BLOCK * 2);
    for frame in 0..BLOCK {
        let expected = f32::from(u16::try_from(frame * 2).unwrap());
        assert_eq!(block[frame * 2], expected);
        assert_eq!(block[(frame * 2) + 1], -expected);
    }
}

#[test]
pub fn case_audio_response_resampler_discards_buffered_frames_on_layout_change() {
    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();

    let partial = vec![1.0f32; BLOCK / 2];
    let partial = MonoPcmF32::borrowed(TARGET, &partial).expect("valid mono chunk");
    resampler.push_mono(&partial, collected.collector());
    assert!(!resampler.pending_for_testing().is_empty());

    // A block of stereo frames is a whole block only if the buffered mono
    // frames were dropped rather than reinterpreted as interleaved samples.
    let stereo = vec![0.25f32; BLOCK * 2];
    let stereo = InterleavedStereoF32::new(TARGET, &stereo).expect("valid stereo chunk");
    resampler.push_stereo(&stereo, collected.collector());

    assert!(collected.mono.is_empty());
    assert_eq!(collected.stereo.len(), 1);
    assert_eq!(collected.stereo[0], vec![0.25f32; BLOCK * 2]);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_platform_audio_backend_constructs_or_reports_unsupported() {
    match PlatformAudioCaptureBackend::new() {
        Ok(backend) => assert!(!backend.is_running()),
        Err(AudioCaptureError::UnsupportedPlatform) => {}
        Err(error) => panic!("unexpected platform backend error: {error}"),
    }
}
