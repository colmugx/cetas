use serde_json::Value;
use std::{
    collections::VecDeque,
    ffi::c_char,
    ptr,
    sync::{Mutex, OnceLock},
    thread,
};

fn commands() -> &'static Mutex<VecDeque<Vec<u8>>> {
    static COMMANDS: OnceLock<Mutex<VecDeque<Vec<u8>>>> = OnceLock::new();
    COMMANDS.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn events() -> &'static Mutex<VecDeque<Vec<u8>>> {
    static EVENTS: OnceLock<Mutex<VecDeque<Vec<u8>>>> = OnceLock::new();
    EVENTS.get_or_init(|| Mutex::new(VecDeque::new()))
}

pub fn send_command(value: Value) {
    if let Ok(bytes) = serde_json::to_vec(&value) {
        commands().lock().unwrap().push_back(bytes);
    }
}

pub fn drain_events() -> Vec<Value> {
    let mut queue = events().lock().unwrap();
    let bytes: Vec<_> = queue.drain(..).collect();
    drop(queue);
    bytes
        .into_iter()
        .filter_map(|line| serde_json::from_slice(&line).ok())
        .collect()
}

#[unsafe(no_mangle)]
pub extern "C" fn cetas_gpui_command_len() -> u32 {
    commands()
        .lock()
        .unwrap()
        .front()
        .map(|command| command.len().min(u32::MAX as usize) as u32)
        .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cetas_gpui_command_copy(out: *mut u8, capacity: u32) -> i32 {
    if out.is_null() {
        return 2;
    }
    let mut queue = commands().lock().unwrap();
    let Some(command) = queue.front() else {
        return 1;
    };
    if command.len() > capacity as usize {
        return 3;
    }
    unsafe {
        ptr::copy_nonoverlapping(command.as_ptr(), out, command.len());
    }
    queue.pop_front();
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cetas_gpui_emit(data: *const u8, len: u32) -> i32 {
    if data.is_null() && len != 0 {
        return 2;
    }
    let slice = if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, len as usize) }
    };
    events().lock().unwrap().push_back(slice.to_vec());
    0
}

unsafe extern "C" {
    fn cetas_mbt_core_main(argc: i32, argv: *mut *mut c_char) -> i32;
}

pub fn start_moon_core() {
    thread::Builder::new()
        .name("cetas-moon-core".into())
        .spawn(|| {
            let mut arg0 = b"cetas-gpui-core\0".to_vec();
            let mut argv = [arg0.as_mut_ptr().cast::<c_char>(), ptr::null_mut()];
            unsafe {
                let _ = cetas_mbt_core_main(1, argv.as_mut_ptr());
            }
        })
        .expect("failed to start MoonBit Cetas core thread");
}
