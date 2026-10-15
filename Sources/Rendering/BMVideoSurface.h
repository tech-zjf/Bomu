#import <AppKit/AppKit.h>
#import <stdint.h>

struct mpv_handle;
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BMGPURenderTimingStatus) {
    BMGPURenderTimingStatusDisabled,
    BMGPURenderTimingStatusExtensionUnavailable,
    BMGPURenderTimingStatusCounterUnavailable,
    BMGPURenderTimingStatusQueryAllocationFailed,
    BMGPURenderTimingStatusSupported
};

typedef NS_ENUM(NSInteger, BMGPURenderTimingMode) {
    BMGPURenderTimingModeDisabled,
    BMGPURenderTimingModeTimestamp,
    BMGPURenderTimingModeElapsed
};

/// Copied under the renderer lock. contextAlive reports libmpv's render context;
/// graphicsContextAlive reports Bomu's owned CGL context. drawCount includes clears/redraws;
/// videoFrameCount counts only new media frames. skippedFrameCount counts skip-render calls.
typedef struct {
    BOOL contextAlive;
    BOOL graphicsContextAlive;
    uint64_t contextCreationCount;
    uint64_t drawCount;
    uint64_t videoFrameCount;
    uint64_t skippedFrameCount;
    uint64_t blankDrawCount;
    BOOL lastDrawWasClearOnly;
    double firstVideoFrameUptime;
    uint64_t timedFrameCount;
    uint64_t earlySubmissionCount;
    int64_t submissionErrorTotalUS;
    int64_t submissionErrorMinimumUS;
    int64_t submissionErrorMaximumUS;
    BMGPURenderTimingStatus gpuRenderTimingStatus;
    BMGPURenderTimingMode gpuRenderTimingMode;
    uint64_t gpuRenderTimingSampleCount;
    uint64_t gpuRenderIntervalNanoseconds;
    uint64_t gpuRenderPendingQueryCount;
    uint64_t gpuRenderDroppedSampleCount;
} BMRenderStatistics;

/// Adapter-internal view. The C handle never crosses into Swift or feature code.
@interface BMVideoSurface : NSView
- (void)attachCore:(struct mpv_handle *)core completion:(void (^)(NSError * _Nullable))completion;
/// Main-thread boundary; the render queue owns the applied presentation state.
- (void)setVideoOutputConfigured:(BOOL)configured;
- (void)shutdownWithCompletion:(void (^)(void))completion;
- (void)collectStatistics:(void (^)(BMRenderStatistics))completion;
@end

NS_ASSUME_NONNULL_END
