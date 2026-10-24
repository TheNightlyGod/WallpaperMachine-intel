// CPU-only ownership regressions. CoreAudio calls and allocation failures are
// injected; no audio context is opened and no disposed handle is dereferenced.
#include <gtest/gtest.h>
#include <pthread.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace sync_probe {
std::set<void*> mutexes, conditions;
std::set<pthread_t> threads;
int invalid_calls = 0;
bool refuse_thread = false;
size_t initializations = 0, refuse_initialization_at = 0;
int mutex_init(pthread_mutex_t* value, const pthread_mutexattr_t* attributes) {
    if (++initializations == refuse_initialization_at) return EAGAIN;
    if (mutexes.count(value)) { ++invalid_calls; return EINVAL; }
    int result = pthread_mutex_init(value, attributes);
    if (!result) mutexes.insert(value);
    return result;
}
int mutex_destroy(pthread_mutex_t* value) {
    if (!mutexes.erase(value)) { ++invalid_calls; return EINVAL; }
    return pthread_mutex_destroy(value);
}
int condition_init(pthread_cond_t* value, const pthread_condattr_t* attributes) {
    if (++initializations == refuse_initialization_at) return EAGAIN;
    if (conditions.count(value)) { ++invalid_calls; return EINVAL; }
    int result = pthread_cond_init(value, attributes);
    if (!result) conditions.insert(value);
    return result;
}
int condition_destroy(pthread_cond_t* value) {
    if (!conditions.erase(value)) { ++invalid_calls; return EINVAL; }
    return pthread_cond_destroy(value);
}
int thread_create(pthread_t* value, const pthread_attr_t* attributes, void* (*entry)(void*), void* argument) {
    if (refuse_thread) return EAGAIN;
    int result = pthread_create(value, attributes, entry, argument);
    if (!result) threads.insert(*value);
    return result;
}
int thread_join(pthread_t value, void** result) {
    if (!threads.erase(value)) { ++invalid_calls; return EINVAL; }
    return pthread_join(value, result);
}
}

#define pthread_mutex_init sync_probe::mutex_init
#define pthread_mutex_destroy sync_probe::mutex_destroy
#define pthread_cond_init sync_probe::condition_init
#define pthread_cond_destroy sync_probe::condition_destroy
#define pthread_create sync_probe::thread_create
#define pthread_join sync_probe::thread_join
#define MA_NO_WASAPI
#define MA_NO_DSOUND
#define MA_NO_WINMM
#define MA_NO_ENCODING
#define MA_NO_DECODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio/miniaudio.h"
#undef pthread_mutex_init
#undef pthread_mutex_destroy
#undef pthread_cond_init
#undef pthread_cond_destroy
#undef pthread_create
#undef pthread_join

namespace {
struct Allocations {
    std::mutex lock;
    std::map<void*, size_t> live;
    size_t calls = 0, fail_at = 0;
    int invalid_frees = 0;
    static void* allocate(size_t bytes, void* user) {
        auto& self = *static_cast<Allocations*>(user);
        std::lock_guard guard(self.lock);
        if (++self.calls == self.fail_at) return nullptr;
        void* memory = std::malloc(bytes ? bytes : 1);
        if (memory) self.live[memory] = bytes;
        return memory;
    }
    static void* resize(void* old, size_t bytes, void* user) {
        auto& self = *static_cast<Allocations*>(user);
        std::lock_guard guard(self.lock);
        if (++self.calls == self.fail_at) return nullptr;
        if (old && !self.live.count(old)) { ++self.invalid_frees; return nullptr; }
        void* memory = std::realloc(old, bytes ? bytes : 1);
        if (memory) { self.live.erase(old); self.live[memory] = bytes; }
        return memory;
    }
    static void release(void* memory, void* user) {
        if (!memory) return;
        auto& self = *static_cast<Allocations*>(user);
        std::lock_guard guard(self.lock);
        if (!self.live.erase(memory)) { ++self.invalid_frees; return; }
        std::free(memory);
    }
    ma_allocation_callbacks callbacks() { return {this, allocate, resize, release}; }
};

struct Device {
    ma_device value{};
    ~Device() { ma_device_uninit(&value); }
};

class MiniaudioFailures : public testing::Test {
protected:
    struct Unit {
        bool alive = true, running = false;
        int disposals = 0, starts = 0, stops = 0;
        AudioUnitPropertyListenerProc listener = nullptr;
        void* listener_user = nullptr;
    };
    inline static MiniaudioFailures* current;
    Allocations allocations;
    ma_context context{};
    std::vector<std::unique_ptr<Unit>> units;
    std::map<ma_device*, void*> backend_resources;
    std::string failure;
    int fail_unit = 0, invalid_unit_calls = 0;
    int backend_inits = 0, backend_uninits = 0;
    bool invalid_descriptor = false, backend_failure = false;
    bool notify_during_init = false;
    size_t units_added_during_init_notification = 0;
    double hardware_rate = 48000;

