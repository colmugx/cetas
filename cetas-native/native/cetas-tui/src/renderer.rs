use crate::terminal::CetasTui;
use crate::{
    CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_MALFORMED_COMMAND, CTUI_STATUS_OK,
    CTUI_STATUS_TERMINAL_ERROR,
};
use ratatui::buffer::Buffer;
use ratatui::layout::{Position, Rect};
use ratatui::widgets::{Clear, Paragraph, Widget};
use std::slice;

const COMMAND_WORDS: usize = 8;

#[derive(Debug)]
enum DrawCommand<'a> {
    Text { area: Rect, text: &'a str },
    Clear { area: Rect },
    Cursor { x: u16, y: u16 },
}

fn bytes<'a>(ptr: *const u8, len: u32) -> Option<&'a [u8]> {
    if ptr.is_null() && len != 0 {
        return None;
    }
    Some(if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len as usize) }
    })
}

fn words<'a>(ptr: *const u32, len: u32) -> Option<&'a [u32]> {
    if ptr.is_null() && len != 0 {
        return None;
    }
    Some(if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len as usize) }
    })
}

fn rect(x: u32, y: u32, width: u32, height: u32) -> Option<Rect> {
    Some(Rect::new(
        u16::try_from(x).ok()?,
        u16::try_from(y).ok()?,
        u16::try_from(width).ok()?,
        u16::try_from(height).ok()?,
    ))
}

fn decode_commands<'a>(
    command_words: &'a [u32],
    text_bytes: &'a [u8],
) -> Result<Vec<DrawCommand<'a>>, i32> {
    if command_words.len() % COMMAND_WORDS != 0 {
        return Err(CTUI_STATUS_MALFORMED_COMMAND);
    }

    let mut out = Vec::with_capacity(command_words.len() / COMMAND_WORDS);

    for raw in command_words.chunks_exact(COMMAND_WORDS) {
        let kind = raw[0];
        let Some(area) = rect(raw[1], raw[2], raw[3], raw[4]) else {
            return Err(CTUI_STATUS_MALFORMED_COMMAND);
        };
        let text_offset = raw[5] as usize;
        let text_len = raw[6] as usize;
        let _flags = raw[7];

        match kind {
            1 => {
                let Some(end) = text_offset.checked_add(text_len) else {
                    return Err(CTUI_STATUS_MALFORMED_COMMAND);
                };
                let Some(raw_text) = text_bytes.get(text_offset..end) else {
                    return Err(CTUI_STATUS_MALFORMED_COMMAND);
                };
                let Ok(text) = std::str::from_utf8(raw_text) else {
                    return Err(CTUI_STATUS_MALFORMED_COMMAND);
                };
                out.push(DrawCommand::Text { area, text });
            }
            2 => out.push(DrawCommand::Clear { area }),
            3 => {
                let Ok(x) = u16::try_from(raw[1]) else {
                    return Err(CTUI_STATUS_MALFORMED_COMMAND);
                };
                let Ok(y) = u16::try_from(raw[2]) else {
                    return Err(CTUI_STATUS_MALFORMED_COMMAND);
                };
                out.push(DrawCommand::Cursor { x, y });
            }
            _ => return Err(CTUI_STATUS_MALFORMED_COMMAND),
        }
    }

    Ok(out)
}

fn render_to_buffer(buffer: &mut Buffer, commands: &[DrawCommand<'_>]) {
    for command in commands {
        match command {
            DrawCommand::Text { area, text } => {
                Paragraph::new(*text).render(*area, buffer);
            }
            DrawCommand::Clear { area } => {
                Clear.render(*area, buffer);
            }
            DrawCommand::Cursor { .. } => {}
        }
    }
}

#[no_mangle]
pub extern "C" fn ctui_headless_probe() -> u32 {
    let area = Rect::new(0, 0, 8, 1);
    let mut buffer = Buffer::empty(area);
    Paragraph::new("cetas").render(area, &mut buffer);
    u32::from(buffer[(0, 0)].symbol() == "c")
}

#[no_mangle]
pub extern "C" fn ctui_headless_batch_probe(
    command_words: *const u32,
    word_count: u32,
    text: *const u8,
    text_len: u32,
) -> u32 {
    let Some(command_words) = words(command_words, word_count) else {
        return 0;
    };
    let Some(text) = bytes(text, text_len) else {
        return 0;
    };
    let Ok(commands) = decode_commands(command_words, text) else {
        return 0;
    };

    let area = Rect::new(0, 0, 32, 4);
    let mut buffer = Buffer::empty(area);
    render_to_buffer(&mut buffer, &commands);

    u32::from(
        buffer[(0, 0)].symbol() == "c"
            && buffer[(1, 0)].symbol() == "e"
            && buffer[(2, 0)].symbol() == "t",
    )
}

#[no_mangle]
pub extern "C" fn ctui_render_text(
    tui: *mut CetasTui,
    text: *const u8,
    text_len: u32,
) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }
    let Some(text) = bytes(text, text_len) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let Ok(text) = std::str::from_utf8(text) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };

    let tui = unsafe { &mut *tui };
    match tui.terminal.draw(|frame| {
        frame.render_widget(Paragraph::new(text), frame.area());
    }) {
        Ok(_) => CTUI_STATUS_OK,
        Err(_) => CTUI_STATUS_TERMINAL_ERROR,
    }
}

#[no_mangle]
pub extern "C" fn ctui_render_batch(
    tui: *mut CetasTui,
    command_words: *const u32,
    word_count: u32,
    text: *const u8,
    text_len: u32,
) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }
    let Some(command_words) = words(command_words, word_count) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let Some(text) = bytes(text, text_len) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let commands = match decode_commands(command_words, text) {
        Ok(commands) => commands,
        Err(status) => return status,
    };

    let tui = unsafe { &mut *tui };
    match tui.terminal.draw(|frame| {
        for command in &commands {
            match command {
                DrawCommand::Text { area, text } => {
                    frame.render_widget(Paragraph::new(*text), *area);
                }
                DrawCommand::Clear { area } => {
                    frame.render_widget(Clear, *area);
                }
                DrawCommand::Cursor { x, y } => {
                    frame.set_cursor_position(Position::new(*x, *y));
                }
            }
        }
    }) {
        Ok(_) => CTUI_STATUS_OK,
        Err(_) => CTUI_STATUS_TERMINAL_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_partial_command() {
        let words = [1u32, 0, 0];
        assert_eq!(
            decode_commands(&words, b"cetas").unwrap_err(),
            CTUI_STATUS_MALFORMED_COMMAND
        );
    }

    #[test]
    fn renders_text_command() {
        let words = [1u32, 0, 0, 10, 1, 0, 5, 0];
        let commands = decode_commands(&words, b"cetas").unwrap();
        let mut buffer = Buffer::empty(Rect::new(0, 0, 10, 1));
        render_to_buffer(&mut buffer, &commands);
        assert_eq!(buffer[(0, 0)].symbol(), "c");
        assert_eq!(buffer[(4, 0)].symbol(), "s");
    }
}
