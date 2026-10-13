#import "BMMPVSession.h"
#import "BMVideoSurface.h"
#import <mpv/client.h>
#import <math.h>

@interface BMPlaybackUpdate ()
@property(nonatomic) BMPlaybackUpdateKind kind;
@property(nonatomic) uint64_t requestID;
@property(nonatomic) uint64_t pauseCommandID;
@property(nonatomic) double position;
@property(nonatomic, nullable) NSNumber *duration;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL seeking;
@property(nonatomic) BOOL buffering;
@property(nonatomic) BOOL seekable;
@property(nonatomic) double volume;
@property(nonatomic, nullable) NSString *message;
@end
@implementation BMPlaybackUpdate
@end

@interface BMPlaybackDiagnostics ()
@property(nonatomic) BOOL coreAlive;
@property(nonatomic) BOOL renderContextAlive;
@property(nonatomic) uint64_t coreCreationCount;
@property(nonatomic) uint64_t renderContextCreationCount;
@property(nonatomic, nullable) NSNumber *idle;
@property(nonatomic, nullable) NSNumber *videoOutputConfigured;
@property(nonatomic, nullable) NSString *hardwareDecoder;
@property(nonatomic, nullable) NSNumber *videoWidth;
@property(nonatomic, nullable) NSNumber *videoHeight;
@property(nonatomic, nullable) NSNumber *audioSampleRate;
@property(nonatomic, nullable) NSNumber *audioChannelCount;
@property(nonatomic, nullable) NSNumber *audioOutputSampleRate;
@property(nonatomic) uint64_t openCount;
@property(nonatomic) uint64_t snapshotCount;
@property(nonatomic) uint64_t drawCount;
@property(nonatomic) uint64_t videoFrameCount;
@property(nonatomic) uint64_t skippedFrameCount;
@property(nonatomic) uint64_t blankDrawCount;
@property(nonatomic) BOOL lastDrawWasClearOnly;
@property(nonatomic, nullable) NSNumber *firstVideoFrameUptime;
@property(nonatomic, nullable) NSString *videoSyncMode;
@property(nonatomic, nullable) NSNumber *videoTimingOffset;
@property(nonatomic) uint64_t timedFrameCount;
@property(nonatomic) uint64_t earlySubmissionCount;
@property(nonatomic) int64_t submissionErrorTotalUS;
@property(nonatomic) int64_t submissionErrorMinimumUS;
@property(nonatomic) int64_t submissionErrorMaximumUS;
@end
@implementation BMPlaybackDiagnostics
@end

@interface BMMPVSession () {
    dispatch_queue_t _controlQueue;
    dispatch_source_t _eventSource;
    dispatch_source_t _sampleTimer;
    mpv_handle *_handle;
    BMVideoSurface *_surface;
    int64_t _desiredEntryID;
    int64_t _activeEntryID;
    uint64_t _requestID;
    uint64_t _pauseCommandID;
    BOOL _loaded;
    BOOL _closing;
    uint64_t _coreCreationCount;
    uint64_t _openCount;
    uint64_t _snapshotCount;
}
@end

// The source stays alive until mpv_set_wakeup_callback(..., NULL, NULL) returns.
static void BMMPVWakeup(void *context) {
    dispatch_source_merge_data((__bridge dispatch_source_t)context, 1);
}

static const uint64_t BMVideoOutputObservation = 1;

@implementation BMMPVSession

- (instancetype)init {
    self = [super init];
    if (self) {
        _controlQueue = dispatch_queue_create("io.github.tech-zjf.Bomu.mpv-control", DISPATCH_QUEUE_SERIAL);
        _surface = [[BMVideoSurface alloc] initWithFrame:NSZeroRect];
        _desiredEntryID = -1;
        _activeEntryID = -1;
    }
    return self;
}

- (NSView *)videoView { return _surface; }

- (void)prepareWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(_controlQueue, ^{
        NSAssert(!self->_handle && !self->_closing, @"A session is prepared once");
        self->_handle = mpv_create();
        if (self->_handle) self->_coreCreationCount += 1;
        int result = self->_handle ? [self configureCore] : MPV_ERROR_NOMEM;
        if (result >= 0) result = mpv_initialize(self->_handle);
        if (result >= 0) result = mpv_observe_property(self->_handle, BMVideoOutputObservation,
                                                     "vo-configured", MPV_FORMAT_FLAG);
        if (result < 0) {
            if (self->_handle) mpv_terminate_destroy(self->_handle);
            self->_handle = NULL;
            NSError *error = [self errorForCode:result];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            return;
        }
        [self installEventPump];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_surface attachCore:self->_handle completion:^(NSError *error) {
                if (error) {
                    [self shutdownWithCompletion:^{ completion(error); }];
                    return;
                }
                completion(nil);
            }];
        });
    });
}