    void SetUp() override {
        current = this;
        context.backend = ma_backend_coreaudio;
        context.allocationCallbacks = allocations.callbacks();
        context.coreaudio.AudioObjectGetPropertyData = reinterpret_cast<ma_proc>(get_object);
        context.coreaudio.AudioObjectGetPropertyDataSize = reinterpret_cast<ma_proc>(object_size);
        context.coreaudio.AudioObjectSetPropertyData = reinterpret_cast<ma_proc>(set_object);
        context.coreaudio.AudioComponentInstanceNew = reinterpret_cast<ma_proc>(new_unit);
        context.coreaudio.AudioComponentInstanceDispose = reinterpret_cast<ma_proc>(dispose_unit);
        context.coreaudio.AudioUnitSetProperty = reinterpret_cast<ma_proc>(set_unit);
        context.coreaudio.AudioUnitGetProperty = reinterpret_cast<ma_proc>(get_unit);
        context.coreaudio.AudioUnitGetPropertyInfo = reinterpret_cast<ma_proc>(unit_info);
        context.coreaudio.AudioUnitAddPropertyListener = reinterpret_cast<ma_proc>(add_listener);
        context.coreaudio.AudioUnitInitialize = reinterpret_cast<ma_proc>(initialize_unit);
        context.coreaudio.AudioOutputUnitStart = reinterpret_cast<ma_proc>(start_unit);
        context.coreaudio.AudioOutputUnitStop = reinterpret_cast<ma_proc>(stop_unit);
        context.callbacks.onDeviceInit = core_init;
        context.callbacks.onDeviceUninit = ma_device_uninit__coreaudio;
        context.callbacks.onDeviceStart = ma_device_start__coreaudio;
        context.callbacks.onDeviceStop = ma_device_stop__coreaudio;
        context.callbacks.onDeviceGetInfo = device_info;
        ASSERT_EQ(ma_mutex_init(&g_DeviceTrackingMutex_CoreAudio), MA_SUCCESS);
        ASSERT_EQ(g_TrackedDeviceCount_CoreAudio, 0u);
    }
    void TearDown() override {
        EXPECT_EQ(g_TrackedDeviceCount_CoreAudio, 0u);
        EXPECT_EQ(g_ppTrackedDevices_CoreAudio, nullptr);
        EXPECT_EQ(invalid_unit_calls, 0);
        EXPECT_EQ(allocations.invalid_frees, 0);
        EXPECT_TRUE(allocations.live.empty());
        EXPECT_TRUE(backend_resources.empty());
        for (const auto& unit : units) {
            EXPECT_FALSE(unit->alive);
            EXPECT_EQ(unit->disposals, 1);
        }
        ma_mutex_uninit(&g_DeviceTrackingMutex_CoreAudio);
        EXPECT_TRUE(sync_probe::mutexes.empty());
        EXPECT_TRUE(sync_probe::conditions.empty());
        EXPECT_TRUE(sync_probe::threads.empty());
        EXPECT_EQ(sync_probe::invalid_calls, 0);
        sync_probe::refuse_thread = false;
        sync_probe::refuse_initialization_at = 0;
    }
    ma_device_config config(ma_device_type type = ma_device_type_playback) {
        auto value = ma_device_config_init(type);
        value.playback.format = value.capture.format = ma_format_f32;
        value.playback.channels = value.capture.channels = 2;
        value.sampleRate = 48000;
        value.periodSizeInFrames = 128;
        return value;
    }
    void custom_backend(bool synchronous = false) {
        context.backend = ma_backend_custom;
        context.callbacks.onDeviceInit = backend_init;
        context.callbacks.onDeviceUninit = backend_uninit;
        context.callbacks.onDeviceStart = nullptr;
        context.callbacks.onDeviceStop = nullptr;
        context.callbacks.onDeviceDataLoop = synchronous ? backend_loop : nullptr;
    }
    bool fail(const char* operation, Unit* unit = nullptr) {
        if (failure != operation) return false;
        return !fail_unit || (unit && units.size() >= size_t(fail_unit) && units[fail_unit - 1].get() == unit);
    }
    Unit* live_unit(AudioUnit handle) {
        for (auto& unit : units) if (reinterpret_cast<AudioUnit>(unit.get()) == handle) {
            if (unit->alive) return unit.get();
            break;
        }
        ++invalid_unit_calls;
        return nullptr;
    }
    static AudioStreamBasicDescription format() {
        return {current->hardware_rate, kAudioFormatLinearPCM,
                kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                8, 1, 8, 2, 32, 0};
    }
    static OSStatus get_object(AudioObjectID, const AudioObjectPropertyAddress* address, UInt32, const void*, UInt32*, void* output) {
        switch (address->mSelector) {
        case kAudioHardwarePropertyDefaultOutputDevice:
        case kAudioHardwarePropertyDefaultInputDevice:
            if (current->fail("lookup")) return kAudioHardwareBadDeviceError;
            *static_cast<AudioObjectID*>(output) = 7;
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: {
            if (current->fail("formats")) return kAudioHardwareBadDeviceError;
            auto* description = static_cast<AudioStreamRangedDescription*>(output);
            description->mFormat = format();
            description->mSampleRateRange = {current->hardware_rate, current->hardware_rate};
            return noErr;
        }
        case kAudioDevicePropertyBufferFrameSizeRange:
            if (current->fail("buffer-range")) return kAudioHardwareBadDeviceError;
            *static_cast<AudioValueRange*>(output) = {32, 4096};
            return noErr;
        case kAudioDevicePropertyBufferFrameSize:
            if (current->fail("buffer-size")) return kAudioHardwareBadDeviceError;
            *static_cast<UInt32*>(output) = 128;
            return noErr;
        default: return kAudioHardwareUnknownPropertyError; // UID/name are deliberately unavailable.
        }
    }
    static OSStatus object_size(AudioObjectID, const AudioObjectPropertyAddress* address, UInt32, const void*, UInt32* size) {
        if (address->mSelector != kAudioStreamPropertyAvailableVirtualFormats) return kAudioHardwareUnknownPropertyError;
        *size = sizeof(AudioStreamRangedDescription);
        return noErr;
    }
    static OSStatus set_object(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*) { return noErr; }
    static OSStatus new_unit(AudioComponent, AudioComponentInstance* output) {
        if (current->fail("new")) return kAudioHardwareBadDeviceError;
        current->units.push_back(std::make_unique<Unit>());
        *output = reinterpret_cast<AudioComponentInstance>(current->units.back().get());
        return noErr;
    }
    static OSStatus dispose_unit(AudioComponentInstance handle) {
        auto* unit = current->live_unit(handle);
        if (!unit) return kAudioHardwareBadDeviceError;
        unit->running = false;
        unit->alive = false;
        ++unit->disposals;
        return noErr;
    }
    static OSStatus set_unit(AudioUnit handle, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement, const void*, UInt32) {
        auto* unit = current->live_unit(handle);
        if (!unit) return kAudioHardwareBadDeviceError;
        const char* operation = "set";
        if (property == kAudioOutputUnitProperty_CurrentDevice) operation = "current-device";
        if (property == kAudioOutputUnitProperty_EnableIO) operation = scope == kAudioUnitScope_Input ? "input-io" : "output-io";
        if (property == kAudioUnitProperty_MaximumFramesPerSlice) operation = "max-frames";
        if (property == kAudioUnitProperty_SetRenderCallback || property == kAudioOutputUnitProperty_SetInputCallback) operation = "callback";
        return current->fail(operation, unit) ? OSStatus(kAudioHardwareBadDeviceError) : OSStatus(noErr);
    }
    static OSStatus get_unit(AudioUnit handle, AudioUnitPropertyID property, AudioUnitScope, AudioUnitElement, void* output, UInt32*) {
        auto* unit = current->live_unit(handle);
        if (!unit) return kAudioHardwareBadDeviceError;
        if (property == kAudioUnitProperty_StreamFormat) {
            if (current->fail("format-read", unit)) return kAudioHardwareBadDeviceError;
            *static_cast<AudioStreamBasicDescription*>(output) = format();
        } else if (property == kAudioOutputUnitProperty_IsRunning) {
            *static_cast<UInt32*>(output) = unit->running;
        } else return kAudioUnitErr_InvalidProperty;
        return noErr;
    }
    static OSStatus unit_info(AudioUnit handle, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32*, Boolean*) {
        return current->live_unit(handle) ? OSStatus(kAudioUnitErr_InvalidProperty) : OSStatus(kAudioHardwareBadDeviceError);
    }
    static OSStatus add_listener(AudioUnit handle, AudioUnitPropertyID, AudioUnitPropertyListenerProc listener, void* user) {
        auto* unit = current->live_unit(handle);
        if (!unit || current->fail("listener", unit)) return kAudioHardwareBadDeviceError;
        unit->listener = listener;
        unit->listener_user = user;
        return noErr;
    }
    static OSStatus initialize_unit(AudioUnit handle) {
        auto* unit = current->live_unit(handle);
        return !unit || current->fail("initialize", unit) ? OSStatus(kAudioHardwareBadDeviceError) : OSStatus(noErr);
    }
    static OSStatus start_unit(AudioUnit handle) {
        auto* unit = current->live_unit(handle);
        if (!unit || current->fail("start", unit)) return kAudioHardwareBadDeviceError;
        unit->running = true;
        ++unit->starts;
        return noErr;
    }
    static OSStatus stop_unit(AudioUnit handle) {
        auto* unit = current->live_unit(handle);
        if (!unit) return kAudioHardwareBadDeviceError;
        unit->running = false;
        ++unit->stops;
        if (unit->listener) unit->listener(unit->listener_user, handle, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0);
        return noErr;
    }
    static ma_result device_info(ma_device*, ma_device_type, ma_device_info* info) {
        std::memset(info, 0, sizeof(*info));
        std::strcpy(info->name, "isolated backend");
        return MA_SUCCESS;
    }
    static ma_result core_init(ma_device* device, const ma_device_config* settings, ma_device_descriptor* playback, ma_device_descriptor* capture) {
        ma_result result = ma_device_init__coreaudio(device, settings, playback, capture);
        if (result == MA_SUCCESS && current->notify_during_init) {
            size_t before = current->units.size();
            AudioObjectPropertyAddress changed{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0};
            ma_default_device_changed__coreaudio(0, 1, &changed, nullptr);
            current->units_added_during_init_notification = current->units.size() - before;
        }
        return result;
    }
    static ma_result backend_init(ma_device* device, const ma_device_config*, ma_device_descriptor* playback, ma_device_descriptor* capture) {
        ++current->backend_inits;
        if (current->backend_failure) return MA_ERROR;
        void* resource = Allocations::allocate(32, &current->allocations);
        if (!resource) return MA_OUT_OF_MEMORY;
        current->backend_resources[device] = resource;
        for (auto* descriptor : {playback, capture}) {
            descriptor->format = ma_format_f32;
            descriptor->channels = 2;
            descriptor->sampleRate = current->invalid_descriptor ? 0 : 44100;
            descriptor->periodSizeInFrames = 128;
            descriptor->periodCount = 2;
        }
        return MA_SUCCESS;
    }
    static ma_result backend_uninit(ma_device* device) {
        ++current->backend_uninits;
        auto found = current->backend_resources.find(device);
        if (found == current->backend_resources.end()) return MA_INVALID_OPERATION;
        Allocations::release(found->second, &current->allocations);
        current->backend_resources.erase(found);
        return MA_SUCCESS;
    }
    static ma_result backend_loop(ma_device*) { return MA_SUCCESS; }
};

TEST_F(MiniaudioFailures, CurrentDeviceErrorIsNotSuccessAndOwnershipIsCleared) {
    failure = "current-device";
    ma_device_init_internal_data__coreaudio data{};
    data.formatIn = ma_format_f32; data.channelsIn = 2; data.sampleRateIn = 48000;
    EXPECT_NE(ma_device_init_internal__coreaudio(&context, ma_device_type_playback, nullptr, &data, nullptr), MA_SUCCESS);
    EXPECT_EQ(data.audioUnit, nullptr);
    EXPECT_EQ(data.pAudioBufferList, nullptr);
    ASSERT_EQ(units.size(), 1u);
    EXPECT_EQ(units[0]->disposals, 1);
}

TEST_F(MiniaudioFailures, EveryCoreAudioSetupFailureRollsBackOwnedUnitsAndBuffers) {
    for (auto operation : {"new", "output-io", "input-io", "current-device", "format-read", "formats",
                           "buffer-range", "buffer-size", "max-frames", "callback", "listener", "initialize"}) {
        SCOPED_TRACE(operation);
        failure = operation;
        auto settings = config(ma_device_type_capture);
        Device device;
        EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_uninitialized);
        EXPECT_TRUE(allocations.live.empty());
        EXPECT_EQ(g_TrackedDeviceCount_CoreAudio, 0u);
        EXPECT_EQ(sync_probe::mutexes.size(), 1u); // only this fixture's tracking mutex
        EXPECT_TRUE(sync_probe::conditions.empty());
    }
}

