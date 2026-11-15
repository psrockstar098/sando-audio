/* sando_audio.h — C API for SANDO Audio (Phase 5).
 *
 * Link against libsando.a plus libaudiocpp.so (when the audio.cpp
 * backend is present) and libc:
 *
 *   cc main.c -I. -L<repo>/zig-out/lib -lsando \
 *      -L<repo>/third-party/audiocpp/lib -laudiocpp -lm
 *
 * Ownership: strings marked "owned" must be freed with
 * sando_free_string(). Strings marked "static" must NOT be freed.
 * A NULL return means failure — see sando_last_error().
 *
 * No real person's voice is ever enrolled through this API: voices
 * are synthetic profiles only (see docs/API.md).
 */
#ifndef SANDO_AUDIO_H
#define SANDO_AUDIO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sando_engine sando_engine_t;
typedef struct sando_stream sando_stream_t;
typedef struct sando_conversation sando_conversation_t;

/* Brain callback for sando_conversation_create_agent(). Return an
 * owned reply string (freed by the engine with sando_free_string),
 * or NULL on failure. `prompt` is the conversation prompt. */
typedef char *(*sando_agent_reply_fn)(void *ctx, const char *prompt);

/* Human-readable detail for the most recent failure, or "no error".
 * Static string. */
const char *sando_last_error(void);

/* Library version, e.g. "0.5.0". Static string. */
const char *sando_version(void);

/* Start an engine from a config file (config/sando.example.toml is
 * the template). NULL config_path uses the default path. NULL on
 * failure. Destroy with sando_engine_destroy(). */
sando_engine_t *sando_engine_create(const char *config_path);
void sando_engine_destroy(sando_engine_t *e);

/* Backend name ("cpu", "vulkan", ...) or "none". Static string. */
const char *sando_engine_backend(sando_engine_t *e);
/* 1 when audio.cpp is linked, 0 otherwise. */
int sando_engine_linked(sando_engine_t *e);
/* Number of task kinds the runtime knows ("asr", "tts", "vad", ...). */
size_t sando_engine_task_count(sando_engine_t *e);
/* Task name at `index`, or NULL when out of range. Static string. */
const char *sando_engine_task_name(sando_engine_t *e, size_t index);
/* Load a model file into the engine. `kind` is "stt", "tts" or "vad".
 * Returns 0 on success, -1 on failure. */
int sando_engine_load_model(sando_engine_t *e, const char *name,
                            const char *kind, const char *path);

/* Validate a config file without starting an engine.
 * Returns 0 when it parses and validates, -1 otherwise. */
int sando_config_validate(const char *path);

/* Free a string returned as "owned" by any sando_* function. */
void sando_free_string(char *s);

/* Run text inference (ASR) over a WAV file with a loaded model.
 * `task` is "asr" (others return an error). Owned result (the
 * transcript), or NULL on failure. */
char *sando_engine_infer_text(sando_engine_t *e, const char *model_name,
                              const char *task, const char *wav_path);
/* Run TTS and write a WAV file. `language` may be NULL (default
 * "en"). Returns 0 on success, -1 on failure. Honest gap: on a
 * small machine the 2 GB Qwen3-TTS model does not fit in RAM and
 * this fails rather than pretending to speak. */
int sando_engine_infer_tts(sando_engine_t *e, const char *model_name,
                           const char *text, const char *language,
                           const char *wav_out_path);

/* Streaming inference. Create with a loaded model + task ("asr"),
 * push f32 samples (frames * channels), finish for the final text.
 * push returns the latest partial transcript (owned) or NULL when
 * there is nothing new; finish returns the final text (owned). */
sando_stream_t *sando_stream_create(sando_engine_t *e,
                                    const char *model_name,
                                    const char *task);
void sando_stream_destroy(sando_stream_t *s);
char *sando_stream_push(sando_stream_t *s, const float *samples,
                        size_t frames, unsigned sample_rate,
                        unsigned char channels);
char *sando_stream_finish(sando_stream_t *s);

/* Conversation with the scripted mock brain (no network, no keys).
 * `voice`/`language` may be NULL for the defaults ("v1"/"en-lr").
 * The engine must not be NULL — it provides the I/O runtime (the
 * mock brain itself needs no model and makes no calls). */
sando_conversation_t *sando_conversation_create_mock(
    sando_engine_t *e, const char *voice, const char *language);
/* Conversation whose brain is a host callback. `cb` must not be NULL. */
sando_conversation_t *sando_conversation_create_agent(
    sando_engine_t *e, void *ctx, sando_agent_reply_fn cb,
    const char *voice, const char *language);
/* Ask one text turn; returns the reply (owned) or NULL on failure. */
char *sando_conversation_ask(sando_conversation_t *c, const char *text);
/* Number of turns in the conversation history so far. */
size_t sando_conversation_history_count(sando_conversation_t *c);
void sando_conversation_destroy(sando_conversation_t *c);

/* Language registry (11 languages: Liberian English + Koloqua +
 * 9 more Liberian languages). */
size_t sando_language_count(void);
/* Language code at `index` ("en-lr", "kq", ...), or NULL when out
 * of range. Static string. */
const char *sando_language_code(size_t index);
/* Display name for a code ("kq" -> "Koloqua"), or NULL when the code
 * is not registered. Static string. */
const char *sando_language_name(const char *code);
/* Identify the language of `text`; returns the code ("kq",
 * "en-lr", "und", ...). Owned — free with sando_free_string.
 * NULL only on allocation failure. */
char *sando_language_identify(const char *text);

#ifdef __cplusplus
}
#endif

#endif /* SANDO_AUDIO_H */
