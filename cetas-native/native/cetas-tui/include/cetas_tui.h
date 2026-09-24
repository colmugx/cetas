#ifndef CETAS_TUI_H
#define CETAS_TUI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CetasTui CetasTui;

enum CetasTuiEventKind {
  CETAS_TUI_EVENT_NONE = 0,
  CETAS_TUI_EVENT_KEY = 1,
  CETAS_TUI_EVENT_RESIZE = 2,
  CETAS_TUI_EVENT_MOUSE = 3,
  CETAS_TUI_EVENT_PASTE = 4,
  CETAS_TUI_EVENT_FOCUS_IN = 5,
  CETAS_TUI_EVENT_FOCUS_OUT = 6
};

enum CetasTuiKeyAction {
  CETAS_TUI_KEY_PRESS = 1,
  CETAS_TUI_KEY_REPEAT = 2,
  CETAS_TUI_KEY_RELEASE = 3
};

typedef struct CetasTuiEvent {
  uint32_t kind;
  uint32_t key_code;
  uint32_t codepoint;
  uint32_t modifiers;
  uint32_t key_action;
  uint16_t width;
  uint16_t height;
  uint16_t mouse_x;
  uint16_t mouse_y;
  uint32_t mouse_kind;
  uint32_t mouse_button;
  size_t text_len;
} CetasTuiEvent;

uint32_t ctui_abi_version(void);
uint32_t ctui_headless_probe(void);
uint32_t ctui_inline_probe(uint32_t rows);
uint32_t ctui_event_size(void);
uint32_t ctui_tty_probe(void);

CetasTui *ctui_open_inline(uint16_t rows);
void ctui_close(CetasTui *tui);
int32_t ctui_render_text(CetasTui *tui, const uint8_t *text, size_t text_len);
int32_t ctui_insert_before_text(CetasTui *tui, const uint8_t *text, size_t text_len);
int32_t ctui_poll(uint64_t timeout_ms, CetasTuiEvent *out_event);

#ifdef __cplusplus
}
#endif

#endif