TEST_F(MiniaudioFailures, DuplexPlaybackFailureUntracksAndReleasesEarlierCapture) {
    failure = "current-device";
    fail_unit = 2;
    auto settings = config(ma_device_type_duplex);
    Device device;
    EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    EXPECT_EQ(g_TrackedDeviceCount_CoreAudio, 0u);
    EXPECT_TRUE(allocations.live.empty());
    ASSERT_EQ(units.size(), 2u);
    EXPECT_EQ(units[0]->disposals, 1);
    EXPECT_EQ(units[1]->disposals, 1);
}

TEST_F(MiniaudioFailures, DefaultDeviceNotificationCannotRerouteAnUnpublishedDevice) {
    notify_during_init = true;
    auto settings = config();
    Device device;
    ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    EXPECT_EQ(units_added_during_init_notification, 0u);
    EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_stopped);
    EXPECT_EQ(g_TrackedDeviceCount_CoreAudio, 1u);
}

TEST_F(MiniaudioFailures, FailedRoutePreservesLiveOwnershipAndNextNotificationRecovers) {
    auto settings = config();
    Device device;
    ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    ASSERT_EQ(ma_device_start(&device.value), MA_SUCCESS);
    Unit* original = units[0].get();
    auto original_unit = device.value.coreaudio.audioUnitPlayback;
    auto original_heap = device.value.playback.converter._pHeap;
    AudioObjectPropertyAddress changed{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0};
    for (auto operation : {"lookup", "current-device", "initialize"}) {
        SCOPED_TRACE(operation);
        failure = operation;
        ma_default_device_changed__coreaudio(0, 1, &changed, nullptr);
        EXPECT_EQ(device.value.coreaudio.audioUnitPlayback, original_unit);
        EXPECT_EQ(device.value.playback.converter._pHeap, original_heap);
        EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_started);
        EXPECT_TRUE(original->alive);
        EXPECT_TRUE(original->running);
        EXPECT_EQ(original->stops, 0);
    }
    failure.clear();
    hardware_rate = 44100;
    ma_default_device_changed__coreaudio(0, 1, &changed, nullptr);
    EXPECT_FALSE(original->alive);
    EXPECT_EQ(original->disposals, 1);
    EXPECT_NE(device.value.coreaudio.audioUnitPlayback, original_unit);
    EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_started);
    EXPECT_TRUE(units.back()->running);
    auto& converter = device.value.playback.converter;
    ASSERT_TRUE(converter.hasResampler);
    EXPECT_EQ(converter.resampler.pBackend, &converter.resampler.state.linear);
    EXPECT_EQ(converter.resampler.pBackendUserData, &converter.resampler);
    float input[256]{}, output[256]{};
    ma_uint64 in_frames = 128, out_frames = 128;
    EXPECT_EQ(ma_data_converter_process_pcm_frames(&converter, input, &in_frames, output, &out_frames), MA_SUCCESS);
    EXPECT_GT(out_frames, 0u);
    EXPECT_EQ(ma_device_stop(&device.value), MA_SUCCESS);
}

