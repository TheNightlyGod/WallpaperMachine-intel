// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    ffi::{CStr, c_void},
    mem,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr::{self, NonNull},
    sync::{Arc, Mutex},
};

use objc2::{AnyThread, ClassType, runtime::AnyObject, sel};
use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart,
    AudioDeviceStop, AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap, AudioObjectGetPropertyData,
    AudioObjectID, AudioObjectPropertyAddress, CATapDescription, CATapMuteBehavior,
    kAudioAggregateDeviceIsPrivateKey, kAudioAggregateDeviceNameKey,
    kAudioAggregateDeviceTapAutoStartKey, kAudioAggregateDeviceTapListKey,
    kAudioAggregateDeviceUIDKey, kAudioAggregateDriftCompensationMediumQuality,
    kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyScopeGlobal, kAudioObjectUnknown, kAudioSubTapDriftCompensationKey,
    kAudioSubTapDriftCompensationQualityKey, kAudioSubTapUIDKey, kAudioTapPropertyFormat,
};
use objc2_core_audio_types::{AudioBuffer, AudioBufferList, AudioStreamBasicDescription, AudioTimeStamp};
use objc2_core_foundation::CFDictionary;
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSString};

use super::{
    AudioCaptureBackend, AudioCaptureError, AudioFrameConsumer, AudioResponseController,
    AudioTapChannelMode, InterleavedStereoF32, MonoPcmF32,
};

pub type DefaultAudioResponseController =
    AudioResponseController<crate::WallpaperEngine, PlatformAudioCaptureBackend>;

/// The I/O callback works on slices of at most this many frames.
const CALLBACK_CHUNK_FRAMES: usize = 1024;
const SYSTEM_OBJECT: AudioObjectID = 1;

/// What the I/O callback owns: where the frames go and the scratch it converts into.
struct CallbackState {
    consumer: Arc<dyn AudioFrameConsumer>,
    channel_mode: AudioTapChannelMode,
    sample_rate: u32,
    scratch: Mutex<Vec<f32>>,
}

