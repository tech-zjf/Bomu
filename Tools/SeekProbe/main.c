#include <mpv/client.h>
#include <mpv/render.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/** 独立内核诊断；软件帧只写入内存，不创建窗口，不代表 OpenGL 或声音验收。 */
typedef struct {
    mpv_handle *core;
    mpv_render_context *render;
    pthread_t thread;
    bool thread_started;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool pending_update;
    bool closing;
    atomic_ulong frames;
    atomic_int render_error;
    unsigned restarts;
    int64_t last_restart_us;
    uint64_t last_reply_id;
    unsigned command_replies;
    unsigned command_errors;
    const char *expected_file;
} Probe;

static bool check(int code, const char *operation);
static int64_t monotonic_us(void);
static void update_available(void *context);
static void *render_frames(void *context);
static bool pump(Probe *probe, double seconds);
static bool measure(Probe *probe, const char *file, const char *target, bool video);
static bool load_and_wait(Probe *probe, const char *file, bool video);
static bool measure_seek(Probe *probe, const char *target);
static bool exercise_lifecycle(Probe *probe, const char *file, const char *replacement);
static bool queue_opening(Probe *probe, const char *file);
static void snapshot(Probe *probe, const char *stage);
static void close_probe(Probe *probe);

int main(int argc, char **argv) {
    bool lifecycle = argc >= 2 && strcmp(argv[1], "--lifecycle") == 0;
    bool opening = argc >= 2 && strcmp(argv[1], "--shutdown-opening") == 0;
    if ((!opening && argc < 4) || (opening && argc != 3) ||
        (!lifecycle && !opening && strcmp(argv[3], "video") && strcmp(argv[3], "audio"))) {
        fprintf(stderr, "Usage: seek-probe FILE SECONDS video|audio [OPTION=VALUE ...]\n"
                        "       seek-probe --lifecycle VIDEO REPLACEMENT [OPTION=VALUE ...]\n"
                        "       seek-probe --shutdown-opening VIDEO\n");
        return 2;
    }
    if (!lifecycle && !opening) {
        char *end = NULL;
        double target = strtod(argv[2], &end);
        if (end == argv[2] || *end || !isfinite(target) || target < 0) return 2;
    }
    Probe probe = {0};
    pthread_mutex_init(&probe.mutex, NULL);
    pthread_cond_init(&probe.condition, NULL);
    atomic_init(&probe.frames, 0);
    atomic_init(&probe.render_error, 0);
    int result = 2;
    int64_t closing_began;
    probe.core = mpv_create();
    if (!probe.core) goto done;
    const char *options[][2] = {
        {"config", "no"}, {"terminal", "no"}, {"load-scripts", "no"},
        {"vo", "libmpv"}, {"ao", "null"}, {"hwdec", "no"}, {"idle", "yes"},
        {"keep-open", "no"}, {"audio-display", "no"}, {"osd-level", "0"},
        {"video-sync", "audio"}, {"video-timing-offset", "0"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
        if (!check(mpv_set_option_string(probe.core, options[i][0], options[i][1]), options[i][0])) goto done;
    }
    for (int i = 4; i < argc; i++) {
        char *equal = strchr(argv[i], '=');
        if (!equal || equal == argv[i]) goto done;
        *equal = 0;
        if (!check(mpv_set_option_string(probe.core, argv[i], equal + 1), argv[i])) goto done;
    }
    if (!check(mpv_initialize(probe.core), "initialize")) goto done;
    if (!check(mpv_request_log_messages(probe.core, "v"), "log messages")) goto done;
    int advanced = 1;
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {0}
    };
    if (!check(mpv_render_context_create(&probe.render, probe.core, parameters), "create renderer")) goto done;
    mpv_render_context_set_update_callback(probe.render, update_available, &probe);
    if (pthread_create(&probe.thread, NULL, render_frames, &probe)) goto done;
    probe.thread_started = true;
    if (lifecycle) {
        if (exercise_lifecycle(&probe, argv[2], argv[3])) result = 0;
    } else if (opening) {
        if (queue_opening(&probe, argv[2])) result = 0;
    } else if (measure(&probe, argv[1], argv[2], strcmp(argv[3], "video") == 0)) {
        result = 0;
    }
done:
    closing_began = monotonic_us();
    close_probe(&probe);
    int64_t closing_ended = monotonic_us();
    if (lifecycle || opening) {
        double elapsed_ms = -1;
        if (closing_began >= 0 && closing_ended >= closing_began) elapsed_ms = (closing_ended - closing_began) / 1000.0;
        printf("{\"stage\":\"released\",\"coreAlive\":%s,\"renderAlive\":%s,\"threadAlive\":%s,\"elapsedMS\":%.3f}\n",
               probe.core ? "true" : "false", probe.render ? "true" : "false",
               probe.thread_started ? "true" : "false", elapsed_ms);
    }
    return result;
}