TEST_F(MiniaudioFailures, AllocationFailureDuringRoutePreparationLeavesOldRouteAndCanRetry) {
    auto settings = config(ma_device_type_duplex);
    Device device;
    ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    ASSERT_EQ(ma_device_start(&device.value), MA_SUCCESS);
    auto old_unit = device.value.coreaudio.audioUnitPlayback;
    auto old_heap = device.value.playback.converter._pHeap;
    auto old_cache = device.value.playback.pInputCache;
    size_t live_before = allocations.live.size();
    hardware_rate = 44100;
    // Failure points cover description allocation, converter heap, then duplex input cache.
    for (size_t point = 1; point <= 3; ++point) {
        SCOPED_TRACE(point);
        allocations.fail_at = allocations.calls + point;
        EXPECT_NE(ma_device_reinit_internal__coreaudio(&device.value, ma_device_type_playback, MA_TRUE), MA_SUCCESS);
        EXPECT_EQ(device.value.coreaudio.audioUnitPlayback, old_unit);
        EXPECT_EQ(device.value.playback.converter._pHeap, old_heap);
        EXPECT_EQ(device.value.playback.pInputCache, old_cache);
        EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_started);
        EXPECT_EQ(allocations.live.size(), live_before);
        allocations.fail_at = 0;
    }
    EXPECT_EQ(ma_device_reinit_internal__coreaudio(&device.value, ma_device_type_playback, MA_TRUE), MA_SUCCESS);
    EXPECT_NE(device.value.coreaudio.audioUnitPlayback, old_unit);
}

