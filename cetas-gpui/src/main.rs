use gpui_kit::component::{
    button::Button,
    input::{Textarea, TextareaState},
    message_scroller::{MessageScroller, MessageScrollerState},
    text::{TextView, TextViewState},
    h_flex, v_flex,
};
use gpui_kit::*;
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    ffi::c_char,
    rc::Rc,
    sync::{Mutex, OnceLock},
    time::Duration,
};

static COMMANDS: OnceLock<Mutex<VecDeque<Vec<u8>>>> = OnceLock::new();
static EVENTS: OnceLock<Mutex<VecDeque<Vec<u8>>>> = OnceLock::new();

fn commands() -> &'static Mutex<VecDeque<Vec<u8>>> {
    COMMANDS.get_or_init(|| Mutex::new(VecDeque::new()))
}
fn events() -> &'static Mutex<VecDeque<Vec<u8>>> {
    EVENTS.get_or_init(|| Mutex::new(VecDeque::new()))
}

#[no_mangle]
pub extern "C" fn cetas_gpui_command_len() -> i32 {
    commands()
        .lock()
        .unwrap()
        .front()
        .map(|v| v.len().min(i32::MAX as usize) as i32)
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn cetas_gpui_command_copy(out: *mut u8, cap: i32) -> i32 {
    if out.is_null() || cap <= 0 {
        return 0;
    }
    let Some(message) = commands().lock().unwrap().pop_front() else {
        return 0;
    };
    let len = message.len().min(cap as usize);
    std::ptr::copy_nonoverlapping(message.as_ptr(), out, len);
    len as i32
}

#[no_mangle]
pub unsafe extern "C" fn cetas_gpui_event_push(data: *const u8, len: i32) {
    if data.is_null() || len <= 0 {
        return;
    }
    events()
        .lock()
        .unwrap()
        .push_back(std::slice::from_raw_parts(data, len as usize).to_vec());
}

extern "C" {
    fn cetas_moonbit_main(argc: i32, argv: *mut *mut c_char) -> i32;
}

fn launch_moonbit() {
    std::thread::Builder::new()
        .name("cetas-moonbit-core".into())
        .spawn(|| unsafe {
            let _ = cetas_moonbit_main(0, std::ptr::null_mut());
        })
        .expect("failed to launch MoonBit Cetas core");
}

fn queue_command(value: Value) {
    commands()
        .lock()
        .unwrap()
        .push_back(value.to_string().into_bytes());
}

fn drain_events() -> Vec<Value> {
    let mut queue = events().lock().unwrap();
    queue
        .drain(..)
        .filter_map(|bytes| serde_json::from_slice(&bytes).ok())
        .collect()
}

#[derive(Clone)]
enum Message {
    User(String),
    Assistant(Entity<TextViewState>),
    Reasoning(String),
    Tool { name: String, body: String, failed: bool },
    Notice(String),
}

struct CetasDesktop {
    messages: Vec<Message>,
    scroller: Entity<MessageScrollerState>,
    composer: Entity<TextareaState>,
    status: SharedString,
    session: SharedString,
    active_assistant: Option<usize>,
    _poll: Task<()>,
}

impl CetasDesktop {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let scroller = cx.new(|cx| MessageScrollerState::new(0, cx));
        cx.observe(&scroller, |_, _, cx| cx.notify()).detach();
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Ask Cetas…")
                .auto_grow(2, 7)
        });

        let poll = cx.spawn(async move |weak, cx| loop {
            Timer::after(Duration::from_millis(16)).await;
            let batch = drain_events();
            if batch.is_empty() {
                continue;
            }
            if weak
                .update(cx, |this, cx| {
                    for event in batch {
                        this.apply_event(event, cx);
                    }
                })
                .is_err()
            {
                break;
            }
        });

        Self {
            messages: vec![],
            scroller,
            composer,
            status: "starting MoonBit core…".into(),
            session: "".into(),
            active_assistant: None,
            _poll: poll,
        }
    }

    fn append(&mut self, message: Message, cx: &mut Context<Self>) -> usize {
        let index = self.messages.len();
        self.messages.push(message);
        self.scroller.update(cx, |state, cx| {
            let _ = state.append(1, cx);
        });
        cx.notify();
        index
    }

    fn apply_event(&mut self, event: Value, cx: &mut Context<Self>) {
        let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
        if let Some(session) = event.get("session_id").and_then(Value::as_str) {
            if !session.is_empty() {
                self.session = session.to_owned().into();
            }
        }

        match kind {
            "session.snapshot" => {
                let model = event.get("model").and_then(Value::as_str).unwrap_or("model");
                self.status = format!("ready · {model}").into();
            }
            "runtime.warning" => {
                if let Some(text) = event.get("message").and_then(Value::as_str) {
                    self.status = text.to_owned().into();
                }
            }
            "runtime.unavailable" | "turn.failed" | "protocol.error" => {
                let text = event
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Cetas core unavailable");
                self.status = "error".into();
                self.append(Message::Notice(text.to_owned()), cx);
            }
            "turn.accepted" => {
                self.status = "thinking…".into();
                let state = cx.new(|cx| TextViewState::markdown("", cx));
                let index = self.append(Message::Assistant(state), cx);
                self.active_assistant = Some(index);
            }
            "assistant.text_delta" => {
                let Some(delta) = event.get("delta").and_then(Value::as_str) else {
                    return;
                };
                if let Some(index) = self.active_assistant {
                    if let Some(Message::Assistant(state)) = self.messages.get(index) {
                        state.update(cx, |state, cx| state.push_str(delta, cx));
                        self.scroller.update(cx, |state, cx| {
                            let _ = state.remeasure_items(index..index + 1, cx);
                        });
                        cx.notify();
                    }
                }
            }
            "assistant.reasoning_delta" => {
                let delta = event.get("delta").and_then(Value::as_str).unwrap_or("");
                if !delta.is_empty() {
                    if matches!(self.messages.last(), Some(Message::Reasoning(_))) {
                        if let Some(Message::Reasoning(body)) = self.messages.last_mut() {
                            body.push_str(delta);
                            let i = self.messages.len() - 1;
                            self.scroller.update(cx, |state, cx| {
                                let _ = state.remeasure_items(i..i + 1, cx);
                            });
                        }
                    } else {
                        self.append(Message::Reasoning(delta.to_owned()), cx);
                    }
                    cx.notify();
                }
            }
            "tool.started" => {
                let name = event.get("tool_name").and_then(Value::as_str).unwrap_or("tool");
                self.append(
                    Message::Tool {
                        name: name.to_owned(),
                        body: "running…".into(),
                        failed: false,
                    },
                    cx,
                );
            }
            "tool.completed" => {
                let name = event.get("tool_name").and_then(Value::as_str).unwrap_or("tool");
                let body = event.get("result").and_then(Value::as_str).unwrap_or("");
                let failed = event.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                self.append(
                    Message::Tool {
                        name: name.to_owned(),
                        body: body.to_owned(),
                        failed,
                    },
                    cx,
                );
            }
            "turn.completed" => {
                self.status = "ready".into();
                self.active_assistant = None;
            }
            _ => {}
        }
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let prompt = self.composer.read(cx).value().trim().to_owned();
        if prompt.is_empty() {
            return;
        }
        self.append(Message::User(prompt.clone()), cx);
        self.composer.update(cx, |state, cx| {
            state.set_value("", window, cx);
            state.focus(window, cx);
        });
        queue_command(json!({"type":"turn.start","prompt":prompt}));
        self.status = "queued…".into();
        cx.notify();
    }

    fn render_message(message: &Message) -> AnyElement {
        match message {
            Message::User(text) => h_flex()
                .w_full()
                .justify_end()
                .child(
                    div()
                        .max_w(px(680.))
                        .px_4()
                        .py_3()
                        .rounded_xl()
                        .bg(rgb(0x243044))
                        .text_color(rgb(0xf4f7fb))
                        .child(text.clone()),
                )
                .into_any_element(),
            Message::Assistant(state) => div()
                .w_full()
                .max_w(px(820.))
                .py_2()
                .child(TextView::new(state).selectable(true).stream_fade(true))
                .into_any_element(),
            Message::Reasoning(text) => div()
                .w_full()
                .px_3()
                .py_2()
                .rounded_lg()
                .bg(rgb(0x1a1d23))
                .text_color(rgb(0x8d95a3))
                .text_sm()
                .child(text.clone())
                .into_any_element(),
            Message::Tool { name, body, failed } => v_flex()
                .w_full()
                .gap_2()
                .px_3()
                .py_3()
                .rounded_lg()
                .border_1()
                .border_color(if *failed { rgb(0x713b43) } else { rgb(0x343a46) })
                .bg(rgb(0x16191f))
                .child(div().font_weight(FontWeight::SEMIBOLD).child(name.clone()))
                .child(div().text_sm().text_color(rgb(0xaab1bd)).child(body.clone()))
                .into_any_element(),
            Message::Notice(text) => div()
                .w_full()
                .px_3()
                .py_2()
                .rounded_lg()
                .bg(rgb(0x3b2529))
                .text_color(rgb(0xffc7ce))
                .child(text.clone())
                .into_any_element(),
        }
    }
}

