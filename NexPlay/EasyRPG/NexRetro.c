// NexRetro.c: see NexRetro.h. The libretro types and constants below follow libretro.h (MIT,
// Copyright (C) 2010-2024 The RetroArch team), declared here so no header has to be vendored.

#include "NexRetro.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - libretro types

struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
struct retro_system_info { const char *library_name; const char *library_version; const char *valid_extensions;
                           bool need_fullpath; bool block_extract; };
struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct retro_system_timing { double fps; double sample_rate; };
struct retro_system_av_info { struct retro_game_geometry geometry; struct retro_system_timing timing; };
enum retro_log_level { RETRO_LOG_DEBUG = 0, RETRO_LOG_INFO, RETRO_LOG_WARN, RETRO_LOG_ERROR };
typedef void (*retro_log_printf_t)(enum retro_log_level level, const char *fmt, ...);
struct retro_log_callback { retro_log_printf_t log; };

typedef bool (*retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

#define RETRO_ENVIRONMENT_GET_CAN_DUPE 3
#define RETRO_ENVIRONMENT_SET_MESSAGE 6
#define RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL 8
#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS 11
#define RETRO_ENVIRONMENT_GET_VARIABLE 15
#define RETRO_ENVIRONMENT_SET_VARIABLES 16
#define RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE 17
#define RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME 18
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27
#define RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY 30
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31
#define RETRO_ENVIRONMENT_SET_CONTROLLER_INFO 35
#define RETRO_ENVIRONMENT_SET_GEOMETRY 37
#define RETRO_ENVIRONMENT_GET_LANGUAGE 39
#define RETRO_ENVIRONMENT_GET_INPUT_BITMASKS (51 | 0x10000)
#define RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION 52
#define RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO 32
#define RETRO_DEVICE_JOYPAD 1
#define RETRO_DEVICE_ID_JOYPAD_MASK 256
#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565 2

// MARK: - State

static void *core;
static void (*p_set_environment)(retro_environment_t);
static void (*p_set_video_refresh)(retro_video_refresh_t);
static void (*p_set_audio_sample)(retro_audio_sample_t);
static void (*p_set_audio_sample_batch)(retro_audio_sample_batch_t);
static void (*p_set_input_poll)(retro_input_poll_t);
static void (*p_set_input_state)(retro_input_state_t);
static void (*p_init)(void);
static void (*p_deinit)(void);
static void (*p_get_system_info)(struct retro_system_info *);
static void (*p_get_system_av_info)(struct retro_system_av_info *);
static bool (*p_load_game)(const struct retro_game_info *);
static void (*p_unload_game)(void);
static void (*p_run)(void);
static void (*p_reset)(void);

static char system_dir[1024];
static char save_dir[1024];
static char core_name[256];
static int pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static double fps = 60.0;
static double sample_rate = 44100.0;
static bool loaded;

static pthread_mutex_t frame_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t *frame;
static size_t frame_capacity;
static unsigned frame_width, frame_height;
static bool frame_new;

#define AUDIO_FRAMES 32768
static pthread_mutex_t audio_lock = PTHREAD_MUTEX_INITIALIZER;
static int16_t audio_ring[AUDIO_FRAMES * 2];
static size_t audio_read_at, audio_count;

static volatile int16_t buttons[16];

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static char log_text[4096];

// MARK: - Callbacks

static void add_log(const char *line) {
    pthread_mutex_lock(&log_lock);
    size_t have = strlen(log_text), add = strlen(line);
    if (add >= sizeof(log_text) - 1) { line += add - (sizeof(log_text) / 2); add = strlen(line); }
    if (have + add + 1 >= sizeof(log_text)) {
        size_t drop = have + add + 1 - sizeof(log_text) + 512;
        if (drop > have) drop = have;
        memmove(log_text, log_text + drop, have - drop + 1);
        have -= drop;
    }
    memcpy(log_text + have, line, add + 1);
    pthread_mutex_unlock(&log_lock);
}

static void core_log(enum retro_log_level level, const char *fmt, ...) {
    char line[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (level >= RETRO_LOG_INFO) add_log(line);
    fprintf(stderr, "[easyrpg] %s", line);
}

static bool environment(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        if (data) *(bool *)data = true;
        return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
        if (data) *(const char **)data = system_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        if (data) *(const char **)data = save_dir;
        return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        if (!data) return false;
        int format = *(const int *)data;
        if (format != RETRO_PIXEL_FORMAT_XRGB8888 && format != RETRO_PIXEL_FORMAT_RGB565 && format != RETRO_PIXEL_FORMAT_0RGB1555) return false;
        pixel_format = format;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        if (!data) return false;
        ((struct retro_log_callback *)data)->log = core_log;
        return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        if (!data) return false;
        const struct retro_system_av_info *info = data;
        if (info->timing.fps > 1) fps = info->timing.fps;
        if (info->timing.sample_rate > 1000) sample_rate = info->timing.sample_rate;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_VARIABLES:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        if (data) *(bool *)data = false;
        return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
        if (data) *(unsigned *)data = 0;   // English
        return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
        if (data) *(unsigned *)data = 0;   // options through SET_VARIABLES (defaults are used)
        return true;
    default:
        return false;   // GET_VARIABLE and everything else: the core's defaults
    }
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data || width == 0 || height == 0) return;   // a duplicated frame: keep the last one
    pthread_mutex_lock(&frame_lock);
    size_t need = (size_t)width * height;
    if (need > frame_capacity) {
        uint32_t *grown = realloc(frame, need * sizeof(uint32_t));
        if (!grown) { pthread_mutex_unlock(&frame_lock); return; }
        frame = grown;
        frame_capacity = need;
    }
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = (const uint8_t *)data + (size_t)y * pitch;
        uint32_t *out = frame + (size_t)y * width;
        if (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
            memcpy(out, row, (size_t)width * 4);
        } else {
            const uint16_t *pixels = (const uint16_t *)row;
            for (unsigned x = 0; x < width; x++) {
                uint16_t p = pixels[x];
                uint32_t r, g, b;
                if (pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
                    r = (p >> 11) & 0x1f; g = (p >> 5) & 0x3f; b = p & 0x1f;
                    r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
                } else {
                    r = (p >> 10) & 0x1f; g = (p >> 5) & 0x1f; b = p & 0x1f;
                    r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
                }
                out[x] = 0xff000000u | (r << 16) | (g << 8) | b;
            }
        }
    }
    frame_width = width;
    frame_height = height;
    frame_new = true;
    pthread_mutex_unlock(&frame_lock);
}

