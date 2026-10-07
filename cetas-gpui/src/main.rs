mod bridge;

use gpui_kit::component::{
    ActiveTheme as _,
    button::{Button, ButtonVariants as _},
    h_flex,
    input::{Input, InputState},
    message_scroller::{MessageScroller, MessageScrollerState},
    text::{TextView, TextViewState},
    v_flex,
};
use gpui_kit::*;
use serde_json::{json, Value};
use std::{rc::Rc, time::Duration};

#[derive(Clone)]
enum TranscriptRow {
    User(String),
    Assistant(Entity<TextViewState>),
    Reasoning(String),
    Tool { name: String, detail: String, error: bool },
    Notice(String),
}

struct CetasDesktop {
    scroller: Entity<MessageScrollerState>,
    composer: Entity<InputState>,
    rows: Vec<TranscriptRow>,
    active_assistant: Option<usize>,
    active_reasoning: Option<usize>,
    busy: bool,
    status: String,
    model: String,
    cwd: String,
    session_id: String,
    _event_task: Task<()>,
}

impl CetasDesktop {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let scroller = cx.new(|cx| MessageScrollerState::new(0, cx));
        cx.observe(&scroller, |_, _, cx| cx.notify()).detach();
        let composer =
            cx.new(|cx| InputState::new(window, cx).placeholder("Ask Cetas anything…"));

        let event_task = cx.spawn(async move |view, cx| loop {
            cx.background_executor().timer(Duration::from_millis(16)).await;
            if view
                .update(cx, |this, cx| {
                    for event in bridge::drain_events() {
                        this.apply_core_event(event, cx);
                    }
                })
                .is_err()
            {
                break;
            }
        });