TEST_F(MiniaudioFailures, InvalidPostInitDescriptorReleasesBackendAndAllSynchronizationOnce) {
    custom_backend();
    invalid_descriptor = true;
    auto settings = config();
    Device device;
    EXPECT_EQ(ma_device_init(&context, &settings, &device.value), MA_INVALID_ARGS);
    EXPECT_EQ(backend_inits, 1);
    EXPECT_EQ(backend_uninits, 1);
    ma_device_uninit(&device.value);
    EXPECT_EQ(backend_uninits, 1);
    EXPECT_TRUE(allocations.live.empty());
    EXPECT_EQ(sync_probe::mutexes.size(), 1u);
    EXPECT_TRUE(sync_probe::conditions.empty());
}

TEST_F(MiniaudioFailures, EveryLateAllocationFailureCleansUpAndAllowsTheSameDeviceToInitializeAgain) {
    custom_backend();
    auto settings = config(ma_device_type_duplex);
    size_t allocation_count;
    {
        Device device;
        ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        allocation_count = allocations.calls;
    }
    ASSERT_GE(allocation_count, 6u);
    RecordProperty("allocation_failure_points", int(allocation_count));
    for (size_t point = 1; point <= allocation_count; ++point) {
        SCOPED_TRACE(point);
        Device device;
        int uninit_before = backend_uninits;
        allocations.fail_at = allocations.calls + point;
        EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_uninitialized);
        EXPECT_EQ(backend_uninits - uninit_before, point == 1 ? 0 : 1);
        EXPECT_TRUE(allocations.live.empty());
        EXPECT_EQ(sync_probe::mutexes.size(), 1u);
        EXPECT_TRUE(sync_probe::conditions.empty());
        ma_device_uninit(&device.value);
        EXPECT_EQ(backend_uninits - uninit_before, point == 1 ? 0 : 1);
        allocations.fail_at = 0;
        EXPECT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    }
}