static size_t audio_batch(const int16_t *data, size_t frames) {
    pthread_mutex_lock(&audio_lock);
    for (size_t i = 0; i < frames; i++) {
        if (audio_count == AUDIO_FRAMES) {   // full: drop the oldest frame
            audio_read_at = (audio_read_at + 1) % AUDIO_FRAMES;
            audio_count--;
        }
        size_t at = (audio_read_at + audio_count) % AUDIO_FRAMES;
        audio_ring[at * 2] = data[i * 2];
        audio_ring[at * 2 + 1] = data[i * 2 + 1];
        audio_count++;
    }
    pthread_mutex_unlock(&audio_lock);
    return frames;
}

static void audio_sample(int16_t left, int16_t right) {
    int16_t pair[2] = { left, right };
    audio_batch(pair, 1);
}

static void input_poll(void) {}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    if (port != 0 || (device & 0xff) != RETRO_DEVICE_JOYPAD) return 0;
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
        int16_t mask = 0;
        for (unsigned i = 0; i < 16; i++) if (buttons[i]) mask |= (int16_t)(1 << i);
        return mask;
    }
    return id < 16 ? buttons[id] : 0;
}

// MARK: - API

#define LOAD(name, symbol) do { *(void **)(&name) = dlsym(core, symbol); if (!name) { \
    snprintf(error, error_size, "The EasyRPG core has no %s.", symbol); dlclose(core); core = NULL; return false; } } while (0)