/// Native teardown is injected only at lifecycle boundaries, never on the audio path.
trait TeardownOperations {
    fn stop(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32;
    fn destroy_io_proc(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32;
    fn destroy_aggregate(&mut self, aggregate: AudioObjectID) -> i32;
    fn destroy_tap(&mut self, tap: AudioObjectID) -> i32;
}

struct NativeTeardown;

impl TeardownOperations for NativeTeardown {
    fn stop(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32 {
        unsafe { AudioDeviceStop(aggregate, io_proc) }
    }
    fn destroy_io_proc(&mut self, aggregate: AudioObjectID, io_proc: AudioDeviceIOProcID) -> i32 {
        unsafe { AudioDeviceDestroyIOProcID(aggregate, io_proc) }
    }
    fn destroy_aggregate(&mut self, aggregate: AudioObjectID) -> i32 {
        unsafe { AudioHardwareDestroyAggregateDevice(aggregate) }
    }
    fn destroy_tap(&mut self, tap: AudioObjectID) -> i32 {
        unsafe { AudioHardwareDestroyProcessTap(tap) }
    }
}

/// Everything one running tap holds. Each part is released in the reverse order it
/// was made: I/O callback, aggregate device, tap.
struct CaptureState<O: TeardownOperations = NativeTeardown> {
    teardown: O,
    channel_mode: AudioTapChannelMode,
    sample_rate: u32,
    running: bool,
    releasing: bool,
    tap: Option<AudioObjectID>,
    aggregate: Option<AudioObjectID>,
    io_proc: AudioDeviceIOProcID,
    callback: *mut CallbackState,
}

// The identifiers are plain integers and `callback` is a heap block owned by this
// value alone; the I/O thread only reads it until the callback is destroyed.
unsafe impl<O: TeardownOperations + Send> Send for CaptureState<O> {}

impl CaptureState {
    fn empty() -> Self {
        Self::with_teardown(NativeTeardown)
    }
}

impl<O: TeardownOperations> CaptureState<O> {
    fn with_teardown(teardown: O) -> Self {
        Self {
            teardown,
            channel_mode: AudioTapChannelMode::Mono,
            sample_rate: 0,
            running: false,
            releasing: false,
            tap: None,
            aggregate: None,
            io_proc: None,
            callback: ptr::null_mut(),
        }
    }

    /// Release in dependency order, retaining the failed resource and everything
    /// below it. Return the first error; retry never repeats a successful native call.
    fn release(&mut self) -> Result<(), AudioCaptureError> {
        self.releasing = true;
        if let Some(aggregate) = self.aggregate {
            if self.running {
                check("AudioDeviceStop", self.teardown.stop(aggregate, self.io_proc))
                    .map_or(Ok(()), Err)?;
                self.running = false;
            }
            if self.io_proc.is_some() {
                check(
                    "AudioDeviceDestroyIOProcID",
                    self.teardown.destroy_io_proc(aggregate, self.io_proc),
                )
                .map_or(Ok(()), Err)?;
                self.io_proc = None;
            }
            check(
                "AudioHardwareDestroyAggregateDevice",
                self.teardown.destroy_aggregate(aggregate),
            )
            .map_or(Ok(()), Err)?;
            self.aggregate = None;
        }
        if !self.callback.is_null() {
            // Stop and IOProc/device destruction succeeded: no native callback can
            // still reference this block. Until then retain it, even across retries.
            drop(unsafe { Box::from_raw(self.callback) });
            self.callback = ptr::null_mut();
        }
        if let Some(tap) = self.tap {
            check("AudioHardwareDestroyProcessTap", self.teardown.destroy_tap(tap))
                .map_or(Ok(()), Err)?;
            self.tap = None;
        }
        Ok(())
    }
}

impl<O: TeardownOperations> Drop for CaptureState<O> {
    fn drop(&mut self) {
        // One bounded attempt. On persistent native failure the raw callback
        // allocation is deliberately retained: an IOProc may still reference it.
        let _ = self.release();
    }
}

/// Turns a non-zero Core Audio result code into a platform error naming the call.
fn check(operation: &str, status: i32) -> Option<AudioCaptureError> {
    if status == 0 {
        return None;
    }
    let tag = status.to_be_bytes();
    let shown = if tag.iter().all(u8::is_ascii_graphic) {
        format!("{status} / four-char code {:?}", String::from_utf8_lossy(&tag))
    } else {
        format!("{status}")
    };
    Some(AudioCaptureError::Platform(format!(
        "Core Audio call {operation} returned error status {shown}"
    )))
}

/// Owns the whole session across start/stop, including partially constructed sessions.
struct CaptureOwner<O: TeardownOperations> {
    state: Option<CaptureState<O>>,
}

impl<O: TeardownOperations> CaptureOwner<O> {
    fn start_with(
        &mut self,
        make_state: impl FnOnce() -> CaptureState<O>,
        open: impl FnOnce(&mut CaptureState<O>) -> Result<(), AudioCaptureError>,
    ) -> Result<(), AudioCaptureError> {
        // A partially stopped session is not a healthy running tap. Finish its
        // cleanup before making anything new, even if AudioDeviceStop failed.
        if self.is_running() {
            return Ok(());
        }
        self.stop()?;
        self.state = Some(make_state());
        if let Err(error) = open(self.state.as_mut().expect("state was just installed")) {
            // Preserve the setup error. Failed cleanup stays owned for stop/start
            // retries rather than being abandoned by a local CaptureState's Drop.
            let _ = self.stop();
            return Err(error);
        }
        Ok(())
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        if let Some(state) = self.state.as_mut() {
            state.release()?;
            self.state = None;
        }
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.state
            .as_ref()
            .is_some_and(|state| state.running && !state.releasing)
    }

    fn has_pending_cleanup(&self) -> bool {
        self.state.as_ref().is_some_and(|state| state.releasing)
    }
}

pub struct PlatformAudioCaptureBackend {
    capture: CaptureOwner<NativeTeardown>,
    permission_hint: bool,
}

impl PlatformAudioCaptureBackend {
    /// # Errors
    ///
    /// Never fails on macOS; the signature allows platforms without a tap to refuse.
    pub fn new() -> Result<Self, AudioCaptureError> {
        Ok(Self {
            capture: CaptureOwner { state: None },
            permission_hint: false,
        })
    }

    /// Returns the channel layout of an active, non-stopping tap, or `None`
    /// during teardown or after it completes. Unfinished teardown is reported by
    /// `has_pending_cleanup`, never as healthy capture through `is_running`.
    /// This is the measured mode, not the requested one: a host without a usable
    /// stereo tap reports [`AudioTapChannelMode::Mono`].
    #[must_use]
    pub fn tap_channel_mode(&self) -> Option<AudioTapChannelMode> {
        self.capture
            .state
            .as_ref()
            .filter(|state| state.running && !state.releasing)
            .map(|state| state.channel_mode)
    }
}

impl AudioCaptureBackend for PlatformAudioCaptureBackend {
    /// Reports a local capture-start hint, not the OS authorization status.
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(self.permission_hint)
    }

    /// Enables a recording attempt. CoreAudio performs OS authorization when
    /// tap recording starts; no permission prompt or TCC preflight runs here.
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        self.permission_hint = true;
        Ok(true)
    }

    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        self.capture
            .start_with(CaptureState::empty, |state| open_capture(state, consumer))?;
        self.permission_hint = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        self.capture.stop()
    }

