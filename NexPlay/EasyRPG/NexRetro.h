// NexRetro.h: a minimal libretro frontend in C (7.1.1), used for EasyRPG Player's libretro core (RPG Maker 2000/2003).
// The core is loaded with dlopen from Frameworks/EasyRPGCore.framework. Video frames are kept as XRGB8888, audio in a
// ring buffer, joypad buttons in an array the Swift side sets. Not thread safe beyond: one thread runs the core
// (load, run, unload), any thread reads frames and audio and sets buttons.
// libretro API: https://github.com/libretro/libretro-common (MIT). EasyRPG Player: https://easyrpg.org (GPL-3.0).

#ifndef NEXRETRO_H
#define NEXRETRO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Opens the core. Returns false with a message in `error`.
bool nexretro_open(const char *core_path, char *error, size_t error_size);
/// retro_init + retro_load_game with the game's path. System and save folders are passed to the core.
bool nexretro_load_game(const char *game_path, const char *system_dir, const char *save_dir, char *error, size_t error_size);
/// One frame of the core.
void nexretro_run(void);
void nexretro_reset(void);
/// retro_unload_game + retro_deinit (the core stays open for the next game).
void nexretro_unload(void);

double nexretro_fps(void);
double nexretro_sample_rate(void);
/// The core's name and version ("EasyRPG Player 0.8.1").
const char *nexretro_core_name(void);

/// Copies the newest frame (XRGB8888, tightly packed) into `out` when it has room. Returns false when there is no new
/// frame since the last copy or `out` is too small; `width`/`height` are always set to the frame size.
bool nexretro_copy_frame(uint32_t *out, size_t capacity_pixels, unsigned *width, unsigned *height);

/// Reads up to `frames` stereo frames (interleaved int16). Returns how many were read.
size_t nexretro_read_audio(int16_t *out, size_t frames);

/// RETRO_DEVICE_ID_JOYPAD_* (0 B, 1 Y, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right, 8 A, 9 X, 10 L, 11 R).
void nexretro_set_button(unsigned id, bool pressed);

/// The last lines the core logged, newest last (for NexPlay's log on errors).
const char *nexretro_last_log(void);

#endif
