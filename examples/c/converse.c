/* converse.c — minimal C example for the SANDO Audio C API.
 *
 * Prints the library version, identifies a Koloqua sentence, then
 * holds a two-turn mock-brain conversation. No model weights, no
 * network, no keys — the mock brain answers locally.
 *
 * Build (from the repo root):
 *   cc examples/c/converse.c -I sdk/c -o /tmp/sando-converse \
 *      zig-out/lib/libsando.a \
 *      -L third-party/audiocpp/lib -laudiocpp \
 *      -Wl,-rpath,$PWD/third-party/audiocpp/lib -lm
 * Run:
 *   /tmp/sando-converse
 */
#include <stdio.h>
#include <stdlib.h>

#include "sando_audio.h"

int main(void) {
    printf("sando-audio %s\n", sando_version());

    /* Language registry: 11 languages. */
    size_t n = sando_language_count();
    printf("languages: %zu\n", n);
    for (size_t i = 0; i < n; i++) {
        const char *code = sando_language_code(i);
        printf("  %s — %s\n", code, sando_language_name(code));
    }

    /* Identify a Koloqua sentence (marker-based, no model). */
    char *lang = sando_language_identify("They fini fool we pekin them.");
    if (lang == NULL) {
        fprintf(stderr, "identify failed: %s\n", sando_last_error());
        return 1;
    }
    printf("identify: \"%s\"\n", lang);
    sando_free_string(lang);

    /* Mock-brain conversation. The engine is required — it provides
     * the I/O runtime — but the mock brain itself makes no network
     * calls and needs no keys. Run this example from the repo root
     * so the default config (config/sando.toml) is found. */
    sando_engine_t *e = sando_engine_create(NULL);
    if (e == NULL) {
        fprintf(stderr, "engine failed: %s\n", sando_last_error());
        fprintf(stderr, "run from the repo root (config/sando.toml must exist)\n");
        return 1;
    }
    printf("backend: %s (linked: %d)\n", sando_engine_backend(e),
           sando_engine_linked(e));
    sando_conversation_t *c =
        sando_conversation_create_mock(e, "v1", "en-lr");
    if (c == NULL) {
        fprintf(stderr, "conversation failed: %s\n", sando_last_error());
        sando_engine_destroy(e);
        return 1;
    }
    const char *turns[] = { "hello", "tell me a joke" };
    for (size_t i = 0; i < 2; i++) {
        char *reply = sando_conversation_ask(c, turns[i]);
        if (reply == NULL) {
            fprintf(stderr, "ask failed: %s\n", sando_last_error());
            sando_conversation_destroy(c);
            sando_engine_destroy(e);
            return 1;
        }
        printf("you: %s\nsando: %s\n", turns[i], reply);
        sando_free_string(reply);
    }
    printf("history turns: %zu\n", sando_conversation_history_count(c));
    sando_conversation_destroy(c);
    sando_engine_destroy(e);
    return 0;
}
