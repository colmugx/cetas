use ratatui::widgets::{Paragraph, Widget};
use ratatui::{DefaultTerminal, TerminalOptions, Viewport};
use crate::{CTUI_STATUS_BUFFER_TOO_SMALL, CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_OK, CTUI_STATUS_TERMINAL_ERROR};
use std::ptr;

pub struct CetasTui {
    pub(crate) terminal: DefaultTerminal,
    pub(crate) last_event_text: Vec<u8>,
}

#[no_mangle]
pub extern "C" fn ctui_open_inline(rows: u32) -> *mut CetasTui {
    let rows = rows.clamp(1, u16::MAX as u32) as u16;
    let options = TerminalOptions {
        viewport: Viewport::Inline(rows),
    };

    match ratatui::try_init_with_options(options) {
        Ok(terminal) => Box::into_raw(Box::new(CetasTui {
            terminal,
            last_event_text: Vec::new(),
        })),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn ctui_close(tui: *mut CetasTui) {
    if tui.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(tui));
    }

    let _ = ratatui::try_restore();
}

#[no_mangle]
pub extern "C" fn ctui_tty_probe() -> u32 {
    let options = TerminalOptions {
        viewport: Viewport::Inline(3),
    };

    let Ok(mut terminal) = ratatui::try_init_with_options(options) else {
        return 0;
    };

    let draw_ok = terminal
        .draw(|frame| {
            frame.render_widget(Paragraph::new("cetas-live"), frame.area());
        })
        .is_ok();

    let insert_ok = if draw_ok {
        terminal
            .insert_before(1, |buffer| {
                Paragraph::new("cetas-history").render(buffer.area, buffer);
            })
            .is_ok()
    } else {
        false
    };

    drop(terminal);
    let restore_ok = ratatui::try_restore().is_ok();

    u32::from(draw_ok && insert_ok && restore_ok)
}


#[no_mangle]
pub extern "C" fn ctui_viewport_size(
    tui: *mut CetasTui,
    out_words: *mut u32,
    capacity: u32,
) -> i32 {
    if tui.is_null() || out_words.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }
    if capacity < 2 {
        return CTUI_STATUS_BUFFER_TOO_SMALL;
    }

    let tui = unsafe { &mut *tui };
    if tui.terminal.autoresize().is_err() {
        return CTUI_STATUS_TERMINAL_ERROR;
    }
    let area = tui.terminal.get_frame().area();

    unsafe {
        *out_words.add(0) = u32::from(area.width);
        *out_words.add(1) = u32::from(area.height);
    }
    CTUI_STATUS_OK
}