        Self {
            scroller,
            composer,
            rows: Vec::new(),
            active_assistant: None,
            active_reasoning: None,
            busy: false,
            status: "starting MoonBit core…".into(),
            model: "—".into(),
            cwd: "—".into(),
            session_id: "—".into(),
            _event_task: event_task,
        }
    }

    fn append_row(&mut self, row: TranscriptRow, cx: &mut Context<Self>) -> usize {
        let index = self.rows.len();
        self.rows.push(row);
        self.scroller.update(cx, |state, cx| {
            let _ = state.append(1, cx);
        });
        cx.notify();
        index
    }

    fn remeasure(&self, index: usize, cx: &mut Context<Self>) {
        self.scroller.update(cx, |state, cx| {
            let _ = state.remeasure_items(index..index + 1, cx);
        });
        cx.notify();
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            bridge::send_command(json!({"type": "turn.abort"}));
            return;
        }
        let prompt = self.composer.read(cx).value().to_string();
        if prompt.trim().is_empty() {
            return;
        }
        self.composer
            .update(cx, |input, cx| input.set_value("", window, cx));
        bridge::send_command(json!({"type": "turn.start", "prompt": prompt}));
        self.status = "sending…".into();
        cx.notify();
    }

    fn text<'a>(event: &'a Value, key: &str) -> &'a str {
        event.get(key).and_then(Value::as_str).unwrap_or("")
    }

    fn apply_core_event(&mut self, event: Value, cx: &mut Context<Self>) {
        match Self::text(&event, "type") {
            "core.ready" => self.status = "ready".into(),
            "runtime.unavailable" => {
                self.status = "needs setup".into();
                let message = Self::text(&event, "message").to_owned();
                self.append_row(
                    TranscriptRow::Notice(format!("Cetas core unavailable\n\n{message}")),
                    cx,
                );
            }
            "session.snapshot" => {
                self.model = Self::text(&event, "model").to_owned();
                self.cwd = Self::text(&event, "cwd").to_owned();
                self.session_id = Self::text(&event, "session_id").to_owned();
                self.busy = event.get("busy").and_then(Value::as_bool).unwrap_or(false);
                self.status = if self.busy { "working…" } else { "ready" }.into();
            }
            "turn.accepted" => {
                self.busy = true;
                self.status = "working…".into();
                self.active_assistant = None;
                self.active_reasoning = None;
                self.append_row(
                    TranscriptRow::User(Self::text(&event, "prompt").to_owned()),
                    cx,
                );
            }
            "assistant.reasoning_delta" => {
                let delta = Self::text(&event, "delta");
                let index = match self.active_reasoning {
                    Some(index) => index,
                    None => {
                        let index = self.append_row(TranscriptRow::Reasoning(String::new()), cx);
                        self.active_reasoning = Some(index);
                        index
                    }
                };
                if let Some(TranscriptRow::Reasoning(text)) = self.rows.get_mut(index) {
                    text.push_str(delta);
                }
                self.remeasure(index, cx);
            }
            "assistant.text_delta" => {
                let delta = Self::text(&event, "delta");
                let index = match self.active_assistant {
                    Some(index) => index,
                    None => {
                        let state = cx.new(|cx| TextViewState::markdown("", cx));
                        let index = self.append_row(TranscriptRow::Assistant(state), cx);
                        self.active_assistant = Some(index);
                        index
                    }
                };
                if let Some(TranscriptRow::Assistant(state)) = self.rows.get(index) {
                    state.update(cx, |state, cx| state.push_str(delta, cx));
                }
                self.remeasure(index, cx);
            }
            "tool.started" => {
                let name = Self::text(&event, "tool_name").to_owned();
                let detail = event
                    .get("arguments")
                    .map(Value::to_string)
                    .unwrap_or_default();
                self.append_row(
                    TranscriptRow::Tool {
                        name: format!("{name} · running"),
                        detail,
                        error: false,
                    },
                    cx,
                );
            }
            "tool.completed" => {
                let name = Self::text(&event, "tool_name").to_owned();
                let detail = Self::text(&event, "result").to_owned();
                let error = event.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                self.append_row(
                    TranscriptRow::Tool {
                        name: if error {
                            format!("{name} · failed")
                        } else {
                            format!("{name} · completed")
                        },
                        detail,
                        error,
                    },
                    cx,
                );
            }
            "turn.completed" => {
                if self.active_assistant.is_none() {
                    let text = Self::text(&event, "text");
                    if !text.is_empty() {
                        let state = cx.new(|cx| TextViewState::markdown(text, cx));
                        self.append_row(TranscriptRow::Assistant(state), cx);
                    }
                }
                self.busy = false;
                self.status = "ready".into();
                self.active_assistant = None;
                self.active_reasoning = None;
            }
            "turn.failed" => {
                self.busy = false;
                self.status = "failed".into();
                self.append_row(
                    TranscriptRow::Notice(format!(
                        "Turn failed\n\n{}",
                        Self::text(&event, "message")
                    )),
                    cx,
                );
                self.active_assistant = None;
                self.active_reasoning = None;
            }
            "turn.abort_result" => {
                self.append_row(
                    TranscriptRow::Notice(format!(
                        "Abort: {}",
                        Self::text(&event, "outcome")
                    )),
                    cx,
                );
            }
            "core.warning" | "protocol.error" => {
                self.append_row(
                    TranscriptRow::Notice(Self::text(&event, "message").to_owned()),
                    cx,
                );
            }
            _ => {}
        }
        cx.notify();
    }

    fn render_row(row: TranscriptRow, index: usize, cx: &mut App) -> AnyElement {
        match row {
            TranscriptRow::User(text) => h_flex()
                .id(("user-row", index))
                .w_full()
                .justify_end()
                .child(
                    div()
                        .max_w(rems(38.))
                        .px_4()
                        .py_3()
                        .rounded_xl()
                        .bg(cx.theme().muted)
                        .text_sm()
                        .child(text),
                )
                .into_any_element(),
            TranscriptRow::Assistant(state) => div()
                .id(("assistant-row", index))
                .w_full()
                .min_w_0()
                .child(TextView::new(&state).selectable(true).stream_fade(true))
                .into_any_element(),
            TranscriptRow::Reasoning(text) => v_flex()
                .id(("reasoning-row", index))
                .w_full()
                .gap_1()
                .child(
                    div()
                        .text_xs()
                        .font_semibold()
                        .text_color(cx.theme().muted_foreground)
                        .child("REASONING"),
                )
                .child(
                    div()
                        .pl_3()
                        .border_l_2()
                        .border_color(cx.theme().border)
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .child(text),
                )
                .into_any_element(),
            TranscriptRow::Tool { name, detail, error } => v_flex()
                .id(("tool-row", index))
                .w_full()
                .rounded_xl()
                .border_1()
                .border_color(if error { cx.theme().danger } else { cx.theme().border })
                .overflow_hidden()
                .child(
                    div()
                        .px_3()
                        .py_2()
                        .bg(cx.theme().muted)
                        .text_xs()
                        .font_semibold()
                        .child(name),
                )
                .child(
                    div()
                        .px_3()
                        .py_3()
                        .text_sm()
                        .text_color(cx.theme().muted_foreground)
                        .child(detail),
                )
                .into_any_element(),
            TranscriptRow::Notice(text) => div()
                .id(("notice-row", index))
                .w_full()
                .px_3()
                .py_2()
                .rounded_lg()
                .bg(cx.theme().muted)
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child(text)
                .into_any_element(),
        }
    }
}