    /// True only for healthy capture, not an owned session awaiting cleanup.
    fn is_running(&self) -> bool {
        self.capture.is_running()
    }

    fn has_pending_cleanup(&self) -> bool {
        self.capture.has_pending_cleanup()
    }
}

/// Builds the tap, aggregate device and I/O callback into the owner's state.
/// The owner releases completed steps on failure and retains any failed cleanup.
fn open_capture(
    state: &mut CaptureState,
    consumer: Arc<dyn AudioFrameConsumer>,
) -> Result<(), AudioCaptureError> {
    let (tap, tap_uid, stereo_requested) = create_tap()?;
    state.tap = Some(tap);

    let format = tap_format(tap)?;
    let rate = format.mSampleRate;
    if !rate.is_finite() || rate < 1.0 || rate > f64::from(u32::MAX) {
        return Err(AudioCaptureError::Platform(format!(
            "system audio tap reported an unusable sample rate: {rate}"
        )));
    }
    state.sample_rate = rate as u32;
    state.channel_mode = if stereo_requested && format.mChannelsPerFrame >= 2 {
        AudioTapChannelMode::Stereo
    } else {
        AudioTapChannelMode::Mono
    };

    let aggregate = create_aggregate(&tap_uid)?;
    state.aggregate = Some(aggregate);

    let mut scratch = Vec::with_capacity(CALLBACK_CHUNK_FRAMES * 2);
    scratch.resize(CALLBACK_CHUNK_FRAMES * 2, 0.0);
    state.callback = Box::into_raw(Box::new(CallbackState {
        consumer,
        channel_mode: state.channel_mode,
        sample_rate: state.sample_rate,
        scratch: Mutex::new(scratch),
    }));

    let mut io_proc: AudioDeviceIOProcID = None;
    let status = unsafe {
        AudioDeviceCreateIOProcID(
            aggregate,
            Some(io_callback),
            state.callback.cast::<c_void>(),
            NonNull::from(&mut io_proc),
        )
    };
    if let Some(error) = check("AudioDeviceCreateIOProcID", status) {
        return Err(error);
    }
    state.io_proc = io_proc;

    if let Some(error) = check("AudioDeviceStart", unsafe {
        AudioDeviceStart(aggregate, state.io_proc)
    }) {
        return Err(error);
    }
    state.running = true;
    log::info!(
        "[wallpaper-core audio] system audio capture started at {} Hz ({})",
        state.sample_rate,
        match state.channel_mode {
            AudioTapChannelMode::Stereo => "stereo",
            AudioTapChannelMode::Mono => "mono (no usable stereo tap)",
        }
    );
    Ok(())
}

/// The object id of this process in the audio system, when it has one.
fn own_process_object() -> Option<AudioObjectID> {
    let address = property_address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    let pid = std::process::id() as i32;
    let mut object: AudioObjectID = kAudioObjectUnknown;
    let mut size = mem::size_of::<AudioObjectID>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            SYSTEM_OBJECT,
            NonNull::from(&address),
            mem::size_of::<i32>() as u32,
            ptr::from_ref(&pid).cast(),
            NonNull::from(&mut size),
            NonNull::from(&mut object).cast(),
        )
    };
    (status == 0 && object != kAudioObjectUnknown).then_some(object)
}

fn property_address(selector: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    }
}