bool nexretro_open(const char *core_path, char *error, size_t error_size) {
    if (core) return true;
    core = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!core) {
        const char *why = dlerror();
        snprintf(error, error_size, "The EasyRPG core didn't load: %s", why ? why : "unknown error");
        return false;
    }
    LOAD(p_set_environment, "retro_set_environment");
    LOAD(p_set_video_refresh, "retro_set_video_refresh");
    LOAD(p_set_audio_sample, "retro_set_audio_sample");
    LOAD(p_set_audio_sample_batch, "retro_set_audio_sample_batch");
    LOAD(p_set_input_poll, "retro_set_input_poll");
    LOAD(p_set_input_state, "retro_set_input_state");
    LOAD(p_init, "retro_init");
    LOAD(p_deinit, "retro_deinit");
    LOAD(p_get_system_info, "retro_get_system_info");
    LOAD(p_get_system_av_info, "retro_get_system_av_info");
    LOAD(p_load_game, "retro_load_game");
    LOAD(p_unload_game, "retro_unload_game");
    LOAD(p_run, "retro_run");
    LOAD(p_reset, "retro_reset");
    struct retro_system_info info;
    memset(&info, 0, sizeof(info));
    p_get_system_info(&info);
    snprintf(core_name, sizeof(core_name), "%s %s", info.library_name ? info.library_name : "EasyRPG",
             info.library_version ? info.library_version : "");
    return true;
}

bool nexretro_load_game(const char *game_path, const char *system, const char *saves, char *error, size_t error_size) {
    if (!core) { snprintf(error, error_size, "The EasyRPG core isn't open."); return false; }
    if (loaded) nexretro_unload();
    snprintf(system_dir, sizeof(system_dir), "%s", system);
    snprintf(save_dir, sizeof(save_dir), "%s", saves);
    pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
    pthread_mutex_lock(&log_lock); log_text[0] = 0; pthread_mutex_unlock(&log_lock);
    pthread_mutex_lock(&audio_lock); audio_read_at = 0; audio_count = 0; pthread_mutex_unlock(&audio_lock);
    for (unsigned i = 0; i < 16; i++) buttons[i] = 0;
    p_set_environment(environment);
    p_init();
    p_set_video_refresh(video_refresh);
    p_set_audio_sample(audio_sample);
    p_set_audio_sample_batch(audio_batch);
    p_set_input_poll(input_poll);
    p_set_input_state(input_state);
    struct retro_game_info game = { game_path, NULL, 0, NULL };
    if (!p_load_game(&game)) {
        snprintf(error, error_size, "EasyRPG couldn't open this game. %s", nexretro_last_log());
        p_deinit();
        return false;
    }
    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    p_get_system_av_info(&av);
    fps = av.timing.fps > 1 ? av.timing.fps : 60.0;
    sample_rate = av.timing.sample_rate > 1000 ? av.timing.sample_rate : 44100.0;
    loaded = true;
    return true;
}

void nexretro_run(void) { if (loaded) p_run(); }
void nexretro_reset(void) { if (loaded) p_reset(); }

void nexretro_unload(void) {
    if (!loaded) return;
    loaded = false;
    p_unload_game();
    p_deinit();
}

double nexretro_fps(void) { return fps; }
double nexretro_sample_rate(void) { return sample_rate; }
const char *nexretro_core_name(void) { return core_name; }

bool nexretro_copy_frame(uint32_t *out, size_t capacity_pixels, unsigned *width, unsigned *height) {
    pthread_mutex_lock(&frame_lock);
    *width = frame_width;
    *height = frame_height;
    bool copied = false;
    size_t need = (size_t)frame_width * frame_height;
    if (frame_new && frame && need > 0 && need <= capacity_pixels) {
        memcpy(out, frame, need * sizeof(uint32_t));
        frame_new = false;
        copied = true;
    }
    pthread_mutex_unlock(&frame_lock);
    return copied;
}

size_t nexretro_read_audio(int16_t *out, size_t frames) {
    pthread_mutex_lock(&audio_lock);
    // Keep latency low: when far more is queued than asked for, skip the oldest audio.
    if (audio_count > frames + 6144) {
        size_t skip = audio_count - frames - 3072;
        audio_read_at = (audio_read_at + skip) % AUDIO_FRAMES;
        audio_count -= skip;
    }
    size_t n = frames < audio_count ? frames : audio_count;
    for (size_t i = 0; i < n; i++) {
        size_t at = (audio_read_at + i) % AUDIO_FRAMES;
        out[i * 2] = audio_ring[at * 2];
        out[i * 2 + 1] = audio_ring[at * 2 + 1];
    }
    audio_read_at = (audio_read_at + n) % AUDIO_FRAMES;
    audio_count -= n;
    pthread_mutex_unlock(&audio_lock);
    return n;
}

void nexretro_set_button(unsigned id, bool pressed) {
    if (id < 16) buttons[id] = pressed ? 1 : 0;
}

const char *nexretro_last_log(void) { return log_text; }
