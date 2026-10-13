#import <AppKit/AppKit.h>

struct mpv_handle;
NS_ASSUME_NONNULL_BEGIN

/// Copied under the renderer lock. drawCount includes clears/redraws; videoFrameCount
/// counts only new media frames. skippedFrameCount counts skip-render calls.
typedef struct {
    BOOL contextAlive;
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
