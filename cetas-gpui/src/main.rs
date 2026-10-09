//! Native Cetas desktop: GPUI presentation of in-process MoonBit Cetas WebRuntime.
//! The WebRuntime runs in a dedicated thread within *this same binary*.
//! Only the transport is loopback; the UI is GPUI, never a WebView.
use std::{
    net::TcpStream,
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::Duration,
};

use gpui_kit::assets::Assets;
use gpui_kit::component::{
    ActiveTheme as _,
    button::{Button, ButtonVariants as _},
    h_flex,
    input::{Textarea, TextareaState},
    message_scroller::{MessageScroller, MessageScrollerState},
    text::{TextView, TextViewState},
    v_flex,
};
use gpui_kit::*;
use serde_json::{Value, json};
use tungstenite::{Message, stream::MaybeTlsStream};

unsafe extern "C" {
    // Renamed from the generated MoonBit C executable entry at compile time.
    // This is intentionally version-gated by the actual macOS CI link.
    fn cetas_embedded_moon_main(argc: i32, argv: *const *const std::ffi::c_char) -> i32;
}

fn start_real_moonbit_core() {
    thread::Builder::new()
        .name("cetas-moonbit-core".into())
        .spawn(|| {
            let argv = [std::ptr::null()];
            // SAFETY: the MoonBit runtime's generated entry is invoked once;
            // GPUI itself owns the macOS main thread.
            let rc = unsafe { cetas_embedded_moon_main(0, argv.as_ptr()) };
            eprintln!("cetas MoonBit core returned: {rc}");
        })
        .expect("start embedded MoonBit Cetas runtime thread");
}

#[derive(Clone)]
enum UiEvent {
    Connected,
    Disconnected(String),
    Message(Value),
}

fn spawn_protocol_client(events: smol::channel::Sender<UiEvent>, commands: Receiver<String>) {
    thread::Builder::new()
        .name("cetas-native-protocol".into())
        .spawn(move || {
            // MoonBit startup may load provider settings/model cache first.
            loop {
                match tungstenite::connect("ws://127.0.0.1:8787/ws") {
                    Ok((mut ws, _)) => {
                        if let MaybeTlsStream::Plain(stream) = ws.get_mut() {
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(40)));
                            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
                        }
                        let _ = events.try_send(UiEvent::Connected);
                        let _ = ws.send(Message::Text(
                            json!({"type":"session.attach"}).to_string().into(),
                        ));
                        loop {
                            while let Ok(command) = commands.try_recv() {
                                if ws.send(Message::Text(command.into())).is_err() {
                                    break;
                                }
                            }
                            match ws.read() {
                                Ok(Message::Text(data)) => {
                                    if let Ok(event) = serde_json::from_str::<Value>(&data) {
                                        let _ = events.try_send(UiEvent::Message(event));
                                    }
                                }
                                Ok(Message::Close(_)) => break,
                                Ok(_) => {}
                                Err(tungstenite::Error::Io(ref error))
                                    if error.kind() == std::io::ErrorKind::WouldBlock
                                        || error.kind() == std::io::ErrorKind::TimedOut => {}
                                Err(error) => {
                                    let _ = events.try_send(UiEvent::Disconnected(error.to_string()));
                                    break;
                                }
                            }
                        }
                    }
                    Err(_) => {
                        thread::sleep(Duration::from_millis(300));
                    }
                }
            }
        })
        .expect("start native event bridge");
}

#[derive(Clone)]
struct TranscriptRow {
    id: usize,
    role: String,
    markdown: Entity<TextViewState>,
}

struct CetasDesktop {
    scroller: Entity<MessageScrollerState>,
    composer: Entity<TextareaState>,
    rows: Vec<TranscriptRow>,
    next_row: usize,
    live_assistant: Option<usize>,
    tool_rows: std::collections::HashMap<String, usize>,
    stream_has_text: bool,
    busy: bool,
    connected: bool,
    status: String,
    model: String,
    session: String,
    cwd: String,
    command_tx: Sender<String>,
    _events: Task<()>,
}

