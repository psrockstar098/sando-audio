// sando-plugin-noop: a passthrough plugin proving the loader works.
// It changes nothing — process returns 0 having touched no samples.
// Layout must match PluginDescriptor in src/plugin.zig exactly:
//   u32 api_version, const char *name, *version, *kind,
//   int (*init)(void), void (*deinit)(void),
//   int (*process_f32)(float *, size_t, unsigned, unsigned).
#include <stddef.h>
#include <stdint.h>

static int noop_init(void) { return 0; }
static void noop_deinit(void) {}

static int noop_process(float *samples, size_t frames, unsigned sample_rate, unsigned channels) {
    (void)samples;
    (void)frames;
    (void)sample_rate;
    (void)channels;
    return 0;
}

struct sando_plugin_descriptor {
    uint32_t api_version;
    const char *name;
    const char *version;
    const char *kind;
    int (*init)(void);
    void (*deinit)(void);
    int (*process_f32)(float *samples, size_t frames, unsigned sample_rate, unsigned channels);
};

struct sando_plugin_descriptor sando_plugin = {
    .api_version = 1,
    .name = "noop",
    .version = "0.1.0",
    .kind = "effect",
    .init = noop_init,
    .deinit = noop_deinit,
    .process_f32 = noop_process,
};