static bool check(int code, const char *operation) {
    if (code >= 0) return true;
    fprintf(stderr, "%s: %s\n", operation, mpv_error_string(code));
    return false;
}

/** core 销毁后的测时由系统单调时钟负责，不再把无效 handle 传给 mpv。 */
static int64_t monotonic_us(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return now.tv_sec * 1000000 + now.tv_nsec / 1000;
}

/** 回调只通知；所有 render API 调用归专用线程，控制线程不持有渲染锁。 */
static void update_available(void *context) {
    Probe *probe = context;
    pthread_mutex_lock(&probe->mutex);
    probe->pending_update = true;
    pthread_cond_signal(&probe->condition);
    pthread_mutex_unlock(&probe->mutex);
}

static void *render_frames(void *context) {
    Probe *probe = context;
    int size[2] = {320, 180}, block = 0;
    size_t stride = 320 * 4;
    void *buffer = NULL;
    if (posix_memalign(&buffer, 64, stride * size[1])) {
        atomic_store(&probe->render_error, MPV_ERROR_NOMEM);
        return NULL;
    }
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, "bgr0"},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, buffer},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {0}
    };
    while (true) {
        pthread_mutex_lock(&probe->mutex);
        while (!probe->pending_update && !probe->closing) pthread_cond_wait(&probe->condition, &probe->mutex);
        bool closing = probe->closing;
        probe->pending_update = false;
        pthread_mutex_unlock(&probe->mutex);
        if (closing) break;
        if (!(mpv_render_context_update(probe->render) & MPV_RENDER_UPDATE_FRAME)) continue;
        mpv_render_frame_info frame = {0};
        int info = mpv_render_context_get_info(probe->render,
            (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO, &frame});
        int rendered = mpv_render_context_render(probe->render, parameters);
        if (info < 0 || rendered < 0) {
            atomic_store(&probe->render_error, info < 0 ? info : rendered);
            break;
        }
        if ((frame.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
            !(frame.flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT))) {
            atomic_fetch_add(&probe->frames, 1);
        }
    }
    free(buffer);
    return NULL;
}

static bool pump(Probe *probe, double seconds) {
    int64_t deadline = mpv_get_time_us(probe->core) + (int64_t)(seconds * 1000000);
    do {
        mpv_event *event;
        while ((event = mpv_wait_event(probe->core, 0))->event_id != MPV_EVENT_NONE) {
            if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
                mpv_event_log_message *log = event->data;
                fprintf(stderr, "[%s][%s] %s", log->prefix, log->level, log->text);
            } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
                probe->restarts++;
                probe->last_restart_us = mpv_get_time_us(probe->core);
            } else if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
                probe->last_reply_id = event->reply_userdata;
                probe->command_replies++;
                if (!check(event->error, "asynchronous command")) probe->command_errors++;
            }
        }
        if (!check(atomic_load(&probe->render_error), "render")) return false;
        usleep(5000);
    } while (mpv_get_time_us(probe->core) < deadline);
    return true;
}

static bool measure(Probe *probe, const char *file, const char *target, bool video) {
    return load_and_wait(probe, file, video) && measure_seek(probe, target);
}

static bool load_and_wait(Probe *probe, const char *file, bool video) {
    unsigned long frames = atomic_load(&probe->frames);
    probe->expected_file = file;
    const char *load[] = {"loadfile", file, "replace", NULL};
    if (!check(mpv_command(probe->core, load), "loadfile")) return false;
    int pause = 0;
    if (!check(mpv_set_property(probe->core, "pause", MPV_FORMAT_FLAG, &pause), "resume load")) return false;
    int64_t deadline = mpv_get_time_us(probe->core) + 10000000;
    double position = 0;
    bool matches = false;
    while (!matches || position <= 0.5 || (video && atomic_load(&probe->frames) <= frames + 1)) {
        if (mpv_get_time_us(probe->core) >= deadline) { fprintf(stderr, "Initial playback timed out\n"); return false; }
        if (!pump(probe, 0.005)) return false;
        position = 0;
        mpv_get_property(probe->core, "time-pos", MPV_FORMAT_DOUBLE, &position);
        char *path = mpv_get_property_string(probe->core, "path");
        matches = path && strcmp(path, file) == 0;
        mpv_free(path);
    }
    return true;
}

