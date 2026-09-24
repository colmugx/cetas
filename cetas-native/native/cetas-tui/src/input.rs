use ratatui::crossterm::event::{
    self, Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind,
};
use std::mem::size_of;
use std::time::Duration;

#[repr(C)]
pub struct CetasTuiEvent {
    kind: u32,
    key_code: u32,
    codepoint: u32,
    modifiers: u32,
    key_action: u32,
    width: u16,
    height: u16,
    mouse_x: u16,
    mouse_y: u16,
    mouse_kind: u32,
    mouse_button: u32,
    text_len: usize,
}

impl Default for CetasTuiEvent {
    fn default() -> Self {
        Self {
            kind: 0,
            key_code: 0,
            codepoint: 0,
            modifiers: 0,
            key_action: 0,
            width: 0,
            height: 0,
            mouse_x: 0,
            mouse_y: 0,
            mouse_kind: 0,
            mouse_button: 0,
            text_len: 0,
        }
    }
}

fn modifiers(value: KeyModifiers) -> u32 {
    let mut out = 0u32;
    if value.contains(KeyModifiers::SHIFT) { out |= 1 << 0; }
    if value.contains(KeyModifiers::CONTROL) { out |= 1 << 1; }
    if value.contains(KeyModifiers::ALT) { out |= 1 << 2; }
    if value.contains(KeyModifiers::SUPER) { out |= 1 << 3; }
    if value.contains(KeyModifiers::HYPER) { out |= 1 << 4; }
    if value.contains(KeyModifiers::META) { out |= 1 << 5; }
    out
}

fn key_action(kind: KeyEventKind) -> u32 {
    match kind {
        KeyEventKind::Press => 1,
        KeyEventKind::Repeat => 2,
        KeyEventKind::Release => 3,
    }
}

fn set_key_code(code: KeyCode, out: &mut CetasTuiEvent) {
    out.key_code = match code {
        KeyCode::Char(ch) => {
            out.codepoint = ch as u32;
            1
        }
        KeyCode::Enter => 2,
        KeyCode::Esc => 3,
        KeyCode::Backspace => 4,
        KeyCode::Tab => 5,
        KeyCode::BackTab => 6,
        KeyCode::Left => 7,
        KeyCode::Right => 8,
        KeyCode::Up => 9,
        KeyCode::Down => 10,
        KeyCode::Home => 11,
        KeyCode::End => 12,
        KeyCode::PageUp => 13,
        KeyCode::PageDown => 14,
        KeyCode::Delete => 15,
        KeyCode::Insert => 16,
        KeyCode::F(n) => 100 + u32::from(n),
        _ => 0,
    };
}

fn mouse_button(button: MouseButton) -> u32 {
    match button {
        MouseButton::Left => 1,
        MouseButton::Right => 2,
        MouseButton::Middle => 3,
    }
}

#[no_mangle]
pub extern "C" fn ctui_event_size() -> u32 {
    size_of::<CetasTuiEvent>() as u32
}

#[no_mangle]
pub extern "C" fn ctui_poll(timeout_ms: u64, out_event: *mut CetasTuiEvent) -> i32 {
    if out_event.is_null() {
        return 0;
    }

    let mut out = CetasTuiEvent::default();

    let ready = match event::poll(Duration::from_millis(timeout_ms)) {
        Ok(value) => value,
        Err(_) => return 0,
    };

    if !ready {
        unsafe { *out_event = out; }
        return 0;
    }

    let event = match event::read() {
        Ok(value) => value,
        Err(_) => return 0,
    };

    match event {
        Event::Key(key) => {
            out.kind = 1;
            out.modifiers = modifiers(key.modifiers);
            out.key_action = key_action(key.kind);
            set_key_code(key.code, &mut out);
        }
        Event::Resize(width, height) => {
            out.kind = 2;
            out.width = width;
            out.height = height;
        }
        Event::Mouse(mouse) => {
            out.kind = 3;
            out.mouse_x = mouse.column;
            out.mouse_y = mouse.row;
            out.modifiers = modifiers(mouse.modifiers);

            match mouse.kind {
                MouseEventKind::Down(button) => {
                    out.mouse_kind = 1;
                    out.mouse_button = mouse_button(button);
                }
                MouseEventKind::Up(button) => {
                    out.mouse_kind = 2;
                    out.mouse_button = mouse_button(button);
                }
                MouseEventKind::Drag(button) => {
                    out.mouse_kind = 3;
                    out.mouse_button = mouse_button(button);
                }
                MouseEventKind::Moved => out.mouse_kind = 4,
                MouseEventKind::ScrollDown => out.mouse_kind = 5,
                MouseEventKind::ScrollUp => out.mouse_kind = 6,
                MouseEventKind::ScrollLeft => out.mouse_kind = 7,
                MouseEventKind::ScrollRight => out.mouse_kind = 8,
            }
        }
        Event::Paste(text) => {
            out.kind = 4;
            out.text_len = text.len();
        }
        Event::FocusGained => out.kind = 5,
        Event::FocusLost => out.kind = 6,
    }

    unsafe { *out_event = out; }
    1
}