/// Creates the private, unmuted global tap that leaves out this process. Returns the
/// tap, its uid and whether the stereo variant was the one created.
fn create_tap() -> Result<(AudioObjectID, String, bool), AudioCaptureError> {
    let excluded: Vec<_> = own_process_object().map(NSNumber::new_u32).into_iter().collect();
    let excluded = NSArray::from_retained_slice(&excluded);

    let class = CATapDescription::class();
    let stereo_available = class
        .instance_method(sel!(initStereoGlobalTapButExcludeProcesses:))
        .is_some();

    let describe = |stereo: bool| {
        let description = CATapDescription::alloc();
        let description = unsafe {
            if stereo {
                CATapDescription::initStereoGlobalTapButExcludeProcesses(description, &excluded)
            } else {
                CATapDescription::initMonoGlobalTapButExcludeProcesses(description, &excluded)
            }
        };
        unsafe {
            description.setPrivate(true);
            description.setMuteBehavior(CATapMuteBehavior::Unmuted);
            description.setName(&NSString::from_str("Wallpaper Machine system audio"));
        }
        description
    };
    let create = |description: &CATapDescription| {
        let mut tap: AudioObjectID = kAudioObjectUnknown;
        let status = unsafe { AudioHardwareCreateProcessTap(Some(description), &mut tap) };
        (status, tap)
    };

    if stereo_available {
        let description = describe(true);
        let (status, tap) = create(&description);
        if status == 0 {
            let uid = unsafe { description.UUID().UUIDString().to_string() };
            return Ok((tap, uid, true));
        }
    }
    let description = describe(false);
    let (status, tap) = create(&description);
    if let Some(error) = check("AudioHardwareCreateProcessTap", status) {
        return Err(error);
    }
    let uid = unsafe { description.UUID().UUIDString().to_string() };
    Ok((tap, uid, false))
}

fn tap_format(tap: AudioObjectID) -> Result<AudioStreamBasicDescription, AudioCaptureError> {
    let address = property_address(kAudioTapPropertyFormat);
    let mut format = mem::MaybeUninit::<AudioStreamBasicDescription>::zeroed();
    let mut size = mem::size_of::<AudioStreamBasicDescription>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            tap,
            NonNull::from(&address),
            0,
            ptr::null(),
            NonNull::from(&mut size),
            NonNull::from(&mut format).cast(),
        )
    };
    match check("AudioObjectGetPropertyData(tap format)", status) {
        Some(error) => Err(error),
        None => Ok(unsafe { format.assume_init() }),
    }
}

fn key(name: &CStr) -> objc2::rc::Retained<NSString> {
    NSString::from_str(&name.to_string_lossy())
}

fn object<T: objc2::Message>(
    value: objc2::rc::Retained<T>,
) -> objc2::rc::Retained<AnyObject> {
    // Every Objective-C object can be handled as an `AnyObject`.
    unsafe { objc2::rc::Retained::cast_unchecked(value) }
}