TEST_F(MiniaudioFailures, CoreAudioAllocationFailuresRemoveDefaultDeviceTrackingAndAllOwnedResources) {
    hardware_rate = 44100;
    auto settings = config(ma_device_type_duplex);
    size_t allocation_count;
    {
        Device device;
        size_t before = allocations.calls;
        ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        allocation_count = allocations.calls - before;
    }
    RecordProperty("allocation_failure_points", int(allocation_count));
    for (size_t point = 1; point <= allocation_count; ++point) {
        SCOPED_TRACE(point);
        Device device;
        allocations.fail_at = allocations.calls + point;
        EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_uninitialized);
        EXPECT_EQ(g_TrackedDeviceCount_CoreAudio, 0u);
        EXPECT_TRUE(allocations.live.empty());
        EXPECT_EQ(sync_probe::mutexes.size(), 1u);
        EXPECT_TRUE(sync_probe::conditions.empty());
        allocations.fail_at = 0;
    }
}

TEST_F(MiniaudioFailures, CaptureRoutePreparationFailurePreservesItsBufferAndLaterRecovers) {
    auto settings = config(ma_device_type_capture);
    Device device;
    ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    ASSERT_EQ(ma_device_start(&device.value), MA_SUCCESS);
    auto old_unit = device.value.coreaudio.audioUnitCapture;
    auto old_buffer = device.value.coreaudio.pAudioBufferList;
    auto old_converter = device.value.capture.converter._pHeap;
    size_t old_allocations = allocations.live.size();
    hardware_rate = 44100;
    for (size_t point = 1; point <= 3; ++point) {
        SCOPED_TRACE(point);
        allocations.fail_at = allocations.calls + point;
        EXPECT_NE(ma_device_reinit_internal__coreaudio(&device.value, ma_device_type_capture, MA_TRUE), MA_SUCCESS);
        EXPECT_EQ(device.value.coreaudio.audioUnitCapture, old_unit);
        EXPECT_EQ(device.value.coreaudio.pAudioBufferList, old_buffer);
        EXPECT_EQ(device.value.capture.converter._pHeap, old_converter);
        EXPECT_EQ(allocations.live.size(), old_allocations);
        allocations.fail_at = 0;
    }
    AudioObjectPropertyAddress changed{kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, 0};
    ma_default_device_changed__coreaudio(0, 1, &changed, nullptr);
    EXPECT_NE(device.value.coreaudio.audioUnitCapture, old_unit);
    EXPECT_NE(device.value.coreaudio.pAudioBufferList, old_buffer);
    EXPECT_TRUE(units.back()->running);
    EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_started);
    EXPECT_EQ(ma_device_stop(&device.value), MA_SUCCESS);
}

