#import "BMVideoSurface.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl3.h>
#import <mpv/render_gl.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdatomic.h>
#import <string.h>

@class BMVideoLayer;

#if BM_ENABLE_GPU_RENDER_TIMING
#define BM_GPU_RENDER_QUERY_COUNT 8
typedef struct {
    GLuint startIdentifier;
    GLuint endIdentifier;
    GLuint elapsedIdentifier;
    BOOL pending;
} BMGPURenderQuery;

// Benchmark-only interception: mpv/libplacebo also use GL_TIME_ELAPSED internally.
// Suppress only their profiling queries when the benchmark wraps the complete render call.
static atomic_bool BMGPUSuppressLibraryElapsedQueries = ATOMIC_VAR_INIT(false);
static PFNGLBEGINQUERYPROC BMOriginalBeginQuery;
static PFNGLENDQUERYPROC BMOriginalEndQuery;

static void APIENTRY BMInterceptBeginQuery(GLenum target, GLuint identifier) {
    if (target == GL_TIME_ELAPSED &&
        atomic_load_explicit(&BMGPUSuppressLibraryElapsedQueries, memory_order_relaxed)) {
        return;
    }
    if (BMOriginalBeginQuery) BMOriginalBeginQuery(target, identifier);
}

static void APIENTRY BMInterceptEndQuery(GLenum target) {
    if (target == GL_TIME_ELAPSED &&
        atomic_load_explicit(&BMGPUSuppressLibraryElapsedQueries, memory_order_relaxed)) {
        return;
    }
    if (BMOriginalEndQuery) BMOriginalEndQuery(target);
}
#endif

/// A render-only owner. It never issues normal mpv commands or waits on the control queue.
@interface BMGLRenderer : NSObject {
@public
    NSRecursiveLock *lock;
    CGLContextObj context;
    CGLPixelFormatObj pixelFormat;
    mpv_render_context *renderContext;
    // Borrowed only for mpv's render-thread-safe clock; cleared before the core can be destroyed.
    mpv_handle *clockCore;
    BOOL didDraw;
    BOOL videoOutputConfigured;
    BMRenderStatistics statistics;
#if BM_ENABLE_GPU_RENDER_TIMING
    BMGPURenderQuery gpuRenderQueries[BM_GPU_RENDER_QUERY_COUNT];
    NSUInteger nextGPURenderQueryIndex;
    BMGPURenderTimingMode gpuRenderTimingMode;
#endif
}
@property(nonatomic, weak) BMVideoLayer *layer;
@property(nonatomic, readonly, nullable) NSError *creationError;
- (void)attachCore:(mpv_handle *)core completion:(void (^)(NSError * _Nullable))completion;
- (void)setVideoOutputConfigured:(BOOL)configured;
- (void)shutdownWithCompletion:(void (^)(void))completion;
- (void)collectStatistics:(void (^)(BMRenderStatistics))completion;
#if BM_ENABLE_GPU_RENDER_TIMING
- (void)initializeGPURenderTiming;
- (void)collectCompletedGPURenderQueries;
- (NSInteger)beginGPURenderTimingQuery;
- (void)endGPURenderTimingQueryAtIndex:(NSInteger)index;
- (void)deleteGPURenderTimingQueries;
#endif
@end

@interface BMVideoLayer : CAOpenGLLayer
@property(nonatomic, strong) BMGLRenderer *renderer;
@end

@interface BMVideoSurface ()
@property(nonatomic, strong) BMGLRenderer *renderer;
@end

static void *BMOpenGLSymbol(void *unused, const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
#if BM_ENABLE_GPU_RENDER_TIMING
    if (!symbol) return NULL;
    if (strcmp(name, "glBeginQuery") == 0 || strcmp(name, "glBeginQueryARB") == 0 ||
        strcmp(name, "glBeginQueryEXT") == 0) {
        BMOriginalBeginQuery = (PFNGLBEGINQUERYPROC)symbol;
        return (void *)BMInterceptBeginQuery;
    }
    if (strcmp(name, "glEndQuery") == 0 || strcmp(name, "glEndQueryARB") == 0 ||
        strcmp(name, "glEndQueryEXT") == 0) {
        BMOriginalEndQuery = (PFNGLENDQUERYPROC)symbol;
        return (void *)BMInterceptEndQuery;
    }
#endif
    return symbol;
}
static void BMRenderWakeup(void *source) {
    dispatch_source_merge_data((__bridge dispatch_source_t)source, 1);
}

