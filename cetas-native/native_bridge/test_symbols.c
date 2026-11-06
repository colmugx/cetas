/*
 * Link-only fail-closed fallback for MoonBit's stand-alone `moon test`.
 *
 * In the actual Go host go_bridge/host.c defines strong versions of these
 * symbols; those always override these weak fallback symbols. Keeping the
 * fallback in this foreign_library allows the ordinary repository MoonBit
 * test runner to link without invoking a Go host.
 *
 * If a build mistakenly calls the bridge without the strong Go-owned
 * transport, abort immediately rather than returning fake commands/events.
 */
#include <stdint.h>
#include <stdlib.h>

#if defined(__GNUC__) || defined(__clang__)
#define CETAS_TEST_FALLBACK __attribute__((weak))
#else
#error "standalone MoonBit bridge fallback needs weak symbols; unsupported compiler"
#endif

CETAS_TEST_FALLBACK int32_t cetas_bridge_publish(const uint8_t *frame, int32_t size) {
    (void)frame; (void)size;
    abort();
}
CETAS_TEST_FALLBACK int32_t cetas_bridge_next_command(void) {
    abort();
}
CETAS_TEST_FALLBACK int32_t cetas_bridge_next_harness(uint8_t *dst, int32_t capacity) {
    (void)dst; (void)capacity;
    abort();
}