impl CetasDesktop {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let scroller = cx.new(|cx| MessageScrollerState::new(0, cx));
        cx.observe(&scroller, |_, _, cx| cx.notify()).detach();
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 7)
                .placeholder("Ask Cetas to inspect, explain or edit your workspace…")
        });
        let (command_tx, command_rx) = mpsc::channel::<String>();
        let (event_tx, event_rx) = smol::channel::unbounded::<UiEvent>();
        spawn_protocol_client(event_tx, command_rx);
        let _events = cx.spawn(async move |view, cx| {
            while let Ok(event) = event_rx.recv().await {
                let _ = view.update(cx, |this, cx| this.apply_event(event, cx));
            }
        });
        Self {
            scroller, composer, rows: Vec::new(), next_row: 1,
            live_assistant: None, tool_rows: Default::default(),
            stream_has_text: false, busy: false, connected: false,
            status: "Starting MoonBit Cetas core…".into(),
            model: "Discovering model".into(),
            session: String::new(), cwd: String::new(),
            command_tx, _events,
        }
    }

    fn add_row(&mut self, role: &str, body: String, cx: &mut Context<Self>) -> usize {
        let index = self.rows.len();
        let markdown = cx.new(|cx| TextViewState::markdown(body, cx));
        self.rows.push(TranscriptRow {
            id: self.next_row,
            role: role.to_string(),
            markdown,
        });
        self.next_row += 1;
        self.scroller.update(cx, |state, cx| {
            let _ = state.append(1, cx);
        });
        cx.notify();
        index
    }

    fn append_to(&mut self, index: usize, text: &str, cx: &mut Context<Self>) {
        if let Some(row) = self.rows.get(index) {
            row.markdown.update(cx, |state, cx| state.push_str(text, cx));
            self.scroller.update(cx, |state, cx| {
                let _ = state.remeasure_items(index..index + 1, cx);
            });
            cx.notify();
        }
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || !self.connected {
            return;
        }
        let prompt = self.composer.read(cx).value().to_string();
        if prompt.trim().is_empty() {
            return;
        }
        let message = json!({"type":"turn.start","prompt":prompt}).to_string();
        if self.command_tx.send(message).is_err() {
            self.status = "Desktop command bridge disconnected".into();
            cx.notify();
            return;
        }
        self.add_row("YOU", prompt, cx);
        self.composer.update(cx, |state, cx| state.set_value("", window, cx));
        self.live_assistant = None;
        self.stream_has_text = false;
        self.tool_rows.clear();
        self.busy = true;
        self.status = "Running Cetas turn…".into();
        cx.notify();
    }

    fn interrupt(&mut self, cx: &mut Context<Self>) {
        let _ = self.command_tx.send(json!({"type":"turn.abort"}).to_string());
        self.status = "Interrupt requested".into();
        cx.notify();
    }

    fn apply_event(&mut self, event: UiEvent, cx: &mut Context<Self>) {
        match event {
            UiEvent::Connected => {
                self.connected = true;
                self.status = "Connected to embedded MoonBit core".into();
            }
            UiEvent::Disconnected(reason) => {
                self.connected = false;
                self.busy = false;
                self.status = format!("Backend connection lost: {reason}");
            }
            UiEvent::Message(event) => {
                let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
                match kind {
                    "runtime.unavailable" => {
                        self.status = event["message"].as_str().unwrap_or("Core needs setup").into();
                    }
                    "session.snapshot" => {
                        self.model = event["model"].as_str().unwrap_or("No model").into();
                        self.cwd = event["cwd"].as_str().unwrap_or("").into();
                        self.busy = event["busy"].as_bool().unwrap_or(false);
                        self.session = event["session_id"].as_str().unwrap_or("").into();
                        self.status = if self.busy { "Agent running" } else { "Ready" }.into();
                    }
                    "turn.accepted" | "turn.started" => {
                        self.busy = true;
                        self.status = "Agent running".into();
                    }
                    "assistant.text_delta" => {
                        let delta = event["delta"].as_str().unwrap_or("");
                        let index = if let Some(index) = self.live_assistant {
                            index
                        } else {
                            let index = self.add_row("CETAS", String::new(), cx);
                            self.live_assistant = Some(index);
                            index
                        };
                        self.append_to(index, delta, cx);
                        self.stream_has_text = true;
                    }
                    "assistant.reasoning_delta" => {
                        self.status = "Thinking…".into();
                    }
                    "tool.started" => {
                        let name = event["tool_name"].as_str().unwrap_or("tool");
                        let id = event["tool_call_id"].as_str().unwrap_or("").to_string();
                        let args = &event["arguments"];
                        let body = format!("**{name}** · running\n\n```json\n{}\n```",
                            serde_json::to_string_pretty(args).unwrap_or_default());
                        let row = self.add_row("TOOL", body, cx);
                        self.tool_rows.insert(id, row);
                    }
                    "tool.completed" => {
                        let id = event["tool_call_id"].as_str().unwrap_or("");
                        let success = !event["is_error"].as_bool().unwrap_or(false);
                        let result = event["result"].as_str().unwrap_or("");
                        if let Some(&row) = self.tool_rows.get(id) {
                            let text = format!("\n\n**{}**\n\n```\n{}\n```",
                                if success { "Completed" } else { "Failed" }, result);
                            self.append_to(row, &text, cx);
                        }
                    }
                    "turn.completed" => {
                        if !self.stream_has_text {
                            let text = event["text"].as_str().unwrap_or("");
                            self.add_row("CETAS", text.to_string(), cx);
                        }
                        self.live_assistant = None;
                        self.busy = false;
                        self.status = "Ready".into();
                    }
                    "turn.failed" | "protocol.error" => {
                        let message = event["message"].as_str().unwrap_or("Unknown error");
                        self.add_row("ERROR", format!("**Cetas error:** {message}"), cx);
                        self.live_assistant = None;
                        self.busy = false;
                        self.status = "Turn failed".into();
                    }
                    "turn.abort_result" => {
                        self.status = "Abort acknowledged".into();
                    }
                    "connection.ready" => {
                        self.status = "Session attached".into();
                    }
                    _ => {}
                }
            }
        }
        cx.notify();
    }

    fn view(window: &mut Window, cx: &mut App) -> Entity<Self> {
        cx.new(|cx| Self::new(window, cx))
    }
}

