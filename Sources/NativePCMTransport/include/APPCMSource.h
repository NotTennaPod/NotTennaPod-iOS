#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// One render request, captured without allocation. Times are native host-clock ticks;
/// timestampFlags determines whether the node's host/sample timestamp is valid. Callback
/// start/end cost timestamps are collected on macOS only and are zero on other platforms.
typedef struct {
    uint64_t sourceStartFrame;
    uint64_t hostTime;
    double sampleTime;
    uint64_t callbackStartHostTime;
    uint64_t callbackEndHostTime;
    uint32_t requestedFrames;
    uint32_t mediaFrames;
    uint32_t timestampFlags;
} APPCMRenderEvent;

/// Control methods have one serialized producer. Only the source node consumes PCM.
/// A new instance owns a new render generation; never reset memory under a live callback.
@interface APPCMSource : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithSampleRate:(double)sampleRate
                                  channels:(uint32_t)channels
                            capacityFrames:(uint32_t)capacityFrames NS_DESIGNATED_INITIALIZER;
@property(nonatomic, readonly) AVAudioSourceNode *node;
@property(nonatomic, readonly) uint64_t writtenFrames;
@property(nonatomic, readonly) uint64_t consumedFrames;
@property(nonatomic, readonly) uint64_t underrunFrames;
@property(nonatomic, readonly) uint64_t droppedRenderEvents;
/// One serialized control consumer drains the bounded 1024-event observation queue.
/// Overflow is explicit; missing history must not be treated as presentation evidence.
- (uint32_t)copyRenderEvents:(APPCMRenderEvent *)events capacity:(uint32_t)capacity
    NS_SWIFT_NAME(copyRenderEvents(_:capacity:));
/// Copies a complete packet or rejects it without changing the buffer or counters.
- (BOOL)enqueuePCM16:(const int16_t *)samples frameCount:(uint32_t)frames
    NS_SWIFT_NAME(enqueue(_:frames:));
@end

NS_ASSUME_NONNULL_END
