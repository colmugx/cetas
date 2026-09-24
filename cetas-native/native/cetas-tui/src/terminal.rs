use ratatui::{DefaultTerminal, TerminalOptions, Viewport};
use std::ptr;

pub struct CetasTui {
    pub(crate) terminal: DefaultTerminal,
}

#[no_mangle]
pub extern "C" fn ctui_open_inline(rows: u16) -> *mut CetasTui {
    let options = TerminalOptions {
        viewport: Viewport::Inline(rows.max(1)),
    };

    match ratatui::try_init_with_options(options) {
        Ok(terminal) => Box::into_raw(Box::new(CetasTui { terminal })),
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
