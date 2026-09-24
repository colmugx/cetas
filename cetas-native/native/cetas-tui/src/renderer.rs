use crate::terminal::CetasTui;
use crate::{
    CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_MALFORMED_COMMAND, CTUI_STATUS_OK,
    CTUI_STATUS_TERMINAL_ERROR,
};
use ratatui::buffer::Buffer;
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::widgets::{Clear, Paragraph, Widget};
use std::slice;

const COMMAND_WORDS: usize = 8;
const STYLE_WORDS: usize = 4;

#[derive(Debug)]
enum DrawCommand<'a> {
    Text {
        area: Rect,
        text: &'a str,
        style_ref: u32,
    },
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

fn decode_color(word: u32) -> Result<Option<Color>, i32> {
    let tag = word >> 28;
    let value = word & 0x00ff_ffff;

    match tag {
        0 => {
            if value != 0 {
                Err(CTUI_STATUS_MALFORMED_COMMAND)
            } else {
                Ok(None)
            }
        }
        1 => {
            if value != 0 {
                Err(CTUI_STATUS_MALFORMED_COMMAND)
            } else {
                Ok(Some(Color::Reset))
            }
        }
        2 => {
            let index = u8::try_from(value).map_err(|_| CTUI_STATUS_MALFORMED_COMMAND)?;
            Ok(Some(Color::Indexed(index)))
        }
        3 => Ok(Some(Color::Rgb(
            ((value >> 16) & 0xff) as u8,
            ((value >> 8) & 0xff) as u8,
            (value & 0xff) as u8,
        ))),
        _ => Err(CTUI_STATUS_MALFORMED_COMMAND),
    }
}

fn decode_modifiers(bits: u32) -> Result<Modifier, i32> {
    if bits & !0x01ff != 0 {
        return Err(CTUI_STATUS_MALFORMED_COMMAND);
    }

    let mut out = Modifier::empty();
    if bits & (1 << 0) != 0 { out |= Modifier::BOLD; }
    if bits & (1 << 1) != 0 { out |= Modifier::DIM; }
    if bits & (1 << 2) != 0 { out |= Modifier::ITALIC; }
    if bits & (1 << 3) != 0 { out |= Modifier::UNDERLINED; }
    if bits & (1 << 4) != 0 { out |= Modifier::SLOW_BLINK; }
    if bits & (1 << 5) != 0 { out |= Modifier::RAPID_BLINK; }
    if bits & (1 << 6) != 0 { out |= Modifier::REVERSED; }
    if bits & (1 << 7) != 0 { out |= Modifier::HIDDEN; }
    if bits & (1 << 8) != 0 { out |= Modifier::CROSSED_OUT; }
    Ok(out)
}