- (void)openURL:(NSURL *)url requestID:(uint64_t)requestID {
    dispatch_async(_controlQueue, ^{
        if (!self->_handle || self->_closing) return;
        self->_requestID = requestID;
        self->_pauseCommandID = 0;
        self->_desiredEntryID = -1;
        self->_loaded = NO;
        [self setSampling:NO];
        if (!url.isFileURL || ![url checkResourceIsReachableAndReturnError:nil]) {
            [self publishFailure:NSLocalizedString(@"error.fileUnavailable", nil)];
            return;
        }
        int paused = 0;
        int result = mpv_set_property(self->_handle, "pause", MPV_FORMAT_FLAG, &paused);
        const char *arguments[] = {"loadfile", url.fileSystemRepresentation, "replace", NULL};
        if (result >= 0) result = mpv_command(self->_handle, arguments);
        if (result >= 0) {
            self->_openCount += 1;
            result = mpv_get_property(self->_handle, "playlist/0/id", MPV_FORMAT_INT64,
                                      &self->_desiredEntryID);
        }
        if (result < 0) [self publishFailure:[self errorForCode:result].localizedDescription];
    });
}

- (void)setPaused:(BOOL)paused requestID:(uint64_t)requestID commandID:(uint64_t)commandID {
    dispatch_async(_controlQueue, ^{
        if (!self->_handle || self->_closing || !self->_loaded || self->_requestID != requestID ||
            commandID <= self->_pauseCommandID) return;
        int flag = paused;
        int result = mpv_set_property(self->_handle, "pause", MPV_FORMAT_FLAG, &flag);
        if (result < 0) {
            [self publishFailure:[self errorForCode:result].localizedDescription];
            return;
        }
        // Only snapshots sampled after the property succeeds acknowledge this command.
        self->_pauseCommandID = commandID;
        [self samplePlayback];
    });
}

- (void)seekSeconds:(double)seconds relative:(BOOL)relative requestID:(uint64_t)requestID {
    if (!isfinite(seconds)) return;
    dispatch_async(_controlQueue, ^{
        if (!self->_handle || self->_closing || !self->_loaded || self->_requestID != requestID) return;
        // mpv combines pending relative seeks and uses its last seek target while decoding.
        // Do not resolve offsets from the UI's slower progress snapshots.
        double value = relative ? seconds : fmax(0, seconds);
        NSString *target = [NSString stringWithFormat:@"%.6f", value];
        const char *mode = relative ? "relative+exact" : "absolute+exact";
        const char *arguments[] = {"seek", target.UTF8String, mode, NULL};
        int result = mpv_command(self->_handle, arguments);
        if (result < 0) [self publishFailure:[self errorForCode:result].localizedDescription];
    });
}

- (void)setVolume:(double)volume {
    if (!isfinite(volume)) return;
    dispatch_async(_controlQueue, ^{
        if (!self->_handle || self->_closing) return;
        double value = fmin(100, fmax(0, volume));
        int result = mpv_set_property(self->_handle, "volume", MPV_FORMAT_DOUBLE, &value);
        if (result < 0) [self publishFailure:[self errorForCode:result].localizedDescription];
    });
}

- (void)stop {
    dispatch_async(_controlQueue, ^{
        if (!self->_handle || self->_closing) return;
        self->_requestID = 0;
        self->_desiredEntryID = -1;
        self->_loaded = NO;
        [self setSampling:NO];
        const char *arguments[] = {"stop", NULL};
        mpv_command(self->_handle, arguments);
    });
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    dispatch_async(_controlQueue, ^{
        self->_closing = YES;
        self->_loaded = NO;
        if (self->_sampleTimer) {
            dispatch_source_cancel(self->_sampleTimer);
            self->_sampleTimer = nil;
        }
        if (self->_handle) mpv_set_wakeup_callback(self->_handle, NULL, NULL);
        if (self->_eventSource) {
            dispatch_source_cancel(self->_eventSource);
            self->_eventSource = nil;
        }
        // No queue waits on another queue. The render context must be released first.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_surface shutdownWithCompletion:^{
                dispatch_async(self->_controlQueue, ^{
                    if (self->_handle) mpv_terminate_destroy(self->_handle);
                    self->_handle = NULL;
                    dispatch_async(dispatch_get_main_queue(), completion);
                });
            }];
        });
    });
}