/// Creates the private aggregate device that carries the tap, with drift
/// compensation at medium quality and without starting the tap on its own.
fn create_aggregate(tap_uid: &str) -> Result<AudioObjectID, AudioCaptureError> {
    let sub_tap = NSDictionary::<NSString, AnyObject>::from_retained_objects(
        &[
            &*key(kAudioSubTapUIDKey),
            &*key(kAudioSubTapDriftCompensationKey),
            &*key(kAudioSubTapDriftCompensationQualityKey),
        ],
        &[
            object(NSString::from_str(tap_uid)),
            object(NSNumber::new_bool(true)),
            object(NSNumber::new_u32(kAudioAggregateDriftCompensationMediumQuality)),
        ],
    );
    let taps = NSArray::from_retained_slice(&[sub_tap]);
    let unique = format!(
        "wallpaper-core-system-audio-{}-{}",
        std::process::id(),
        NEXT_AGGREGATE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let description = NSDictionary::<NSString, AnyObject>::from_retained_objects(
        &[
            &*key(kAudioAggregateDeviceNameKey),
            &*key(kAudioAggregateDeviceUIDKey),
            &*key(kAudioAggregateDeviceIsPrivateKey),
            &*key(kAudioAggregateDeviceTapAutoStartKey),
            &*key(kAudioAggregateDeviceTapListKey),
        ],
        &[
            object(NSString::from_str("Wallpaper Machine system audio")),
            object(NSString::from_str(&unique)),
            object(NSNumber::new_bool(true)),
            object(NSNumber::new_bool(false)),
            object(taps),
        ],
    );

    // An `NSDictionary` is toll-free bridged to `CFDictionary`.
    let bridged: &CFDictionary = unsafe { &*ptr::from_ref(&*description).cast::<CFDictionary>() };
    let mut device: AudioObjectID = kAudioObjectUnknown;
    let status = unsafe { AudioHardwareCreateAggregateDevice(bridged, NonNull::from(&mut device)) };
    match check("AudioHardwareCreateAggregateDevice", status) {
        Some(error) => Err(error),
        None => Ok(device),
    }
}

static NEXT_AGGREGATE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// The aggregate device's I/O callback. It runs on a real-time thread: it never
/// allocates, works through the device buffer in bounded chunks and always reports
/// success, even when it could not deliver.
unsafe extern "C-unwind" fn io_callback(
    _device: AudioObjectID,
    _now: NonNull<AudioTimeStamp>,
    input: NonNull<AudioBufferList>,
    _input_time: NonNull<AudioTimeStamp>,
    _output: NonNull<AudioBufferList>,
    _output_time: NonNull<AudioTimeStamp>,
    client_data: *mut c_void,
) -> i32 {
    let Some(state) = (unsafe { client_data.cast::<CallbackState>().as_ref() }) else {
        return 0;
    };
    let list = unsafe { input.as_ref() };
    // A panic in the consumer must not unwind into Core Audio's thread.
    let _ = catch_unwind(AssertUnwindSafe(|| deliver(state, list)));
    0
}

/// Hands one device buffer list to the consumer in chunks of bounded size. It gives
/// up silently when its lock is poisoned or the buffer list is malformed.
fn deliver(state: &CallbackState, list: &AudioBufferList) {
    let Ok(mut scratch) = state.scratch.lock() else {
        return;
    };
    let Some((_, frames)) = inspect(list) else {
        return;
    };

    let mut offset = 0;
    while offset < frames {
        let chunk = (frames - offset).min(CALLBACK_CHUNK_FRAMES);
        match state.channel_mode {
            AudioTapChannelMode::Stereo => {
                let out = &mut scratch[..chunk * 2];
                if list.copy_to_stereo_f32(offset, out).is_err() {
                    return;
                }
                if let Ok(frames) = InterleavedStereoF32::new(state.sample_rate, out) {
                    let _ = state.consumer.submit_audio_frames(frames);
                }
            }
            AudioTapChannelMode::Mono => {
                let out = &mut scratch[..chunk];
                if list.copy_to_mono_f32(offset, out).is_err() {
                    return;
                }
                if let Ok(frames) = MonoPcmF32::borrowed(state.sample_rate, out) {
                    let _ = state.consumer.submit_mono_audio_frames(frames);
                }
            }
        }
        offset += chunk;
    }
}

trait AudioBufferListExt {
    fn copy_to_mono_f32(&self, frame_offset: usize, mono: &mut [f32]) -> Result<(), ()>;
    fn copy_to_stereo_f32(&self, frame_offset: usize, stereo: &mut [f32]) -> Result<(), ()>;
}

/// Checks a device buffer list and returns its buffers with the frame count they
/// share. Every buffer must hold whole, aligned float32 frames and all must agree.
fn inspect(list: &AudioBufferList) -> Option<(&[AudioBuffer], usize)> {
    let count = list.mNumberBuffers as usize;
    if count == 0 {
        return None;
    }
    // The buffer array is variable-length at the ABI: `mNumberBuffers` entries follow.
    let buffers = unsafe { std::slice::from_raw_parts(list.mBuffers.as_ptr(), count) };

    let mut frames = None;
    for buffer in buffers {
        let channels = buffer.mNumberChannels as usize;
        let bytes = buffer.mDataByteSize as usize;
        let sample = mem::size_of::<f32>();
        if channels == 0
            || bytes == 0
            || buffer.mData.is_null()
            || buffer.mData.align_offset(mem::align_of::<f32>()) != 0
            || bytes % (channels * sample) != 0
        {
            return None;
        }
        let buffer_frames = bytes / (channels * sample);
        if *frames.get_or_insert(buffer_frames) != buffer_frames {
            return None;
        }
    }
    frames.map(|frames| (buffers, frames))
}

/// One sample of a buffer that `inspect` accepted.
fn sample_at(buffer: &AudioBuffer, frame: usize, channel: usize) -> f32 {
    let index = frame * buffer.mNumberChannels as usize + channel;
    unsafe { *buffer.mData.cast::<f32>().add(index) }
}

impl AudioBufferListExt for AudioBufferList {
    fn copy_to_mono_f32(&self, frame_offset: usize, mono: &mut [f32]) -> Result<(), ()> {
        let (buffers, frames) = inspect(self).ok_or(())?;
        let end = frame_offset.checked_add(mono.len()).ok_or(())?;
        if end > frames {
            return Err(());
        }

        if let [only] = buffers
            && only.mNumberChannels == 1
        {
            for (slot, frame) in mono.iter_mut().zip(frame_offset..end) {
                *slot = sample_at(only, frame, 0);
            }
            return Ok(());
        }

        let channels: usize = buffers.iter().map(|buffer| buffer.mNumberChannels as usize).sum();
        for (slot, frame) in mono.iter_mut().zip(frame_offset..end) {
            let mut sum = 0.0f32;
            for buffer in buffers {
                for channel in 0..buffer.mNumberChannels as usize {
                    sum += sample_at(buffer, frame, channel);
                }
            }
            *slot = sum / channels as f32;
        }
        Ok(())
    }

    fn copy_to_stereo_f32(&self, frame_offset: usize, stereo: &mut [f32]) -> Result<(), ()> {
        let (buffers, frames) = inspect(self).ok_or(())?;
        if stereo.is_empty() || stereo.len() % 2 != 0 {
            return Err(());
        }
        let count = stereo.len() / 2;
        let end = frame_offset.checked_add(count).ok_or(())?;
        if end > frames {
            return Err(());
        }

        if let [only] = buffers
            && only.mNumberChannels == 2
        {
            for (pair, frame) in stereo.chunks_exact_mut(2).zip(frame_offset..end) {
                pair[0] = sample_at(only, frame, 0);
                pair[1] = sample_at(only, frame, 1);
            }
            return Ok(());
        }

        // Channels are numbered across the whole list: even ones feed the left
        // side, odd ones the right.
        let total: usize = buffers.iter().map(|buffer| buffer.mNumberChannels as usize).sum();
        let left_members = total.div_ceil(2);
        let right_members = total / 2;
        if left_members == 0 {
            return Err(());
        }
        for (pair, frame) in stereo.chunks_exact_mut(2).zip(frame_offset..end) {
            let (mut left, mut right) = (0.0f32, 0.0f32);
            let mut position = 0;
            for buffer in buffers {
                for channel in 0..buffer.mNumberChannels as usize {
                    let value = sample_at(buffer, frame, channel);
                    if position % 2 == 0 {
                        left += value;
                    } else {
                        right += value;
                    }
                    position += 1;
                }
            }
            pair[0] = left / left_members as f32;
            pair[1] = if right_members == 0 {
                pair[0]
            } else {
                right / right_members as f32
            };
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "capture_lifecycle_tests.rs"]
mod lifecycle_tests;

#[cfg(test)]
mod tests {
    use super::*;

    // CoreAudio's trailing AudioBuffer array is variable-length at the ABI.
    #[repr(C)]
    struct TestBufferList<const N: usize> {
        count: u32,
        buffers: [AudioBuffer; N],
    }

    impl<const N: usize> TestBufferList<N> {
        fn new(buffers: [AudioBuffer; N]) -> Self {
            Self {
                count: u32::try_from(N).unwrap(),
                buffers,
            }
        }

        fn as_list(&self) -> &AudioBufferList {
            assert!(N > 0);
            // repr(C) preserves AudioBufferList's header, alignment and first
            // buffer, with storage for every buffer advertised by the count.
            unsafe { &*std::ptr::from_ref(self).cast::<AudioBufferList>() }
        }
    }

    fn buffer(channels: u32, samples: &mut [f32]) -> AudioBuffer {
        AudioBuffer {
            mNumberChannels: channels,
            mDataByteSize: u32::try_from(std::mem::size_of_val(samples)).unwrap(),
            mData: samples.as_mut_ptr().cast(),
        }
    }

    #[test]
    fn mixed_interleaved_buffers_preserve_frames_and_all_channels() {
        let mut first = [1.0, 0.0, 0.25, 0.75];
        let mut second = [0.5, 0.5, 1.0, 1.0];
        let buffers = TestBufferList::new([buffer(2, &mut first), buffer(2, &mut second)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(0, &mut mono).unwrap();
        assert_eq!(mono, [0.5, 0.75]);
    }

    #[test]
    fn mixed_channel_counts_weight_channels_instead_of_buffers() {
        let mut stereo = [1.0, 1.0, 0.0, 0.0];
        let mut single = [0.0, 1.0];
        let buffers = TestBufferList::new([buffer(2, &mut stereo), buffer(1, &mut single)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(0, &mut mono).unwrap();
        assert_eq!(mono, [2.0 / 3.0, 1.0 / 3.0]);
        let mut chunk = [0.0];
        buffers.as_list().copy_to_mono_f32(1, &mut chunk).unwrap();
        assert_eq!(chunk, [1.0 / 3.0]);
    }

    #[test]
    fn mono_fast_path_copies_only_requested_frame_range() {
        let mut samples = [0.25, 0.5, 0.75];
        let buffers = TestBufferList::new([buffer(1, &mut samples)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(1, &mut mono).unwrap();
        assert_eq!(mono, [0.5, 0.75]);
        assert!(buffers.as_list().copy_to_mono_f32(2, &mut mono).is_err());
    }

    #[test]
    fn short_interleaved_buffer_rejects_entire_conversion_before_output() {
        let mut first = [1.0, 0.0, 0.25, 0.75];
        let mut short = [0.5, 0.5];
        let buffers = TestBufferList::new([buffer(2, &mut first), buffer(2, &mut short)]);
        let mut mono = [-1.0; 2];
        assert!(buffers.as_list().copy_to_mono_f32(0, &mut mono).is_err());
        assert_eq!(mono, [-1.0; 2]);
    }

    #[test]
    fn malformed_buffers_are_rejected_before_reading_pcm() {
        let mut samples = [1.0; 4];
        let valid = buffer(2, &mut samples);
        let malformed = [
            AudioBuffer {
                mNumberChannels: 0,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 0,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 15,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 12,
                ..valid
            },
            AudioBuffer {
                mData: ptr::null_mut(),
                ..valid
            },
            AudioBuffer {
                mData: valid.mData.wrapping_byte_add(1),
                ..valid
            },
        ];
        for invalid in malformed {
            let buffers = TestBufferList::new([valid, invalid]);
            let mut mono = [-1.0; 2];
            assert!(buffers.as_list().copy_to_mono_f32(0, &mut mono).is_err());
            assert_eq!(mono, [-1.0; 2]);
        }
    }

    #[test]
    fn interleaved_stereo_buffer_is_copied_without_downmixing() {
        let mut samples = [1.0, -1.0, 0.25, -0.25, 0.5, -0.5];
        let buffers = TestBufferList::new([buffer(2, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(1, &mut stereo).unwrap();
        assert_eq!(stereo, [0.25, -0.25, 0.5, -0.5]);
    }

    #[test]
    fn separate_channel_buffers_keep_left_and_right_apart() {
        let mut left = [1.0, 0.5];
        let mut right = [-1.0, -0.5];
        let buffers = TestBufferList::new([buffer(1, &mut left), buffer(1, &mut right)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [1.0, -1.0, 0.5, -0.5]);
    }

    #[test]
    fn surround_channels_fold_onto_their_own_side() {
        // Four channels: L, R, Ls, Rs. Each side averages its own members and
        // never borrows from the other.
        let mut samples = [1.0, -1.0, 0.0, 0.0, 0.5, -0.5, 0.5, -0.5];
        let buffers = TestBufferList::new([buffer(4, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [0.5, -0.5, 0.5, -0.5]);
    }

    #[test]
    fn mono_source_is_duplicated_rather_than_left_silent_on_the_right() {
        let mut samples = [0.25, 0.75];
        let buffers = TestBufferList::new([buffer(1, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [0.25, 0.25, 0.75, 0.75]);
    }

    #[test]
    fn stereo_copy_rejects_out_of_range_and_odd_requests() {
        let mut samples = [1.0, -1.0, 0.25, -0.25];
        let buffers = TestBufferList::new([buffer(2, &mut samples)]);
        let mut stereo = [-2.0; 4];
        assert!(buffers.as_list().copy_to_stereo_f32(1, &mut stereo).is_err());
        assert_eq!(stereo, [-2.0; 4]);
        let mut odd = [-2.0; 3];
        assert!(buffers.as_list().copy_to_stereo_f32(0, &mut odd).is_err());
        assert_eq!(odd, [-2.0; 3]);
    }
}
