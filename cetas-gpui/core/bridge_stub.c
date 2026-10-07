#include <moonbit.h>
#include <stdint.h>
#include <string.h>

extern int32_t cetas_gpui_command_len(void);
extern int32_t cetas_gpui_command_copy(uint8_t *out, int32_t cap);
extern void cetas_gpui_event_push(const uint8_t *data, int32_t len);

MOONBIT_FFI_EXPORT
moonbit_bytes_t cetas_gpui_bridge_next_command(void) {
  int32_t len = cetas_gpui_command_len();
  if (len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes(len, 0);
  int32_t copied = cetas_gpui_command_copy(out, len);
  if (copied < 0) copied = 0;
  return out;
}

MOONBIT_FFI_EXPORT
void cetas_gpui_bridge_emit(moonbit_bytes_t payload) {
  if (!payload) return;
  cetas_gpui_event_push(payload, (int32_t)strlen((const char *)payload));
}