- (void)collectDiagnosticsWithCompletion:(void (^)(BMPlaybackDiagnostics *))completion {
    dispatch_async(_controlQueue, ^{
        BMPlaybackDiagnostics *value = [[BMPlaybackDiagnostics alloc] init];
        value.coreAlive = self->_handle != NULL;
        value.coreCreationCount = self->_coreCreationCount;
        value.openCount = self->_openCount;
        value.snapshotCount = self->_snapshotCount;
        if (self->_handle && !self->_closing) {
            value.idle = [self optionalFlagProperty:"idle-active"];
            value.videoOutputConfigured = [self optionalFlagProperty:"vo-configured"];
            value.videoWidth = [self optionalIntegerProperty:"video-params/w"];
            value.videoHeight = [self optionalIntegerProperty:"video-params/h"];
            value.audioSampleRate = [self optionalIntegerProperty:"audio-params/samplerate"];
            value.audioChannelCount = [self optionalIntegerProperty:"audio-params/channel-count"];
            value.audioOutputSampleRate = [self optionalIntegerProperty:"audio-out-params/samplerate"];
            char *decoder = mpv_get_property_string(self->_handle, "hwdec-current");
            if (decoder) {
                value.hardwareDecoder = [NSString stringWithUTF8String:decoder];
                mpv_free(decoder);
            }
            char *syncMode = mpv_get_property_string(self->_handle, "video-sync");
            if (syncMode) {
                value.videoSyncMode = [NSString stringWithUTF8String:syncMode];
                mpv_free(syncMode);
            }
            double timingOffset = 0;
            if (mpv_get_property(self->_handle, "video-timing-offset", MPV_FORMAT_DOUBLE, &timingOffset) >= 0) {
                value.videoTimingOffset = @(timingOffset);
            }
        }
        // Never wait for rendering while holding the control queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_surface collectStatistics:^(BMRenderStatistics render) {
                value.renderContextAlive = render.contextAlive;
                value.renderContextCreationCount = render.contextCreationCount;
                value.drawCount = render.drawCount;
                value.videoFrameCount = render.videoFrameCount;
                value.skippedFrameCount = render.skippedFrameCount;
                value.blankDrawCount = render.blankDrawCount;
                value.lastDrawWasClearOnly = render.lastDrawWasClearOnly;
                value.timedFrameCount = render.timedFrameCount;
                value.earlySubmissionCount = render.earlySubmissionCount;
                value.submissionErrorTotalUS = render.submissionErrorTotalUS;
                value.submissionErrorMinimumUS = render.submissionErrorMinimumUS;
                value.submissionErrorMaximumUS = render.submissionErrorMaximumUS;
                if (render.firstVideoFrameUptime > 0) {
                    value.firstVideoFrameUptime = @(render.firstVideoFrameUptime);
                }
                completion(value);
            }];
        });
    });
}

- (int)configureCore {
    const char *options[][2] = {
        {"config", "no"}, {"terminal", "no"}, {"load-scripts", "no"},
        {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"},
        {"osc", "no"}, {"ytdl", "no"}, {"osd-level", "0"},
        {"vo", "libmpv"}, {"hwdec", "auto-safe"}, {"idle", "yes"},
        {"keep-open", "no"}, {"audio-display", "no"},
        // BMVideoLayer must not wait inside an AppKit draw. Let mpv issue audio-timed
        // frames when due, with no advance-render headroom that would require that wait.
        {"video-sync", "audio"}, {"video-timing-offset", "0"},
        {"target-prim", "bt.709"}, {"target-trc", "srgb"}
    };
    for (size_t index = 0; index < sizeof(options) / sizeof(options[0]); index++) {
        int result = mpv_set_option_string(_handle, options[index][0], options[index][1]);
        if (result < 0) return result;
    }
    return 0;
}

- (void)installEventPump {
    __weak BMMPVSession *weakSelf = self;
    _eventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _controlQueue);
    dispatch_source_set_event_handler(_eventSource, ^{ [weakSelf drainEvents]; });
    dispatch_resume(_eventSource);
    mpv_set_wakeup_callback(_handle, BMMPVWakeup, (__bridge void *)_eventSource);
    _sampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _controlQueue);
    dispatch_source_set_timer(_sampleTimer, DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10, NSEC_PER_MSEC * 10);
    dispatch_source_set_event_handler(_sampleTimer, ^{ [weakSelf samplePlayback]; });
    dispatch_resume(_sampleTimer);
}

- (void)drainEvents {
    if (!_handle || _closing) return;
    while (YES) {
        mpv_event *event = mpv_wait_event(_handle, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
            case MPV_EVENT_PROPERTY_CHANGE: {
                if (event->reply_userdata != BMVideoOutputObservation) break;
                mpv_event_property *property = event->data;
                // Present video only while the core explicitly reports an active VO.
                // An unavailable VO property also revokes permission to retain an old frame.
                BOOL configured = property && property->format == MPV_FORMAT_FLAG && property->data &&
                    *(int *)property->data != 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_surface setVideoOutputConfigured:configured];
                });
                break;
            }
            case MPV_EVENT_START_FILE: {
                mpv_event_start_file *start = event->data;
                _activeEntryID = start->playlist_entry_id;
                _loaded = NO;
                break;
            }
            case MPV_EVENT_FILE_LOADED:
                if (_activeEntryID == _desiredEntryID && _requestID != 0) {
                    _loaded = YES;
                    [self setSampling:YES];
                    [self publishKind:BMPlaybackUpdateLoaded];
                    [self samplePlayback];
                }
                break;
            case MPV_EVENT_END_FILE: {
                mpv_event_end_file *end = event->data;
                if (end->playlist_entry_id != _desiredEntryID || _requestID == 0) break;
                _loaded = NO;
                [self setSampling:NO];
                if (end->reason == MPV_END_FILE_REASON_EOF) [self publishKind:BMPlaybackUpdateEnded];
                if (end->reason == MPV_END_FILE_REASON_ERROR) {
                    [self publishFailure:[self errorForCode:end->error].localizedDescription];
                }
                break;
            }
            case MPV_EVENT_QUEUE_OVERFLOW:
                [self publishFailure:NSLocalizedString(@"error.eventOverflow", nil)];
                break;
            default:
                break;
        }
    }
}

- (void)setSampling:(BOOL)active {
    if (_sampleTimer) {
        dispatch_source_set_timer(_sampleTimer, active ? DISPATCH_TIME_NOW : DISPATCH_TIME_FOREVER,
                                  NSEC_PER_SEC / 10, NSEC_PER_MSEC * 10);
    }
}

- (void)samplePlayback {
    if (!_handle || _closing || !_loaded || _activeEntryID != _desiredEntryID) return;
    BMPlaybackUpdate *update = [self updateWithKind:BMPlaybackUpdateSnapshot];
    double position = 0;
    if (mpv_get_property(_handle, "time-pos", MPV_FORMAT_DOUBLE, &position) < 0) return;
    update.position = fmax(0, position);
    update.pauseCommandID = _pauseCommandID;
    double duration = 0;
    if (mpv_get_property(_handle, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0 && isfinite(duration) && duration > 0) {
        update.duration = @(duration);
    }
    update.paused = [self flagProperty:"pause"];
    update.seeking = [self flagProperty:"seeking"];
    update.buffering = [self flagProperty:"paused-for-cache"];
    update.seekable = [self flagProperty:"seekable"];
    double volume = 0;
    if (mpv_get_property(_handle, "volume", MPV_FORMAT_DOUBLE, &volume) >= 0) update.volume = volume;
    _snapshotCount += 1;
    [self publish:update];
}

- (BOOL)flagProperty:(const char *)name {
    int value = 0;
    return mpv_get_property(_handle, name, MPV_FORMAT_FLAG, &value) >= 0 && value != 0;
}

- (NSNumber *)optionalFlagProperty:(const char *)name {
    int value = 0;
    if (mpv_get_property(_handle, name, MPV_FORMAT_FLAG, &value) < 0) return nil;
    return @(value != 0);
}

- (NSNumber *)optionalIntegerProperty:(const char *)name {
    int64_t value = 0;
    if (mpv_get_property(_handle, name, MPV_FORMAT_INT64, &value) < 0) return nil;
    return @(value);
}

- (BMPlaybackUpdate *)updateWithKind:(BMPlaybackUpdateKind)kind {
    BMPlaybackUpdate *update = [[BMPlaybackUpdate alloc] init];
    update.kind = kind;
    update.requestID = _requestID;
    return update;
}

- (void)publishKind:(BMPlaybackUpdateKind)kind { [self publish:[self updateWithKind:kind]]; }

- (void)publishFailure:(NSString *)message {
    _loaded = NO;
    [self setSampling:NO];
    if (_handle) {
        const char *arguments[] = {"stop", NULL};
        mpv_command(_handle, arguments);
    }
    BMPlaybackUpdate *update = [self updateWithKind:BMPlaybackUpdateFailed];
    update.message = message;
    [self publish:update];
}

- (void)publish:(BMPlaybackUpdate *)update {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onUpdate) self.onUpdate(update);
    });
}

- (NSError *)errorForCode:(int)code {
    NSString *detail = [NSString stringWithUTF8String:mpv_error_string(code)];
    return [NSError errorWithDomain:@"Bomu.MPV" code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"error.engine", nil), detail]
    }];
}

- (void)dealloc { NSAssert(!_handle, @"Await shutdown before releasing a playback session"); }
@end