impl Render for CetasDesktop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = std::rc::Rc::new(self.rows.clone());
        let status = self.status.clone();
        let model = self.model.clone();
        let cwd = if self.cwd.is_empty() { "No workspace selected".into() } else { self.cwd.clone() };
        let is_busy = self.busy;
        let can_submit = self.connected && !self.busy;
        let left = v_flex()
            .w(px(256.))
            .h_full()
            .p_5()
            .gap_5()
            .bg(rgb(0x11151d))
            .child(
                v_flex()
                    .gap_1()
                    .child(div().text_size(px(22.)).text_color(rgb(0xe6eef9)).child("Cetas"))
                    .child(div().text_size(px(11.)).text_color(rgb(0x8391a6)).child("NATIVE · GPUI / MOONBIT")),
            )
            .child(
                v_flex()
                    .gap_2()
                    .p_3()
                    .rounded_lg()
                    .bg(rgb(0x1c2532))
                    .child(div().text_size(px(11.)).text_color(rgb(0x8ca5bf)).child("ACTIVE MODEL"))
                    .child(div().text_size(px(13.)).text_color(rgb(0xe3e9f3)).child(model)),
            )
            .child(
                v_flex()
                    .gap_2()
                    .child(div().text_size(px(11.)).text_color(rgb(0x8ca5bf)).child("WORKSPACE"))
                    .child(div().text_size(px(12.)).text_color(rgb(0xb8c7d7)).child(cwd)),
            )
            .child(div().flex_1())
            .child(div().text_size(px(11.)).text_color(rgb(0x6e7e92)).child("Cetas core / Posoco"))
            .child(div().text_size(px(11.)).text_color(rgb(0x8ca5bf)).child(status.clone()));

        let scroller = if self.rows.is_empty() {
            v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap_3()
                .child(div().text_size(px(27.)).text_color(rgb(0xe4ebf3)).child("What shall we build?"))
                .child(div().text_size(px(13.)).text_color(rgb(0x8794a9))
                    .child("Real Cetas agent. Native Markdown and GPU-rendered conversation."))
                .into_any_element()
        } else {
            MessageScroller::new("cetas-conversation", self.scroller.clone(), move |index, _, _| {
                let Some(row) = rows.get(index) else {
                    return div().into_any_element();
                };
                let tint = if row.role == "YOU" { 0x93b5ea }
                    else if row.role == "ERROR" { 0xf1a3a3 }
                    else if row.role == "TOOL" { 0x9accb0 }
                    else { 0xbbcde3 };
                v_flex()
                    .id(("cetas-row", row.id))
                    .min_w_0()
                    .p_4()
                    .gap_2()
                    .child(div().text_size(px(10.)).text_color(rgb(tint)).child(row.role.clone()))
                    .child(TextView::new(&row.markdown).selectable(true).stream_fade(true))
                    .into_any_element()
            })
            .w_full()
            .h_full()
            .into_any_element()
        };
        let composer = v_flex()
            .p_4()
            .gap_2()
            .border_t_1()
            .border_color(rgb(0x263143))
            .child(Textarea::new(&self.composer).bordered(true))
            .child(
                h_flex()
                    .items_center()
                    .justify_between()
                    .child(div().text_size(px(11.)).text_color(rgb(0x8493aa))
                        .child(if is_busy { "Streaming…" } else { "Markdown · tools · workspace" }))
                    .child(
                        h_flex()
                            .gap_2()
                            .child(
                                Button::new("stop").outline().label("Stop")
                                    .disabled(!is_busy)
                                    .on_click(cx.listener(|this, _, _, cx| this.interrupt(cx))),
                            )
                            .child(
                                Button::new("send").primary().label("Send")
                                    .disabled(!can_submit)
                                    .on_click(cx.listener(|this, _, window, cx| this.submit(window, cx))),
                            ),
                    ),
            );
        let central = v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .bg(rgb(0x161b24))
            .child(
                h_flex()
                    .items_center()
                    .justify_between()
                    .p_4()
                    .border_b_1()
                    .border_color(rgb(0x273141))
                    .child(div().text_size(px(14.)).text_color(rgb(0xe5edf5)).child("Conversation"))
                    .child(div().text_size(px(11.)).text_color(rgb(0x91a4b9)).child(status)),
            )
            .child(div().flex_1().min_h_0().child(scroller))
            .child(composer);
        h_flex().size_full().child(left).child(central)
    }
}

fn main() {
    // The Rust process owns the macOS UI event loop; the Cetas MoonBit main
    // runs in a dedicated thread in this same Mach-O executable.
    start_real_moonbit_core();
    application().with_assets(Assets).run(|cx| {
        gpui_kit::init(cx);
        cx.activate(true);
        gpui_kit::open_window(WindowOptions::default(), cx, CetasDesktop::view)
            .expect("open native Cetas window");
    });
}