@implementation BMGLRenderer {
    dispatch_queue_t _renderQueue;
    dispatch_source_t _updateSource;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        lock = [[NSRecursiveLock alloc] init];
        _renderQueue = dispatch_queue_create("io.github.tech-zjf.Bomu.mpv-render", DISPATCH_QUEUE_SERIAL);
        CGLPixelFormatAttribute attributes[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
            (CGLPixelFormatAttribute)0
        };
        GLint count = 0;
        CGLError result = CGLChoosePixelFormat(attributes, &pixelFormat, &count);
        if (result == kCGLNoError) result = CGLCreateContext(pixelFormat, NULL, &context);
        if (result != kCGLNoError) {
            _creationError = [NSError errorWithDomain:@"Bomu.OpenGL" code:result userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"error.renderUnavailable", nil)
            }];
        }
    }
    return self;
}

- (void)attachCore:(mpv_handle *)core completion:(void (^)(NSError *))completion {
    dispatch_async(_renderQueue, ^{
        if (self.creationError) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(self.creationError); });
            return;
        }
        [self->lock lock];
        CGLLockContext(self->context);
        CGLSetCurrentContext(self->context);
#if BM_ENABLE_GPU_RENDER_TIMING
        [self initializeGPURenderTiming];
#endif
        mpv_opengl_init_params gl = { .get_proc_address = BMOpenGLSymbol };
        int advanced = 1;
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
            {MPV_RENDER_PARAM_INVALID, NULL}
        };
        int result = mpv_render_context_create(&self->renderContext, core, parameters);
        if (result >= 0) {
            self->statistics.contextCreationCount += 1;
            self->clockCore = core;
            __weak BMGLRenderer *weakSelf = self;
            self->_updateSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, self->_renderQueue);
            dispatch_source_set_event_handler(self->_updateSource, ^{ [weakSelf.layer display]; });
            dispatch_resume(self->_updateSource);
            mpv_render_context_set_update_callback(self->renderContext, BMRenderWakeup,
                                                   (__bridge void *)self->_updateSource);
        }
#if BM_ENABLE_GPU_RENDER_TIMING
        if (result < 0) {
            [self deleteGPURenderTimingQueries];
            self->gpuRenderTimingMode = BMGPURenderTimingModeDisabled;
            self->statistics.gpuRenderTimingStatus = BMGPURenderTimingStatusDisabled;
            self->statistics.gpuRenderTimingMode = BMGPURenderTimingModeDisabled;
            atomic_store_explicit(&BMGPUSuppressLibraryElapsedQueries, false, memory_order_relaxed);
        }