static bool measure_seek(Probe *probe, const char *target) {
    int pause = 1;
    if (!check(mpv_set_property(probe->core, "pause", MPV_FORMAT_FLAG, &pause), "pause")) return false;
    /** 先确认暂停并消耗在途帧，避免把定位前的最后一帧计成定位成功。 */
    if (!pump(probe, 0.15)) return false;
    snapshot(probe, "before");
    unsigned restarts = probe->restarts;
    int64_t began = mpv_get_time_us(probe->core);
    const char *seek[] = {"seek", target, "absolute+exact", NULL};
    if (!check(mpv_command(probe->core, seek), "seek")) return false;
    while (probe->restarts == restarts) {
        if (mpv_get_time_us(probe->core) - began > 10000000) { fprintf(stderr, "Seek restart timed out\n"); return false; }
        if (!pump(probe, 0.005)) return false;
    }
    printf("{\"stage\":\"restart\",\"elapsedMS\":%.3f}\n", (probe->last_restart_us - began) / 1000.0);
    if (!pump(probe, 0.15)) return false;
    snapshot(probe, "paused-seek");
    pause = 0;
    if (!check(mpv_set_property(probe->core, "pause", MPV_FORMAT_FLAG, &pause), "resume")) return false;
    if (!pump(probe, 1)) return false;
    snapshot(probe, "resumed");
    return true;
}

/** 固定的交错场景只属于诊断工具；输入是已核验、至少 6 秒的测试视频。 */
static bool exercise_lifecycle(Probe *probe, const char *file, const char *replacement) {
    if (!load_and_wait(probe, file, true)) return false;
    double duration = 0;
    if (!check(mpv_get_property(probe->core, "duration", MPV_FORMAT_DOUBLE, &duration), "duration") ||
        !isfinite(duration) || duration < 6) return false;
    const char *targets[] = {"3.75", "1.25", "4.25", "0.25"};
    for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        printf("{\"stage\":\"case\",\"name\":\"sequential-%zu\",\"target\":%s}\n", i, targets[i]);
        if (!measure_seek(probe, targets[i])) return false;
    }
    int pause = 1;
    if (!check(mpv_set_property(probe->core, "pause", MPV_FORMAT_FLAG, &pause), "pause burst")) return false;
    if (!pump(probe, 0.15)) return false;
    snapshot(probe, "burst-before");
    unsigned long baseline = atomic_load(&probe->frames);
    const char *burst_targets[] = {"1", "4", "2", "3"};
    for (unsigned i = 0; i < 100; i++) {
        const char *seek[] = {"seek", burst_targets[i % 4], "absolute+exact", NULL};
        if (!check(mpv_command_async(probe->core, 100 + i, seek), "queue seek")) return false;
    }
    int64_t deadline = mpv_get_time_us(probe->core) + 10000000;
    while (true) {
        if (!pump(probe, 0.005)) return false;
        int seeking = 1;
        double position = -1;
        mpv_get_property(probe->core, "seeking", MPV_FORMAT_FLAG, &seeking);
        mpv_get_property(probe->core, "time-pos", MPV_FORMAT_DOUBLE, &position);
        if (probe->last_reply_id == 199 && probe->command_replies == 100 && !seeking && fabs(position - 3) <= 0.2 &&
            atomic_load(&probe->frames) > baseline) break;
        if (mpv_get_time_us(probe->core) >= deadline) { fprintf(stderr, "Seek burst timed out\n"); return false; }
    }
    /** 保留一个稳定区间，防止短暂经过最终位置就误判旧命令已全部消退。 */
    if (!pump(probe, 0.3)) return false;
    snapshot(probe, "burst-paused");
    pause = 0;
    if (!check(mpv_set_property(probe->core, "pause", MPV_FORMAT_FLAG, &pause), "resume burst")) return false;
    if (!pump(probe, 1)) return false;
    snapshot(probe, "burst-resumed");

    /** 不等待定位完成就替换文件；只接受替换后的真实路径、位置与新帧。 */
    const char *seek[] = {"seek", "4.5", "absolute+exact", NULL};
    if (!check(mpv_command_async(probe->core, 1000, seek), "seek before replacement")) return false;
    if (!load_and_wait(probe, replacement, true)) return false;
    snapshot(probe, "replacement-playing");
    if (!pump(probe, 0.5)) return false;
    snapshot(probe, "replacement-stable");

    if (!check(mpv_command_async(probe->core, 2000, seek), "seek before stop")) return false;
    const char *stop[] = {"stop", NULL};
    if (!check(mpv_command(probe->core, stop), "stop pending seek")) return false;
    deadline = mpv_get_time_us(probe->core) + 10000000;
    while (true) {
        if (!pump(probe, 0.005)) return false;
        int idle = 0, video = 1;
        mpv_get_property(probe->core, "idle-active", MPV_FORMAT_FLAG, &idle);
        mpv_get_property(probe->core, "vo-configured", MPV_FORMAT_FLAG, &video);
        if (idle && !video) break;
        if (mpv_get_time_us(probe->core) >= deadline) { fprintf(stderr, "Stop timed out\n"); return false; }
    }
    if (!pump(probe, 0.3)) return false;
    snapshot(probe, "stopped");
    if (!pump(probe, 1)) return false;
    snapshot(probe, "quiet");
    return probe->command_errors == 0;
}