TEST_F(MiniaudioFailures, ReplacementStartFailureLeavesAStoppedOwnedUnitThatCanStartLater) {
    auto settings = config();
    Device device;
    ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    ASSERT_EQ(ma_device_start(&device.value), MA_SUCCESS);
    failure = "start";
    AudioObjectPropertyAddress changed{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0};
    ma_default_device_changed__coreaudio(0, 1, &changed, nullptr);
    EXPECT_EQ(ma_device_get_state(&device.value), ma_device_state_stopped);
    EXPECT_TRUE(units.back()->alive);
    EXPECT_FALSE(units.back()->running);
    failure.clear();
    EXPECT_EQ(ma_device_start(&device.value), MA_SUCCESS);
    EXPECT_TRUE(units.back()->running);
    EXPECT_EQ(ma_device_stop(&device.value), MA_SUCCESS);
}

TEST_F(MiniaudioFailures, SynchronizationFailureRollsBackOnlyTheStagesThatWereInitialized) {
    custom_backend();
    auto settings = config();
    size_t initialization_count;
    {
        Device device;
        size_t before = sync_probe::initializations;
        ASSERT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        initialization_count = sync_probe::initializations - before;
    }
    RecordProperty("synchronization_failure_points", int(initialization_count));
    for (size_t point = 1; point <= initialization_count; ++point) {
        SCOPED_TRACE(point);
        Device device;
        sync_probe::refuse_initialization_at = sync_probe::initializations + point;
        EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
        EXPECT_EQ(sync_probe::mutexes.size(), 1u);
        EXPECT_TRUE(sync_probe::conditions.empty());
        EXPECT_EQ(sync_probe::invalid_calls, 0);
        EXPECT_TRUE(allocations.live.empty());
        sync_probe::refuse_initialization_at = 0;
    }
}

TEST_F(MiniaudioFailures, BackendFailureAlsoReleasesTheGenericStopEvent) {
    custom_backend();
    backend_failure = true;
    auto settings = config();
    Device device;
    EXPECT_EQ(ma_device_init(&context, &settings, &device.value), MA_ERROR);
    EXPECT_EQ(backend_uninits, 0);
    EXPECT_EQ(sync_probe::mutexes.size(), 1u);
    EXPECT_TRUE(sync_probe::conditions.empty());
}

TEST_F(MiniaudioFailures, WorkerCreationFailureRollsBackWithoutJoiningANonexistentThread) {
    custom_backend(true);
    auto settings = config();
    Device device;
    sync_probe::refuse_thread = true;
    EXPECT_NE(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
    EXPECT_EQ(backend_uninits, 1);
    EXPECT_TRUE(allocations.live.empty());
    EXPECT_EQ(sync_probe::invalid_calls, 0);
    EXPECT_TRUE(sync_probe::threads.empty());
    sync_probe::refuse_thread = false;
    EXPECT_EQ(ma_device_init(&context, &settings, &device.value), MA_SUCCESS);
}
}
