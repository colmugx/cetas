mod inline;
mod input;
mod renderer;
mod terminal;

pub use terminal::CetasTui;

pub(crate) const CTUI_STATUS_OK: i32 = 0;
pub(crate) const CTUI_STATUS_TIMEOUT: i32 = 1;
pub(crate) const CTUI_STATUS_INVALID_ARGUMENT: i32 = 2;
pub(crate) const CTUI_STATUS_TERMINAL_ERROR: i32 = 3;
pub(crate) const CTUI_STATUS_BUFFER_TOO_SMALL: i32 = 4;
pub(crate) const CTUI_STATUS_MALFORMED_COMMAND: i32 = 5;

#[no_mangle]
pub extern "C" fn ctui_abi_version() -> u32 {
    2
}