impl Render for CetasDesktop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Rc::new(self.messages.clone());
        let status = self.status.clone();
        let session = self.session.clone();

        h_flex()
            .id("cetas-desktop")
            .size_full()
            .bg(rgb(0x0f1115))
            .text_color(rgb(0xe7eaf0))
            .child(
                v_flex()
                    .w(px(248.))
                    .h_full()
                    .border_r_1()
                    .border_color(rgb(0x252a33))
                    .p_4()
                    .gap_4()
                    .child(div().text_xl().font_weight(FontWeight::BOLD).child("Cetas"))
                    .child(div().text_sm().text_color(rgb(0x8d95a3)).child("Native GPUI POC"))
                    .child(
                        v_flex()
                            .gap_2()
                            .child(div().text_sm().child("Session"))
                            .child(div().text_xs().text_color(rgb(0x737b89)).child(session)),
                    )
                    .child(div().flex_1())
                    .child(div().text_xs().text_color(rgb(0x737b89)).child(status)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .h_full()
                    .min_w_0()
                    .child(
                        div()
                            .h(px(52.))
                            .px_5()
                            .flex()
                            .items_center()
                            .border_b_1()
                            .border_color(rgb(0x252a33))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Workspace")),
                    )
                    .child(
                        MessageScroller::new(
                            "conversation",
                            self.scroller.clone(),
                            move |index, _window, _cx| {
                                let Some(message) = rows.get(index) else {
                                    return div().into_any_element();
                                };
                                div()
                                    .id(("message-row", index))
                                    .w_full()
                                    .px_6()
                                    .py_2()
                                    .child(Self::render_message(message))
                                    .into_any_element()
                            },
                        )
                        .flex_1()
                        .min_h_0()
                        .w_full()
                        .with_jump_button_label("Jump to latest"),
                    )
                    .child(
                        v_flex()
                            .w_full()
                            .border_t_1()
                            .border_color(rgb(0x252a33))
                            .p_4()
                            .gap_2()
                            .child(
                                div()
                                    .rounded_xl()
                                    .border_1()
                                    .border_color(rgb(0x343a46))
                                    .bg(rgb(0x15181e))
                                    .p_2()
                                    .child(Textarea::new(&self.composer)),
                            )
                            .child(
                                h_flex()
                                    .justify_between()
                                    .child(div().text_xs().text_color(rgb(0x737b89)).child("MoonBit cetas-core · native"))
                                    .child(
                                        Button::new("send")
                                            .primary()
                                            .label("Send")
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.submit(window, cx);
                                            })),
                                    ),
                            ),
                    ),
            )
    }
}

fn main() {
    launch_moonbit();

    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .run(|cx| {
            gpui_kit::init(cx);
            let options = WindowOptions {
                window_bounds: Some(WindowBounds::centered(size(px(1180.), px(820.)), cx)),
                ..Default::default()
            };
            gpui_kit::open_window(options, cx, |window, cx| {
                cx.new(|cx| CetasDesktop::new(window, cx))
            })
            .expect("failed to open Cetas desktop window");
        });
}
