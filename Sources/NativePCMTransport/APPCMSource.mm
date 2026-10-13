#import "APPCMSource.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>
#include <memory>
#include <new>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreAudio/HostTime.h>
#endif

namespace {
// Callback cost is a host-probe diagnostic. The iOS SDK does not expose this annotated
// CoreAudio host-clock API; keep its native render timestamps, without inventing a clock
// annotation or disabling the realtime checks to collect extra diagnostic timestamps.
uint64_t diagnosticHostTime() noexcept CA_REALTIME_API {
#if TARGET_OS_OSX
    return AudioGetCurrentHostTime();
#else
    return 0;
#endif
}
// Exactly one control producer and one audio consumer. Release/acquire publication
// protects the non-atomic sample slots in both directions; neither overwrites a live slot.
// Storage and shared ownership are allocated before the node enters the render graph.
struct Ring {
    const uint32_t channels;
    const uint32_t capacity;
    std::unique_ptr<float[]> samples;
    alignas(64) std::atomic<uint64_t> written{0};
    alignas(64) std::atomic<uint64_t> consumed{0};
    std::atomic<uint64_t> underrun{0};
    static constexpr uint32_t eventCapacity = 1024;
    std::array<APPCMRenderEvent, eventCapacity> events;
    alignas(64) std::atomic<uint64_t> eventsWritten{0};
    alignas(64) std::atomic<uint64_t> eventsRead{0};
    std::atomic<uint64_t> eventsDropped{0};

    Ring(uint32_t channels, uint32_t capacity)
        : channels(channels), capacity(capacity), samples(new float[size_t(channels) * capacity]) {}

    bool enqueue(const int16_t *input, uint32_t frames) {
        const auto write = written.load(std::memory_order_relaxed);
        const auto read = consumed.load(std::memory_order_acquire);
        if (!input || !frames || frames > capacity || write - read > capacity - frames
            || write > std::numeric_limits<uint64_t>::max() - frames) { return false; }
        for (uint32_t frame = 0; frame < frames; ++frame) {
            const size_t slot = size_t((write + frame) % capacity) * channels;
            for (uint32_t channel = 0; channel < channels; ++channel) {
                samples[slot + channel] = float(input[size_t(frame) * channels + channel]) / 32768.0f;
            }
        }
        written.store(write + frames, std::memory_order_release);
        return true;
    }

    OSStatus render(BOOL *silence, const AudioTimeStamp *timestamp, uint32_t frames,
                    AudioBufferList *output) noexcept CA_REALTIME_API {
        const uint64_t started = diagnosticHostTime();
        if (output->mNumberBuffers != channels) { return kAudio_ParamError; }
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const auto &buffer = output->mBuffers[channel];
            if (!buffer.mData || buffer.mNumberChannels != 1
                || uint64_t(buffer.mDataByteSize) < uint64_t(frames) * sizeof(float)) {
                return kAudio_ParamError;
            }
        }
        const auto read = consumed.load(std::memory_order_relaxed);
        const auto write = written.load(std::memory_order_acquire);
        const auto count = uint32_t(std::min<uint64_t>(frames, write - read));
        for (uint32_t channel = 0; channel < channels; ++channel) {
            auto *destination = static_cast<float *>(output->mBuffers[channel].mData);
            for (uint32_t frame = 0; frame < count; ++frame) {
                destination[frame] = samples[size_t((read + frame) % capacity) * channels + channel];
            }
            for (uint32_t frame = count; frame < frames; ++frame) { destination[frame] = 0; }
        }
        *silence = count == 0;
        consumed.store(read + count, std::memory_order_release);
        // Underrun produces required hardware silence without advancing the media frame clock.
        if (count < frames) { underrun.fetch_add(frames - count, std::memory_order_relaxed); }
        const auto eventWrite = eventsWritten.load(std::memory_order_relaxed);
        const auto eventRead = eventsRead.load(std::memory_order_acquire);
        if (eventWrite - eventRead < eventCapacity) {
            events[eventWrite % eventCapacity] = {
                read, timestamp->mHostTime, timestamp->mSampleTime, started, diagnosticHostTime(),
                frames, count, timestamp->mFlags
            };
            eventsWritten.store(eventWrite + 1, std::memory_order_release);
        } else { eventsDropped.fetch_add(1, std::memory_order_relaxed); }
        return noErr;
    }

    uint32_t copyEvents(APPCMRenderEvent *destination, uint32_t capacity) {
        if (!destination || !capacity) { return 0; }
        const auto read = eventsRead.load(std::memory_order_relaxed);
        const auto write = eventsWritten.load(std::memory_order_acquire);
        const auto count = uint32_t(std::min<uint64_t>(capacity, write - read));
        for (uint32_t i = 0; i < count; ++i) { destination[i] = events[(read + i) % eventCapacity]; }
        eventsRead.store(read + count, std::memory_order_release);
        return count;
    }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio counters must be lock-free");
}

@implementation APPCMSource {
    std::shared_ptr<Ring> _ring;
    AVAudioSourceNode *_node;
}

- (instancetype)initWithSampleRate:(double)sampleRate channels:(uint32_t)channels
                    capacityFrames:(uint32_t)capacityFrames {
    if (!std::isfinite(sampleRate) || sampleRate < 1 || sampleRate > 768000
        || channels < 1 || channels > 32 || capacityFrames < 1 || capacityFrames > 65536 * 64) {
        return nil;
    }
    self = [super init];
    if (self) {
        try { _ring = std::make_shared<Ring>(channels, capacityFrames); }
        catch (const std::bad_alloc &) { return nil; }
        const AudioChannelLayoutTag tag = channels == 1 ? kAudioChannelLayoutTag_Mono
            : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | channels;
        AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:tag];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channelLayout:layout];
        const auto ring = _ring;
        _node = [[AVAudioSourceNode alloc] initWithFormat:format realtimeSafeRenderBlock:
            ^OSStatus(BOOL *silence, const AudioTimeStamp *timestamp, AVAudioFrameCount frames,
                      AudioBufferList *output) CA_REALTIME_API {
                return ring->render(silence, timestamp, frames, output);
            }];
    }
    return self;
}

- (AVAudioSourceNode *)node { return _node; }
- (uint64_t)writtenFrames { return _ring->written.load(std::memory_order_acquire); }
- (uint64_t)consumedFrames { return _ring->consumed.load(std::memory_order_acquire); }
- (uint64_t)underrunFrames { return _ring->underrun.load(std::memory_order_acquire); }
- (uint64_t)droppedRenderEvents { return _ring->eventsDropped.load(std::memory_order_acquire); }
- (uint32_t)copyRenderEvents:(APPCMRenderEvent *)events capacity:(uint32_t)capacity {
    return _ring->copyEvents(events, capacity);
}
- (BOOL)enqueuePCM16:(const int16_t *)samples frameCount:(uint32_t)frames { return _ring->enqueue(samples, frames); }
@end
