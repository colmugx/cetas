use crate::{
    CTUI_STATUS_BUFFER_TOO_SMALL, CTUI_STATUS_INVALID_ARGUMENT, CTUI_STATUS_OK,
    CTUI_STATUS_TERMINAL_ERROR,
};
use ratatui::crossterm::event::{
    DisableBracketedPaste, DisableFocusChange, EnableBracketedPaste, EnableFocusChange,
};
use ratatui::crossterm::execute;
use ratatui::widgets::{Paragraph, Widget};
use ratatui::{DefaultTerminal, TerminalOptions, Viewport};
use std::io::{self, stdout};
use std::ptr;

pub struct CetasTui {
    pub(crate) terminal: DefaultTerminal,
    pub(crate) last_event_text: Vec<u8>,
    pub(crate) suspended: bool,
    rows: u16,
}

fn enable_event_modes() -> io::Result<()> {
    execute!(stdout(), EnableBracketedPaste, EnableFocusChange)?;
    Ok(())
}

fn disable_event_modes() {
    let _ = execute!(stdout(), DisableFocusChange, DisableBracketedPaste);
}

fn init_inline(rows: u16) -> io::Result<DefaultTerminal> {
    let terminal = ratatui::try_init_with_options(TerminalOptions {
        viewport: Viewport::Inline(rows),
    })?;

    if let Err(error) = enable_event_modes() {
        let _ = ratatui::try_restore();
        return Err(error);
    }

    Ok(terminal)
}

#[no_mangle]
pub extern "C" fn ctui_open_inline(rows: u32) -> *mut CetasTui {
    let rows = rows.clamp(1, u16::MAX as u32) as u16;

    match init_inline(rows) {
        Ok(terminal) => Box::into_raw(Box::new(CetasTui {
            terminal,
            last_event_text: Vec::new(),
            suspended: false,
            rows,
        })),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn ctui_is_null(tui: *const CetasTui) -> u32 {
    u32::from(tui.is_null())
}

#[no_mangle]
pub extern "C" fn ctui_close(tui: *mut CetasTui) {
    if tui.is_null() {
        return;
    }

    let tui = unsafe { Box::from_raw(tui) };
    let should_restore = !tui.suspended;
    drop(tui);

    if should_restore {
        disable_event_modes();
        let _ = ratatui::try_restore();
    }
}

#[no_mangle]
pub extern "C" fn ctui_suspend(tui: *mut CetasTui) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }

    let tui = unsafe { &mut *tui };
    if tui.suspended {
        return CTUI_STATUS_OK;
    }

    disable_event_modes();
    match ratatui::try_restore() {
        Ok(()) => {
            tui.suspended = true;
            CTUI_STATUS_OK
        }
        Err(_) => {
            let _ = enable_event_modes();
            CTUI_STATUS_TERMINAL_ERROR
        }
    }
}

#[no_mangle]
pub extern "C" fn ctui_resume(tui: *mut CetasTui) -> i32 {
    if tui.is_null() {
        return CTUI_STATUS_INVALID_ARGUMENT;
    }

    let tui = unsafe { &mut *tui };
    if !tui.suspended {
        return CTUI_STATUS_OK;
    }

    match init_inline(tui.rows) {
        Ok(terminal) => {
            tui.terminal = terminal;
            tui.suspended = false;
            CTUI_STATUS_OK
        }
        Err(_) => CTUI_STATUS_TERMINAL_ERROR,
    }
}

#[no_mangle]
pub extern "C" fn ctui_tty_probe() -> u32 {
    let Ok(mut terminal) = init_inline(3) else {
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

    disable_event_modes();
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
    if tui.suspended {
        return CTUI_STATUS_TERMINAL_ERROR;
    }
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
