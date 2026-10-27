#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BMPlaybackUpdateKind) {
    BMPlaybackUpdateLoaded,
    BMPlaybackUpdateSnapshot,
    BMPlaybackUpdateEnded,
    BMPlaybackUpdateFailed,
    BMPlaybackUpdateCommandFailed
};

typedef NS_ENUM(NSInteger, BMPlaybackFailureKind) {
    BMPlaybackFailureUnavailable,
    BMPlaybackFailurePermissionDenied,
    BMPlaybackFailureUnsupportedOrDamaged,
    BMPlaybackFailureEngine
};

typedef NS_ENUM(NSInteger, BMPlaybackCommandFailureKind) {
    BMPlaybackCommandFailureAudioTrack,
    BMPlaybackCommandFailureSubtitle
};

@interface BMPlaybackTrack : NSObject
@property(nonatomic, readonly) int64_t trackID;
@property(nonatomic, copy, readonly) NSString *trackType;
@property(nonatomic, copy, readonly, nullable) NSString *language;
@property(nonatomic, copy, readonly, nullable) NSString *title;
@property(nonatomic, readonly) BOOL selected;
@property(nonatomic, readonly) BOOL external;
@end

/// Immutable data copied from libmpv on its control queue, delivered on the main queue.
@interface BMPlaybackUpdate : NSObject
@property(nonatomic, readonly) BMPlaybackUpdateKind kind;
@property(nonatomic, readonly) uint64_t requestID;
@property(nonatomic, readonly) uint64_t pauseCommandID;
@property(nonatomic, readonly) uint64_t muteCommandID;
@property(nonatomic, readonly, nullable) NSNumber *muted;
@property(nonatomic, readonly) double position;
@property(nonatomic, readonly, nullable) NSNumber *duration;
@property(nonatomic, readonly) BOOL paused;
@property(nonatomic, readonly) BOOL seeking;
@property(nonatomic, readonly) BOOL buffering;
@property(nonatomic, readonly) BOOL seekable;
@property(nonatomic, readonly) double volume;
@property(nonatomic, readonly) double speed;
@property(nonatomic, readonly, nullable) NSNumber *audioTrackID;
@property(nonatomic, readonly, nullable) NSNumber *subtitleTrackID;
@property(nonatomic, copy, readonly) NSArray<BMPlaybackTrack *> *tracks;
@property(nonatomic, readonly) double subtitleDelay;
@property(nonatomic, readonly, nullable) NSNumber *subtitleScale;
@property(nonatomic, readonly, nullable) NSString *message;
@property(nonatomic, readonly) BMPlaybackFailureKind failureKind;
@property(nonatomic, readonly) BMPlaybackCommandFailureKind commandFailureKind;
@end

/// On-demand, path-free diagnostics. Unknown native properties remain nil.
@interface BMPlaybackDiagnostics : NSObject
@property(nonatomic, readonly) BOOL coreAlive;
@property(nonatomic, readonly) BOOL renderContextAlive;
@property(nonatomic, readonly) BOOL graphicsContextAlive;
@property(nonatomic, readonly) uint64_t coreCreationCount;
@property(nonatomic, readonly) uint64_t renderContextCreationCount;
@property(nonatomic, readonly, nullable) NSNumber *idle;
@property(nonatomic, readonly, nullable) NSNumber *videoOutputConfigured;
@property(nonatomic, readonly, nullable) NSString *hardwareDecoder;
@property(nonatomic, readonly, nullable) NSNumber *videoWidth;
@property(nonatomic, readonly, nullable) NSNumber *videoHeight;
@property(nonatomic, readonly, nullable) NSNumber *audioSampleRate;
@property(nonatomic, readonly, nullable) NSNumber *audioChannelCount;
@property(nonatomic, readonly, nullable) NSNumber *audioOutputSampleRate;
@property(nonatomic, readonly) uint64_t openCount;
@property(nonatomic, readonly) uint64_t snapshotCount;
@property(nonatomic, readonly) uint64_t drawCount;
@property(nonatomic, readonly) uint64_t videoFrameCount;
@property(nonatomic, readonly) uint64_t skippedFrameCount;
@property(nonatomic, readonly) uint64_t blankDrawCount;
@property(nonatomic, readonly) BOOL lastDrawWasClearOnly;
@property(nonatomic, readonly, nullable) NSNumber *firstVideoFrameUptime;
@property(nonatomic, readonly, nullable) NSString *videoSyncMode;
@property(nonatomic, readonly, nullable) NSNumber *videoTimingOffset;
@property(nonatomic, readonly) uint64_t timedFrameCount;
@property(nonatomic, readonly) uint64_t earlySubmissionCount;
@property(nonatomic, readonly) int64_t submissionErrorTotalUS;
@property(nonatomic, readonly) int64_t submissionErrorMinimumUS;
@property(nonatomic, readonly) int64_t submissionErrorMaximumUS;
/// GPU render intervals around mpv OpenGL rendering, when enabled and supported.
@property(nonatomic, copy, readonly) NSString *gpuRenderTimingAvailability;
@property(nonatomic, copy, readonly) NSString *gpuRenderTimingMode;
@property(nonatomic, readonly) uint64_t gpuRenderTimingSampleCount;
@property(nonatomic, readonly) uint64_t gpuRenderIntervalNanoseconds;
@property(nonatomic, readonly) uint64_t gpuRenderPendingQueryCount;
@property(nonatomic, readonly) uint64_t gpuRenderDroppedSampleCount;
@end

/// Main-thread facade. The private control queue owns the mpv handle and all commands.
/// The surface owns the OpenGL render context; teardown releases it before the handle.
NS_SWIFT_UI_ACTOR
@interface BMMPVSession : NSObject
@property(nonatomic, readonly) NSView *videoView;
@property(nonatomic, copy, nullable) void (^onUpdate)(BMPlaybackUpdate *update);
- (void)prepareWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)openURL:(NSURL *)url requestID:(uint64_t)requestID startPosition:(nullable NSNumber *)startPosition;
- (void)setPaused:(BOOL)paused requestID:(uint64_t)requestID commandID:(uint64_t)commandID;
- (void)setMuted:(BOOL)muted requestID:(uint64_t)requestID commandID:(uint64_t)commandID;
- (void)seekSeconds:(double)seconds relative:(BOOL)relative requestID:(uint64_t)requestID
    NS_SWIFT_NAME(seek(seconds:relative:requestID:));
- (void)setVolume:(double)volume;
- (void)setSpeed:(double)speed;
- (void)setAudioTrackID:(int64_t)trackID requestID:(uint64_t)requestID;
- (void)setSubtitleTrackID:(int64_t)trackID requestID:(uint64_t)requestID;
- (void)addExternalSubtitleURL:(NSURL *)url requestID:(uint64_t)requestID;
- (void)setSubtitleDelay:(double)seconds requestID:(uint64_t)requestID;
- (void)setSubtitleScale:(double)scale requestID:(uint64_t)requestID;
- (void)stop;
- (void)shutdownWithCompletion:(void (^)(void))completion;
- (void)collectDiagnosticsWithCompletion:(void (^)(BMPlaybackDiagnostics *))completion;
@end

NS_ASSUME_NONNULL_END
