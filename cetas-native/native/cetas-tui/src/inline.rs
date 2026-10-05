use crate::terminal::CetasTui;
use crate::{
    CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_OK, CTUI_STATUS_TERMINAL_ERROR,
};
use ratatui::text::Text;
use ratatui::widgets::{Paragraph, Widget, Wrap};
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

fn paragraph_line_count(paragraph: &Paragraph<'_>, width: u16) -> Option<u16> {
    u16::try_from(paragraph.line_count(width.max(1)).max(1)).ok()
}

fn plain_paragraph(text: &str) -> Option<Paragraph<'_>> {
    // insert_before addresses its height with u16. Check physical lines first
    // because Paragraph::line_count intentionally saturates at the terminal
    // coordinate boundary for pathological inputs.
    if text.split('\n').count() > u16::MAX as usize {
        return None;
    }
    Some(Paragraph::new(text).wrap(Wrap { trim: false }))
}

fn markdown_text(markdown: &str) -> Text<'_> {
    tui_markdown::from_str(markdown)
}

fn insert_paragraph(tui: &mut CetasTui, paragraph: Paragraph<'_>) -> i32 {
    let width = match tui.terminal.size() {
        Ok(size) => size.width,
        Err(_) => return CTUI_STATUS_TERMINAL_ERROR,
    };
    let Some(height) = paragraph_line_count(&paragraph, width) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };

    match tui.terminal.insert_before(height, |buffer| {
        paragraph.render(buffer.area, buffer);
    }) {
        Ok(_) => CTUI_STATUS_OK,
        Err(_) => CTUI_STATUS_TERMINAL_ERROR,
    }
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
    let Some(paragraph) = plain_paragraph(text) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };

    let tui = unsafe { &mut *tui };
    if tui.suspended {
        return CTUI_STATUS_TERMINAL_ERROR;
    }
    insert_paragraph(tui, paragraph)
}

#[no_mangle]
pub extern "C" fn ctui_insert_before_markdown(
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

    let tui = unsafe { &mut *tui };
    if tui.suspended {
        return CTUI_STATUS_TERMINAL_ERROR;
    }
    let rendered = markdown_text(text);
    insert_paragraph(tui, Paragraph::new(rendered).wrap(Wrap { trim: false }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::buffer::Buffer;
    use ratatui::layout::Rect;
    use ratatui::style::Modifier;

    #[test]
    fn counts_wrapped_scrollback_lines() {
        let p = plain_paragraph("").unwrap();
        assert_eq!(paragraph_line_count(&p, 80), Some(1));
        let p = plain_paragraph("one").unwrap();
        assert_eq!(paragraph_line_count(&p, 80), Some(1));
        let p = plain_paragraph("one\ntwo").unwrap();
        assert_eq!(paragraph_line_count(&p, 80), Some(2));
        let p = plain_paragraph("1234567890").unwrap();
        assert_eq!(paragraph_line_count(&p, 5), Some(2));
        let p = plain_paragraph("界界").unwrap();
        assert_eq!(paragraph_line_count(&p, 2), Some(2));
    }

    #[test]
    fn rejects_more_lines_than_insert_before_can_address() {
        let text = "\n".repeat(u16::MAX as usize);
        assert!(plain_paragraph(&text).is_none());
    }

    #[test]
    fn markdown_renderer_preserves_semantic_style() {
        let rendered = markdown_text("**bold**");
        let paragraph = Paragraph::new(rendered);
        let mut buffer = Buffer::empty(Rect::new(0, 0, 10, 1));
        paragraph.render(buffer.area, &mut buffer);
        assert_eq!(buffer[(0, 0)].symbol(), "b");
        assert!(buffer[(0, 0)].modifier.contains(Modifier::BOLD));
    }
}
