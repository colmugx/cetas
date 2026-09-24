#ifndef CETAS_TUI_H
#define CETAS_TUI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CETAS_TUI_ABI_VERSION 2u
#define CETAS_TUI_COMMAND_WORDS 8u
#define CETAS_TUI_STYLE_WORDS 4u
#define CETAS_TUI_EVENT_WORDS 14u
#define CETAS_TUI_VIEWPORT_WORDS 2u

typedef struct CetasTui CetasTui;

enum CetasTuiStatus {
  CETAS_TUI_STATUS_OK = 0,
  CETAS_TUI_STATUS_TIMEOUT = 1,
  CETAS_TUI_STATUS_INVALID_ARGUMENT = 2,
  CETAS_TUI_STATUS_TERMINAL_ERROR = 3,
  CETAS_TUI_STATUS_BUFFER_TOO_SMALL = 4,
  CETAS_TUI_STATUS_MALFORMED_COMMAND = 5
};

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

enum CetasTuiCommandKind {
  CETAS_TUI_COMMAND_TEXT = 1,
  CETAS_TUI_COMMAND_CLEAR = 2,
  CETAS_TUI_COMMAND_CURSOR = 3
};

typedef struct CetasTuiEvent {
  uint32_t abi_version;
  uint32_t struct_size;
  uint32_t kind;
  uint32_t key_code;
  uint32_t codepoint;
  uint32_t modifiers;
  uint32_t key_action;
  uint32_t width;
  uint32_t height;
  uint32_t mouse_x;
  uint32_t mouse_y;
  uint32_t mouse_kind;
  uint32_t mouse_button;
  uint32_t text_len;
} CetasTuiEvent;

uint32_t ctui_abi_version(void);
uint32_t ctui_headless_probe(void);
uint32_t ctui_headless_batch_probe(
    const uint32_t *words,
    uint32_t word_count,
    const uint8_t *text,
    uint32_t text_len);

uint32_t ctui_headless_scene_probe(
    const uint32_t *command_words,
    uint32_t command_word_count,
    const uint32_t *style_words,
    uint32_t style_word_count,
    const uint8_t *text,
    uint32_t text_len);
uint32_t ctui_inline_probe(uint32_t rows);
uint32_t ctui_event_size(void);
uint32_t ctui_tty_probe(void);

CetasTui *ctui_open_inline(uint32_t rows);
uint32_t ctui_is_null(const CetasTui *tui);
void ctui_close(CetasTui *tui);

int32_t ctui_viewport_size(
    CetasTui *tui,
    uint32_t *out_words,
    uint32_t capacity);

int32_t ctui_render_text(
    CetasTui *tui,
    const uint8_t *text,
    uint32_t text_len);

int32_t ctui_render_batch(
    CetasTui *tui,
    const uint32_t *words,
    uint32_t word_count,
    const uint8_t *text,
    uint32_t text_len);

int32_t ctui_render_scene(
    CetasTui *tui,
    const uint32_t *command_words,
    uint32_t command_word_count,
    const uint32_t *style_words,
    uint32_t style_word_count,
    const uint8_t *text,
    uint32_t text_len);

int32_t ctui_insert_before_text(
    CetasTui *tui,
    const uint8_t *text,
    uint32_t text_len);

int32_t ctui_poll(
    CetasTui *tui,
    uint64_t timeout_ms,
    CetasTuiEvent *out_event);

int32_t ctui_poll_words(
    CetasTui *tui,
    uint64_t timeout_ms,
    uint32_t *out_words,
    uint32_t capacity);

uint32_t ctui_event_text_len(const CetasTui *tui);

int32_t ctui_event_text_copy(
    const CetasTui *tui,
    uint8_t *out,
    uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif
