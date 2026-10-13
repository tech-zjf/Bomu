#import "BMVideoSurface.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl3.h>
#import <mpv/render_gl.h>
#import <dlfcn.h>

@class BMVideoLayer;

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
}
@property(nonatomic, weak) BMVideoLayer *layer;
@property(nonatomic, readonly, nullable) NSError *creationError;
- (void)attachCore:(mpv_handle *)core completion:(void (^)(NSError * _Nullable))completion;
- (void)setVideoOutputConfigured:(BOOL)configured;
- (void)shutdownWithCompletion:(void (^)(void))completion;
- (void)collectStatistics:(void (^)(BMRenderStatistics))completion;
@end

@interface BMVideoLayer : CAOpenGLLayer
@property(nonatomic, strong) BMGLRenderer *renderer;
@end

@interface BMVideoSurface ()
@property(nonatomic, strong) BMGLRenderer *renderer;
@end

static void *BMOpenGLSymbol(void *unused, const char *name) { return dlsym(RTLD_DEFAULT, name); }
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
            CGLSetCurrentContext(NULL);
            CGLUnlockContext(self->context);
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
        BMRenderStatistics value = self->statistics;
        value.contextAlive = self->renderContext != NULL;
        [self->lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(value); });
    });
}

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
    return CGLRetainPixelFormat(_renderer->pixelFormat);
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)format {
    return CGLRetainContext(_renderer->context);
}

- (void)display {
    BMGLRenderer *renderer = self.renderer;
    if (!renderer || !renderer->context) return;
    // Core Animation can also request a draw on the main thread (resize/backing changes).
    // Both paths share this lock and the same current CGL context; there is no control-queue wait.
    [renderer->lock lock];
    CGLLockContext(renderer->context);
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(renderer->context);
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
    CGLUnlockContext(renderer->context);
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
    CGLLockContext(renderer->context);
    CGLSetCurrentContext(renderer->context);
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
        int result = mpv_render_context_render(renderer->renderContext, parameters);
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
    if (submittedVideoFrame && renderer->statistics.firstVideoFrameUptime == 0) {
        // Commands submitted to the layer FBO, not GPU completion or physical display scanout.
        renderer->statistics.firstVideoFrameUptime = CACurrentMediaTime();
    }
    CGLUnlockContext(renderer->context);
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
    [_renderer shutdownWithCompletion:completion];
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