fn decode_styles(style_words: &[u32]) -> Result<Vec<Style>, i32> {
    if style_words.len() % STYLE_WORDS != 0 {
        return Err(CTUI_STATUS_MALFORMED_COMMAND);
    }

    let mut out = Vec::with_capacity(style_words.len() / STYLE_WORDS);
    for raw in style_words.chunks_exact(STYLE_WORDS) {
        if raw[3] != 0 {
            return Err(CTUI_STATUS_MALFORMED_COMMAND);
        }

        let mut style = Style::new();
        if let Some(fg) = decode_color(raw[0])? {
            style = style.fg(fg);
        }
        if let Some(bg) = decode_color(raw[1])? {
            style = style.bg(bg);
        }
        style = style.add_modifier(decode_modifiers(raw[2])?);
        out.push(style);
    }
    Ok(out)
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
        let flags = raw[7];

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
                out.push(DrawCommand::Text {
                    area,
                    text,
                    style_ref: flags,
                });
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

fn command_style(style_ref: u32, styles: &[Style]) -> Result<Style, i32> {
    if style_ref == 0 {
        return Ok(Style::new());
    }

    styles
        .get((style_ref - 1) as usize)
        .copied()
        .ok_or(CTUI_STATUS_MALFORMED_COMMAND)
}

fn render_to_buffer(
    buffer: &mut Buffer,
    commands: &[DrawCommand<'_>],
    styles: &[Style],
) -> Result<(), i32> {
    for command in commands {
        match command {
            DrawCommand::Text {
                area,
                text,
                style_ref,
            } => {
                let style = command_style(*style_ref, styles)?;
                Paragraph::new(*text).style(style).render(*area, buffer);
            }
            DrawCommand::Clear { area } => {
                Clear.render(*area, buffer);
            }
            DrawCommand::Cursor { .. } => {}
        }
    }
    Ok(())
}

fn decode_scene<'a>(
    command_words: &'a [u32],
    style_words: &[u32],
    text: &'a [u8],
) -> Result<(Vec<DrawCommand<'a>>, Vec<Style>), i32> {
    let commands = decode_commands(command_words, text)?;
    let styles = decode_styles(style_words)?;

    for command in &commands {
        if let DrawCommand::Text { style_ref, .. } = command {
            let _ = command_style(*style_ref, &styles)?;
        }
    }

    Ok((commands, styles))
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
    let Ok((commands, styles)) = decode_scene(command_words, &[], text) else {
        return 0;
    };

    let area = Rect::new(0, 0, 32, 4);
    let mut buffer = Buffer::empty(area);
    if render_to_buffer(&mut buffer, &commands, &styles).is_err() {
        return 0;
    }

    u32::from(
        buffer[(0, 0)].symbol() == "c"
            && buffer[(1, 0)].symbol() == "e"
            && buffer[(2, 0)].symbol() == "t",
    )
}

#[no_mangle]
pub extern "C" fn ctui_headless_scene_probe(
    command_words: *const u32,
    command_word_count: u32,
    style_words: *const u32,
    style_word_count: u32,
    text: *const u8,
    text_len: u32,
) -> u32 {
    let Some(command_words) = words(command_words, command_word_count) else {
        return 0;
    };
    let Some(style_words) = words(style_words, style_word_count) else {
        return 0;
    };
    let Some(text) = bytes(text, text_len) else {
        return 0;
    };
    let Ok((commands, styles)) = decode_scene(command_words, style_words, text) else {
        return 0;
    };

    let area = Rect::new(0, 0, 32, 4);
    let mut buffer = Buffer::empty(area);
    if render_to_buffer(&mut buffer, &commands, &styles).is_err() {
        return 0;
    }

    let cell = &buffer[(0, 0)];
    u32::from(
        cell.symbol() == "c"
            && cell.fg == Color::Rgb(10, 200, 100)
            && cell.modifier.contains(Modifier::BOLD),
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
    ctui_render_scene(
        tui,
        command_words,
        word_count,
        std::ptr::null(),
        0,
        text,
        text_len,
    )
}

#[no_mangle]
pub extern "C" fn ctui_render_scene(
    tui: *mut CetasTui,
    command_words: *const u32,
    command_word_count: u32,
    style_words: *const u32,
    style_word_count: u32,
    text: *const u8,
    text_len: u32,
) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }
    let Some(command_words) = words(command_words, command_word_count) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let Some(style_words) = words(style_words, style_word_count) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let Some(text) = bytes(text, text_len) else {
        return CTUI_STATUS_INVALID_ARGUMENT;
    };
    let (commands, styles) = match decode_scene(command_words, style_words, text) {
        Ok(scene) => scene,
        Err(status) => return status,
    };

    let tui = unsafe { &mut *tui };
    match tui.terminal.draw(|frame| {
        for command in &commands {
            match command {
                DrawCommand::Text {
                    area,
                    text,
                    style_ref,
                } => {
                    let style = command_style(*style_ref, &styles)
                        .expect("scene styles validated before draw");
                    frame.render_widget(Paragraph::new(*text).style(style), *area);
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
        let (commands, styles) = decode_scene(&words, &[], b"cetas").unwrap();
        let mut buffer = Buffer::empty(Rect::new(0, 0, 10, 1));
        render_to_buffer(&mut buffer, &commands, &styles).unwrap();
        assert_eq!(buffer[(0, 0)].symbol(), "c");
        assert_eq!(buffer[(4, 0)].symbol(), "s");
    }

    #[test]
    fn renders_rgb_bold_style() {
        let words = [1u32, 0, 0, 10, 1, 0, 5, 1];
        let styles = [0x030a_c864u32, 0, 1, 0];
        let (commands, styles) = decode_scene(&words, &styles, b"cetas").unwrap();
        let mut buffer = Buffer::empty(Rect::new(0, 0, 10, 1));
        render_to_buffer(&mut buffer, &commands, &styles).unwrap();

        let cell = &buffer[(0, 0)];
        assert_eq!(cell.fg, Color::Rgb(10, 200, 100));
        assert!(cell.modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn rejects_missing_style_reference() {
        let words = [1u32, 0, 0, 10, 1, 0, 5, 1];
        assert_eq!(
            decode_scene(&words, &[], b"cetas").unwrap_err(),
            CTUI_STATUS_MALFORMED_COMMAND
        );
    }
}