impl Render for CetasDesktop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Rc::new(self.rows.clone());
        let model = self.model.clone();
        let cwd = self.cwd.clone();
        let status = self.status.clone();
        let session = self.session_id.clone();

        h_flex()
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                v_flex()
                    .w(rems(15.5))
                    .h_full()
                    .border_r_1()
                    .border_color(cx.theme().sidebar_border)
                    .bg(cx.theme().sidebar)
                    .text_color(cx.theme().sidebar_foreground)
                    .child(
                        h_flex()
                            .h(rems(3.6))
                            .px_4()
                            .items_center()
                            .gap_2()
                            .border_b_1()
                            .border_color(cx.theme().sidebar_border)
                            .child(
                                div()
                                    .size(px(24.))
                                    .rounded_lg()
                                    .bg(cx.theme().sidebar_primary)
                                    .text_color(cx.theme().sidebar_primary_foreground)
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .font_semibold()
                                    .child("C"),
                            )
                            .child(div().font_semibold().child("Cetas")),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_h_0()
                            .p_3()
                            .gap_3()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(cx.theme().sidebar_foreground.opacity(0.65))
                                    .child("CURRENT SESSION"),
                            )
                            .child(
                                div()
                                    .rounded_lg()
                                    .bg(cx.theme().sidebar_accent)
                                    .p_3()
                                    .text_xs()
                                    .child(session),
                            )
                            .child(
                                div()
                                    .mt_2()
                                    .text_xs()
                                    .text_color(cx.theme().sidebar_foreground.opacity(0.65))
                                    .child("MODEL"),
                            )
                            .child(div().text_sm().child(model))
                            .child(
                                div()
                                    .mt_2()
                                    .text_xs()
                                    .text_color(cx.theme().sidebar_foreground.opacity(0.65))
                                    .child("WORKSPACE"),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(cx.theme().sidebar_foreground.opacity(0.65))
                                    .child(cwd),
                            ),
                    ),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(
                        h_flex()
                            .h(rems(3.6))
                            .px_6()
                            .items_center()
                            .justify_between()
                            .border_b_1()
                            .border_color(cx.theme().border)
                            .child(
                                v_flex()
                                    .child(div().text_sm().font_semibold().child("Cetas Desktop"))
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(cx.theme().muted_foreground)
                                            .child("MoonBit core · GPUI native surface"),
                                    ),
                            )
                            .child(
                                div()
                                    .px_2()
                                    .py_1()
                                    .rounded_full()
                                    .bg(cx.theme().muted)
                                    .text_xs()
                                    .text_color(cx.theme().muted_foreground)
                                    .child(status),
                            ),
                    )
                    .child(
                        div().flex_1().min_h_0().child(
                            MessageScroller::new(
                                "cetas-transcript",
                                self.scroller.clone(),
                                move |index, _, cx| {
                                    let Some(row) = rows.get(index).cloned() else {
                                        return div().into_any_element();
                                    };
                                    div()
                                        .w_full()
                                        .px_8()
                                        .py_3()
                                        .child(
                                            div()
                                                .w_full()
                                                .max_w(rems(58.))
                                                .mx_auto()
                                                .child(Self::render_row(row, index, cx)),
                                        )
                                        .into_any_element()
                                },
                            )
                            .with_jump_button_label("Jump to latest")
                            .size_full(),
                        ),
                    )
                    .child(
                        div()
                            .w_full()
                            .px_8()
                            .pb_6()
                            .child(
                                h_flex()
                                    .w_full()
                                    .max_w(rems(58.))
                                    .mx_auto()
                                    .gap_2()
                                    .items_end()
                                    .rounded_xl()
                                    .border_1()
                                    .border_color(cx.theme().border)
                                    .p_2()
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .child(Input::new(&self.composer).appearance(false)),
                                    )
                                    .child(
                                        Button::new("send-or-abort")
                                            .when(self.busy, |button| button.danger())
                                            .when(!self.busy, |button| button.primary())
                                            .label(if self.busy { "Abort" } else { "Send" })
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.send(window, cx);
                                            })),
                                    ),
                            ),
                    ),
            )
    }
}

fn main() {
    bridge::start_moon_core();
    gpui_kit::application().run(|cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            window.set_window_title("Cetas");
            cx.new(|cx| CetasDesktop::new(window, cx))
        })
        .expect("failed to open Cetas window");
    });
}