#endif
        CGLSetCurrentContext(NULL);
        CGLUnlockContext(self->context);
        [self->lock unlock];
        NSError *error = nil;
        if (result < 0) {
            error = [NSError errorWithDomain:@"Bomu.Render" code:result userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"error.renderUnavailable", nil)
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)setVideoOutputConfigured:(BOOL)configured {
    dispatch_async(_renderQueue, ^{
        [self->lock lock];
        BOOL changed = self->videoOutputConfigured != configured;
        self->videoOutputConfigured = configured;
        [self->lock unlock];
        // libmpv can retain its previous texture after its VO closes. Clearing the
        // layer is a presentation transition, not evidence of another media frame.
        if (changed) [self.layer display];
    });
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    dispatch_async(_renderQueue, ^{
        [self->lock lock];
        if (self->context) {
            CGLLockContext(self->context);
            CGLSetCurrentContext(self->context);
            if (self->renderContext) {
                mpv_render_context_set_update_callback(self->renderContext, NULL, NULL);
                mpv_render_context_free(self->renderContext);
                self->renderContext = NULL;
                self->clockCore = NULL;
            }
#if BM_ENABLE_GPU_RENDER_TIMING
            if (self->gpuRenderTimingMode == BMGPURenderTimingModeElapsed) {
                atomic_store_explicit(&BMGPUSuppressLibraryElapsedQueries, false, memory_order_relaxed);
            }
            [self collectCompletedGPURenderQueries];
            [self deleteGPURenderTimingQueries];
#endif
            CGLSetCurrentContext(NULL);
            CGLUnlockContext(self->context);
            CGLReleaseContext(self->context);
            self->context = NULL;
        }
        if (self->pixelFormat) {
            CGLReleasePixelFormat(self->pixelFormat);
            self->pixelFormat = NULL;
        }
        if (self->_updateSource) {
            dispatch_source_cancel(self->_updateSource);
            self->_updateSource = nil;
        }
        [self->lock unlock];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)collectStatistics:(void (^)(BMRenderStatistics))completion {
    dispatch_async(_renderQueue, ^{
        [self->lock lock];
#if BM_ENABLE_GPU_RENDER_TIMING
        if (self->context) {
            CGLLockContext(self->context);
            CGLContextObj previous = CGLGetCurrentContext();
            CGLSetCurrentContext(self->context);
            [self collectCompletedGPURenderQueries];
            CGLSetCurrentContext(previous);
            CGLUnlockContext(self->context);
        }
#endif
        BMRenderStatistics value = self->statistics;
        value.contextAlive = self->renderContext != NULL;
        value.graphicsContextAlive = self->context != NULL;
        [self->lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(value); });
    });
}

#if BM_ENABLE_GPU_RENDER_TIMING
- (void)initializeGPURenderTiming {
    self->statistics.gpuRenderTimingStatus = BMGPURenderTimingStatusExtensionUnavailable;
    GLint majorVersion = 0;
    GLint minorVersion = 0;
    const GLubyte *versionString = glGetString(GL_VERSION);
    if (versionString) {
        sscanf((const char *)versionString, "%d.%d", &majorVersion, &minorVersion);
    }
    BOOL supportsTimerQueries = majorVersion > 3 || (majorVersion == 3 && minorVersion >= 3);
    if (!supportsTimerQueries) {
        GLint extensionCount = 0;
        glGetIntegerv(GL_NUM_EXTENSIONS, &extensionCount);
        for (GLint index = 0; index < extensionCount; index++) {
            const GLubyte *extension = glGetStringi(GL_EXTENSIONS, (GLuint)index);
            if (extension && (strcmp((const char *)extension, "GL_ARB_timer_query") == 0 ||
                              strcmp((const char *)extension, "GL_EXT_disjoint_timer_query") == 0)) {
                supportsTimerQueries = YES;
                break;
            }
        }
    }
    if (!supportsTimerQueries) return;

    self->statistics.gpuRenderTimingStatus = BMGPURenderTimingStatusCounterUnavailable;
    GLint counterBits = 0;
    glGetQueryiv(GL_TIMESTAMP, GL_QUERY_COUNTER_BITS, &counterBits);
    BMGPURenderTimingMode mode = BMGPURenderTimingModeTimestamp;
    if (counterBits <= 0) {
        glGetQueryiv(GL_TIME_ELAPSED, GL_QUERY_COUNTER_BITS, &counterBits);
        mode = BMGPURenderTimingModeElapsed;
    }
    if (counterBits <= 0) return;

    self->statistics.gpuRenderTimingStatus = BMGPURenderTimingStatusQueryAllocationFailed;
    self->gpuRenderTimingMode = mode;
    self->statistics.gpuRenderTimingMode = mode;
    if (mode == BMGPURenderTimingModeElapsed) {
        atomic_store_explicit(&BMGPUSuppressLibraryElapsedQueries, true, memory_order_relaxed);
    }
    NSUInteger identifiersPerQuery = mode == BMGPURenderTimingModeTimestamp ? 2 : 1;
    NSUInteger identifierCount = BM_GPU_RENDER_QUERY_COUNT * identifiersPerQuery;
    GLuint identifiers[BM_GPU_RENDER_QUERY_COUNT * 2] = {0};
    glGenQueries((GLsizei)identifierCount, identifiers);
    for (NSUInteger index = 0; index < BM_GPU_RENDER_QUERY_COUNT; index++) {
        NSUInteger baseIndex = index * identifiersPerQuery;
        NSUInteger endIndex = baseIndex + (identifiersPerQuery - 1);
        if (identifiers[baseIndex] == 0 || identifiers[endIndex] == 0) {
            glDeleteQueries((GLsizei)identifierCount, identifiers);
            memset(self->gpuRenderQueries, 0, sizeof(self->gpuRenderQueries));
            self->gpuRenderTimingMode = BMGPURenderTimingModeDisabled;
            self->statistics.gpuRenderTimingMode = BMGPURenderTimingModeDisabled;
            atomic_store_explicit(&BMGPUSuppressLibraryElapsedQueries, false, memory_order_relaxed);
            return;
        }
        if (mode == BMGPURenderTimingModeTimestamp) {
            self->gpuRenderQueries[index].startIdentifier = identifiers[baseIndex];
            self->gpuRenderQueries[index].endIdentifier = identifiers[endIndex];
        } else {
            self->gpuRenderQueries[index].elapsedIdentifier = identifiers[baseIndex];
        }
    }
    self->statistics.gpuRenderTimingStatus = BMGPURenderTimingStatusSupported;
}

- (void)collectCompletedGPURenderQueries {
    for (NSUInteger index = 0; index < BM_GPU_RENDER_QUERY_COUNT; index++) {
        BMGPURenderQuery *query = &self->gpuRenderQueries[index];
        if (!query->pending) continue;

        GLuint resultIdentifier = self->gpuRenderTimingMode == BMGPURenderTimingModeElapsed
            ? query->elapsedIdentifier : query->endIdentifier;
        GLint available = GL_FALSE;
        glGetQueryObjectiv(resultIdentifier, GL_QUERY_RESULT_AVAILABLE, &available);
        if (!available) continue;

        GLuint64 intervalNanoseconds = 0;
        if (self->gpuRenderTimingMode == BMGPURenderTimingModeElapsed) {
            glGetQueryObjectui64v(resultIdentifier, GL_QUERY_RESULT, &intervalNanoseconds);
        } else {
            GLuint64 startTimestamp = 0;
            GLuint64 endTimestamp = 0;
            glGetQueryObjectui64v(query->startIdentifier, GL_QUERY_RESULT, &startTimestamp);
            glGetQueryObjectui64v(query->endIdentifier, GL_QUERY_RESULT, &endTimestamp);
            if (endTimestamp < startTimestamp) {
                self->statistics.gpuRenderDroppedSampleCount += 1;
                self->statistics.gpuRenderPendingQueryCount -= 1;
                query->pending = NO;
                continue;
            }
            intervalNanoseconds = endTimestamp - startTimestamp;
        }
        {
            self->statistics.gpuRenderTimingSampleCount += 1;
            if (UINT64_MAX - self->statistics.gpuRenderIntervalNanoseconds < intervalNanoseconds) {
                self->statistics.gpuRenderIntervalNanoseconds = UINT64_MAX;
            } else {
                self->statistics.gpuRenderIntervalNanoseconds += intervalNanoseconds;
            }
        }
        self->statistics.gpuRenderPendingQueryCount -= 1;
        query->pending = NO;
    }
}

- (NSInteger)beginGPURenderTimingQuery {
    if (self->statistics.gpuRenderTimingStatus != BMGPURenderTimingStatusSupported) return NSNotFound;
    [self collectCompletedGPURenderQueries];

    for (NSUInteger offset = 0; offset < BM_GPU_RENDER_QUERY_COUNT; offset++) {
        NSUInteger index = (self->nextGPURenderQueryIndex + offset) % BM_GPU_RENDER_QUERY_COUNT;
        BMGPURenderQuery *query = &self->gpuRenderQueries[index];
        if (query->pending) continue;
        if (self->gpuRenderTimingMode == BMGPURenderTimingModeElapsed) {
            glBeginQuery(GL_TIME_ELAPSED, query->elapsedIdentifier);
        } else {
            glQueryCounter(query->startIdentifier, GL_TIMESTAMP);
        }
        self->nextGPURenderQueryIndex = (index + 1) % BM_GPU_RENDER_QUERY_COUNT;
        return (NSInteger)index;
    }

    self->statistics.gpuRenderDroppedSampleCount += 1;
    return NSNotFound;
}

- (void)endGPURenderTimingQueryAtIndex:(NSInteger)index {
    if (index == NSNotFound) return;
    if (self->gpuRenderTimingMode == BMGPURenderTimingModeElapsed) {
        glEndQuery(GL_TIME_ELAPSED);
    } else {
        glQueryCounter(self->gpuRenderQueries[index].endIdentifier, GL_TIMESTAMP);
    }
    self->gpuRenderQueries[index].pending = YES;
    self->statistics.gpuRenderPendingQueryCount += 1;
}

- (void)deleteGPURenderTimingQueries {
    GLuint identifiers[BM_GPU_RENDER_QUERY_COUNT * 2] = {0};
    NSUInteger identifiersPerQuery = self->gpuRenderTimingMode == BMGPURenderTimingModeTimestamp ? 2 : 1;
    NSUInteger identifierCount = BM_GPU_RENDER_QUERY_COUNT * identifiersPerQuery;
    for (NSUInteger index = 0; index < BM_GPU_RENDER_QUERY_COUNT; index++) {
        NSUInteger baseIndex = index * identifiersPerQuery;
        if (self->gpuRenderTimingMode == BMGPURenderTimingModeTimestamp) {
            identifiers[baseIndex] = self->gpuRenderQueries[index].startIdentifier;
            identifiers[baseIndex + 1] = self->gpuRenderQueries[index].endIdentifier;
        } else {
            identifiers[baseIndex] = self->gpuRenderQueries[index].elapsedIdentifier;
        }
        self->gpuRenderQueries[index].startIdentifier = 0;
        self->gpuRenderQueries[index].endIdentifier = 0;
        self->gpuRenderQueries[index].elapsedIdentifier = 0;
        self->gpuRenderQueries[index].pending = NO;
    }
    glDeleteQueries((GLsizei)identifierCount, identifiers);
}
#endif

- (void)dealloc {
    NSAssert(!renderContext, @"Release the renderer before the mpv core");
    if (context) CGLReleaseContext(context);
    if (pixelFormat) CGLReleasePixelFormat(pixelFormat);
}
@end

@implementation BMVideoLayer

- (instancetype)init {
    self = [super init];
    if (self) {
        self.asynchronous = NO;
        self.opaque = YES;
        self.needsDisplayOnBoundsChange = YES;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        self.colorspace = space;
        CGColorSpaceRelease(space);
    }
    return self;
}

- (instancetype)initWithLayer:(id)layer {
    self = [super initWithLayer:layer];
    if (self && [layer isKindOfClass:BMVideoLayer.class]) _renderer = [layer renderer];
    return self;
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    BMGLRenderer *renderer = self.renderer;
    if (!renderer) return [super copyCGLPixelFormatForDisplayMask:mask];
    [renderer->lock lock];
    CGLPixelFormatObj pixelFormat = renderer->pixelFormat;
    if (pixelFormat) CGLRetainPixelFormat(pixelFormat);
    [renderer->lock unlock];
    return pixelFormat ?: [super copyCGLPixelFormatForDisplayMask:mask];
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)format {
    BMGLRenderer *renderer = self.renderer;
    if (!renderer) return [super copyCGLContextForPixelFormat:format];
    [renderer->lock lock];
    CGLContextObj context = renderer->context;
    if (context) CGLRetainContext(context);
    [renderer->lock unlock];
    return context ?: [super copyCGLContextForPixelFormat:format];
}

- (void)display {
    BMGLRenderer *renderer = self.renderer;
    if (!renderer) return;
    // Core Animation can also request a draw on the main thread (resize/backing changes).
    // Both paths share this lock and the same current CGL context; there is no control-queue wait.
    [renderer->lock lock];
    CGLContextObj context = renderer->context;
    if (!context) {
        [renderer->lock unlock];
        return;
    }
    CGLLockContext(context);
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(context);
    renderer->didDraw = NO;
    if (renderer->renderContext) mpv_render_context_update(renderer->renderContext);
    if (NSThread.isMainThread) {
        // AppKit may already be committing its transaction during a resize/backing change.
        // Starting another one here re-enters that commit and invalidates its handlers.
        [super display];
    } else {
        // The render queue has no AppKit run loop to commit an implicit transaction.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [super display];
        [CATransaction commit];
    }
    if (renderer->renderContext && !renderer->didDraw) {
        // A hidden/minimized layer still consumes pending frames, so advanced control cannot stall.
        int skip = 1;
        int block = 0;
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, NULL}
        };
        mpv_render_context_render(renderer->renderContext, parameters);
        renderer->statistics.skippedFrameCount += 1;
    }
    CGLSetCurrentContext(previous);
    CGLUnlockContext(context);
    [renderer->lock unlock];
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)format
              forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)timestamp {
    return YES;
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)format
          forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)timestamp {
    BMGLRenderer *renderer = self.renderer;
    [renderer->lock lock];
    CGLContextObj context = renderer->context;
    if (!context) {
        [renderer->lock unlock];
        return;
    }
    CGLLockContext(context);
    CGLSetCurrentContext(context);
    renderer->statistics.drawCount += 1;
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    renderer->statistics.lastDrawWasClearOnly = !(renderer->renderContext && renderer->videoOutputConfigured);
    BOOL submittedVideoFrame = NO;
    int64_t frameTargetTime = 0;
    if (renderer->renderContext && renderer->videoOutputConfigured) {
        mpv_render_frame_info frame = {0};
        mpv_render_param info = {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &frame};
        int infoResult = mpv_render_context_get_info(renderer->renderContext, info);
        GLint framebuffer = 0;
        GLint viewport[4];
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
        glGetIntegerv(GL_VIEWPORT, viewport);
        mpv_opengl_fbo fbo = { .fbo = framebuffer, .w = viewport[2], .h = viewport[3] };
        int flip = 1;
        // Paired with video-sync=audio and video-timing-offset=0 in BMMPVSession.
        int block = 0;
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, NULL}
        };
