mod inline;
mod input;
mod renderer;
mod terminal;

pub use terminal::CetasTui;

#[no_mangle]
pub extern "C" fn ctui_abi_version() -> u32 {
    1
}