static bool queue_opening(Probe *probe, const char *file) {
    const char *load[] = {"loadfile", file, "replace", NULL};
    if (!check(mpv_command_async(probe->core, 1, load), "queue opening")) return false;
    /** 不等待 FILE_LOADED，直接进入正常关闭路径；不能宣称观察到了某个解码阶段。 */
    printf("{\"stage\":\"opening-queued\"}\n");
    return true;
}

static void snapshot(Probe *probe, const char *stage) {
    printf("{\"stage\":\"%s\",\"frames\":%lu", stage, atomic_load(&probe->frames));
    const char *numbers[] = {"time-pos", "audio-params/samplerate", "audio-out-params/samplerate"};
    for (size_t i = 0; i < sizeof(numbers) / sizeof(numbers[0]); i++) {
        double value;
        printf(",\"%s\":", numbers[i]);
        if (mpv_get_property(probe->core, numbers[i], MPV_FORMAT_DOUBLE, &value) >= 0 && isfinite(value)) printf("%.6f", value);
        else printf("null");
    }
    const char *flags[] = {"pause", "seeking", "eof-reached", "vo-configured", "idle-active"};
    for (size_t i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
        int value;
        printf(",\"%s\":", flags[i]);
        if (mpv_get_property(probe->core, flags[i], MPV_FORMAT_FLAG, &value) >= 0) printf("%s", value ? "true" : "false");
        else printf("null");
    }
    /** mpv 将这个 NODE 属性编码为 JSON；调用方按 JSON 解析，格式错误显式失败。 */
    char *cache = mpv_get_property_string(probe->core, "demuxer-cache-state");
    char *file = mpv_get_property_string(probe->core, "path");
    bool matches = file && probe->expected_file && strcmp(file, probe->expected_file) == 0;
    printf(",\"matchesFile\":%s,\"lastReplyID\":%llu,\"commandReplies\":%u,\"commandErrors\":%u,\"cache\":%s}\n",
           matches ? "true" : "false", (unsigned long long)probe->last_reply_id,
           probe->command_replies, probe->command_errors, cache ? cache : "null");
    mpv_free(file);
    mpv_free(cache);
    fflush(stdout);
}

static void close_probe(Probe *probe) {
    /** 保持渲染线程服务至 stop 返回，再移除回调、回收线程、释放 render context 和 core。 */
    if (probe->thread_started && atomic_load(&probe->render_error) >= 0) {
        const char *stop[] = {"stop", NULL};
        mpv_command(probe->core, stop);
    }
    if (probe->render) mpv_render_context_set_update_callback(probe->render, NULL, NULL);
    pthread_mutex_lock(&probe->mutex);
    probe->closing = true;
    pthread_cond_signal(&probe->condition);
    pthread_mutex_unlock(&probe->mutex);
    if (probe->thread_started) { pthread_join(probe->thread, NULL); probe->thread_started = false; }
    if (probe->render) { mpv_render_context_free(probe->render); probe->render = NULL; }
    if (probe->core) { mpv_terminate_destroy(probe->core); probe->core = NULL; }
    pthread_cond_destroy(&probe->condition);
    pthread_mutex_destroy(&probe->mutex);
}