#if BM_ENABLE_GPU_RENDER_TIMING
        NSInteger gpuQueryIndex = [renderer beginGPURenderTimingQuery];
#endif
        int result = mpv_render_context_render(renderer->renderContext, parameters);
#if BM_ENABLE_GPU_RENDER_TIMING
        [renderer endGPURenderTimingQueryAtIndex:gpuQueryIndex];
#endif
        renderer->didDraw = YES;
        BOOL newFrame = infoResult >= 0 && (frame.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
            !(frame.flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT));
        if (result >= 0 && newFrame) {
            renderer->statistics.videoFrameCount += 1;
            submittedVideoFrame = YES;
            frameTargetTime = frame.target_time;
        }
    }
    if (renderer->statistics.lastDrawWasClearOnly) renderer->statistics.blankDrawCount += 1;
    glFlush();
    if (submittedVideoFrame && frameTargetTime > 0) {
        // Pinned mpv 0.41.0's vo_libmpv.c returns vo_frame.pts in nanoseconds,
        // despite render.h's outdated microsecond comment. Compare using its ns clock
        // before converting to microseconds; never infer units from the observed magnitude.
        int64_t error = (mpv_get_time_ns(renderer->clockCore) - frameTargetTime) / 1000;
        BMRenderStatistics *stats = &renderer->statistics;
        if (stats->timedFrameCount == 0) {
            stats->submissionErrorMinimumUS = error;
            stats->submissionErrorMaximumUS = error;
        } else {
            stats->submissionErrorMinimumUS = MIN(stats->submissionErrorMinimumUS, error);
            stats->submissionErrorMaximumUS = MAX(stats->submissionErrorMaximumUS, error);
        }
        stats->timedFrameCount += 1;
        stats->submissionErrorTotalUS += error;
        // Allow 2 ms for clock/scheduling precision when detecting systematic early submission.
        if (error < -2000) stats->earlySubmissionCount += 1;
    }
