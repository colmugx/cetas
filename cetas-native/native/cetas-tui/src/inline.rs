use crate::terminal::CetasTui;
use ratatui::widgets::{Paragraph, Widget};
use ratatui::Viewport;
use std::slice;

fn utf8<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() && len != 0 {
        return None;
    }
    let bytes = if len == 0 { &[] } else { unsafe { slice::from_raw_parts(ptr, len) } };
    std::str::from_utf8(bytes).ok()
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
    text_len: usize,
) -> i32 {
    if tui.is_null() {
        return 0;
    }
    let Some(text) = utf8(text, text_len) else {
        return 0;
    };
    let tui = unsafe { &mut *tui };
    match tui.terminal.insert_before(1, |buffer| {
        Paragraph::new(text).render(buffer.area, buffer);
    }) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}
