use crate::terminal::CetasTui;
use crate::{
    CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_OK, CTUI_STATUS_TERMINAL_ERROR,
};
use ratatui::widgets::{Paragraph, Widget};
use ratatui::Viewport;
use std::slice;

fn utf8<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() && len != 0 {
        return None;
    }
    let bytes = if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    };
    std::str::from_utf8(bytes).ok()
}

fn explicit_line_count(text: &str) -> Option<u16> {
    u16::try_from(text.split('\n').count()).ok()
}

#[no_mangle]
pub extern "C" fn ctui_inline_probe(rows: u32) -> u32 {
    let rows = rows.clamp(1, u16::MAX as u32) as u16;
    match Viewport::Inline(rows) {
        Viewport::Inline(value) if value == rows => 1,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn ctui_insert_before_text(
    tui: *mut CetasTui,
    text: *const u8,
    text_len: u32,
) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }
    let Some(text) = utf8(text, text_len as usize) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let Some(height) = explicit_line_count(text) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };

    let tui = unsafe { &mut *tui };
    if tui.suspended {
        return CTUI_STATUS_TERMINAL_ERROR;
    }

    match tui.terminal.insert_before(height, |buffer| {
        Paragraph::new(text).render(buffer.area, buffer);
    }) {
        Ok(_) => CTUI_STATUS_OK,
        Err(_) => CTUI_STATUS_TERMINAL_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_explicit_scrollback_lines() {
        assert_eq!(explicit_line_count(""), Some(1));
        assert_eq!(explicit_line_count("one"), Some(1));
        assert_eq!(explicit_line_count("one\ntwo"), Some(2));
        assert_eq!(explicit_line_count("one\ntwo\n"), Some(3));
        assert_eq!(explicit_line_count("界\nx"), Some(2));
    }

    #[test]
    fn rejects_more_lines_than_insert_before_can_address() {
        let text = "\n".repeat(u16::MAX as usize);
        assert_eq!(explicit_line_count(&text), None);
    }
}