#if BM_ENABLE_GPU_RENDER_TIMING
    [renderer collectCompletedGPURenderQueries];
#endif
    if (submittedVideoFrame && renderer->statistics.firstVideoFrameUptime == 0) {
        // Commands submitted to the layer FBO, not GPU completion or physical display scanout.
        renderer->statistics.firstVideoFrameUptime = CACurrentMediaTime();
    }
    CGLUnlockContext(context);
    [renderer->lock unlock];
}
@end

@implementation BMVideoSurface

- (void)setVideoOutputConfigured:(BOOL)configured {
    [_renderer setVideoOutputConfigured:configured];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _renderer = [[BMGLRenderer alloc] init];
        BMVideoLayer *videoLayer = [[BMVideoLayer alloc] init];
        videoLayer.renderer = _renderer;
        _renderer.layer = videoLayer;
        self.layer = videoLayer;
        self.wantsLayer = YES;
    }
    return self;
}

- (void)attachCore:(mpv_handle *)core completion:(void (^)(NSError *))completion {
    [_renderer attachCore:core completion:completion];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    [_renderer shutdownWithCompletion:^{
        // Detach the CAOpenGLLayer so Core Animation releases its retained context and pixel format.
        self.layer = nil;
        self.wantsLayer = NO;
        completion();
    }];
}

- (void)collectStatistics:(void (^)(BMRenderStatistics))completion {
    [_renderer collectStatistics:completion];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateBackingScale];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateBackingScale];
}

- (void)updateBackingScale {
    if (self.window) self.layer.contentsScale = self.window.backingScaleFactor;
    [self.layer setNeedsDisplay];
}
@end
