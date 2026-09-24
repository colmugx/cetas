use crate::terminal::CetasTui;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Widget};
use std::slice;

fn utf8<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() && len != 0 {
        return None;
    }
    let bytes = if len == 0 { &[] } else { unsafe { slice::from_raw_parts(ptr, len) } };
    std::str::from_utf8(bytes).ok()
}

#[no_mangle]
pub extern "C" fn ctui_headless_probe() -> u32 {
    let area = Rect::new(0, 0, 8, 1);
    let mut buffer = Buffer::empty(area);
    Paragraph::new("cetas").render(area, &mut buffer);
    u32::from(buffer[(0, 0)].symbol() == "c")
}

#[no_mangle]
pub extern "C" fn ctui_render_text(tui: *mut CetasTui, text: *const u8, text_len: usize) -> i32 {
    if tui.is_null() {
        return 0;
    }
    let Some(text) = utf8(text, text_len) else {
        return 0;
    };
    let tui = unsafe { &mut *tui };
    match tui.terminal.draw(|frame| {
        frame.render_widget(Paragraph::new(text), frame.area());
    }) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}
