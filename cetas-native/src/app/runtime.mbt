/// MoonBit-owned terminal runtime loop seam.
///
/// Rust owns terminal mechanics only. This runtime performs one deterministic
/// tick at a time: pull pending UiRequests, poll Crossterm through Terminal,
/// apply focused-UI precedence, surface shell actions to the caller, flush
/// finalized transcript rows into real scrollback, and paint only live state.

///|
pub(all) struct RuntimeInputState {
  now_ms : UInt64
  editor_has_text : Bool
  in_turn : Bool
  compact_pending : Bool
  command_busy : Bool
  dismissible_overlay_visible : Bool
}

///|
pub(all) enum RuntimeEvent {
  RuntimeIdle
  RuntimeUiUpdated
  RuntimeUiSettled
  RuntimeRewindAction(@ui.RewindPickerAction)
  RuntimeEditorKey(@ui.TerminalEvent)
  RuntimeShellAction(ShellInputAction)
  RuntimePaste(String)
  RuntimeResize(UInt, UInt)
  RuntimeFocus(Bool)
  RuntimeTerminalError(Int)
} derive(Eq)

///|
pub extend RuntimeEvent with Eq::{equal, not_equal}

///|
pub struct NativeRuntime {
  terminal : @ui.Terminal
  shell : NativeShell
  input : NativeInputRouter
  editor : @ui.EditorModel
  rewind : @ui.RewindPickerModel
  autocomplete : AutocompletePopupModel
}

///|
pub fn NativeRuntime::new(
  terminal : @ui.Terminal,
  shell : NativeShell,
  input : NativeInputRouter,
  editor : @ui.EditorModel,
  rewind : @ui.RewindPickerModel,
) -> NativeRuntime {
  {
    terminal,
    shell,
    input,
    editor,
    rewind,
    autocomplete: AutocompletePopupModel::new(),
  }
}

///|
pub fn NativeRuntime::editor(self : NativeRuntime) -> @ui.EditorModel {
  self.editor
}

///|
fn NativeRuntime::open_autocomplete(
  self : NativeRuntime,
  prefix : String,
  items : Array[@ui.SelectItem],
) -> Bool {
  self.autocomplete.open(prefix, items)
}

///|
fn NativeRuntime::close_autocomplete(self : NativeRuntime) -> Unit {
  self.autocomplete.close()
}

///|
pub fn NativeRuntime::is_open(self : NativeRuntime) -> Bool {
  self.terminal.is_open()
}

///|
/// Shutdown ordering is intentional: release parked agent-side UI requests
/// before closing the terminal resource they depend on.
pub fn NativeRuntime::close(self : NativeRuntime) -> Unit {
  self.input.close_ui()
  self.terminal.close()
}

///|
pub fn NativeRuntime::close_ui_only(self : NativeRuntime) -> Unit {
  self.input.close_ui()
}

///|
pub fn NativeRuntime::auth_ui(self : NativeRuntime) -> NativeAuthUi {
  self.input.auth_ui()
}

///|
/// Flush finalized rows exactly once into real terminal scrollback.
pub fn NativeRuntime::flush_scrollback(self : NativeRuntime) -> Int {
  let ready = self.shell.take_scrollback_ready()
  for row in ready {
    let status = if row.kind == @ui.TranscriptAssistant {
      self.terminal.insert_before_markdown(row.text)
    } else {
      self.terminal.insert_before(self.shell.scrollback_text(row))
    }
    if status != 0 {
      return status
    }
  }
  0
}

///|
fn append_runtime_text(
  builder : @ui.SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  text : String,
) -> Unit {
  builder.text(x, y, width, 1U, @utf8.encode(text))
}

///|
fn append_multiline_runtime_text(
  builder : @ui.SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
  text : String,
) -> UInt {
  let mut row_y = y
  for line in text.split("\n") {
    if row_y >= height {
      break
    }
    append_runtime_text(builder, x, row_y, width, line.to_owned())
    row_y += 1U
  }
  row_y
}

///|
fn append_extension_render_lines(
  builder : @ui.SceneBuilder,
  input : NativeInputRouter,
  mut_y : UInt,
  width : UInt,
  height : UInt,
  max_rows : UInt,
) -> UInt {
  let mut y = mut_y
  let count = input.render_line_count()
  let mut shown = 0U
  let start = if count > max_rows.reinterpret_as_int() {
    count - max_rows.reinterpret_as_int()
  } else {
    0
  }
  for index in start..<count {
    if y >= height || shown >= max_rows {
      break
    }
    match input.render_line(index) {
      Some(line) => append_runtime_text(builder, 0U, y, width, line)
      None => ()
    }
    y += 1U
    shown += 1U
  }
  y
}

///|
fn append_editor_scene(
  builder : @ui.SceneBuilder,
  editor : @ui.EditorModel,
  mut_y : UInt,
  width : UInt,
  height : UInt,
  focused : Bool,
) -> UInt {
  let mut y = mut_y
  let cursor = editor.cursor()
  for index in 0..<editor.line_count() {
    if y >= height {
      break
    }
    guard editor.line(index) is Some(line) else { continue }
    let prefix = if index == 0 { "> " } else { "  " }
    append_runtime_text(builder, 0U, y, width, prefix + line)
    if focused && index == cursor.line {
      builder.cursor(2U + cursor.column.reinterpret_as_uint(), y)
    }
    y += 1U
  }
  y
}

///|
fn build_runtime_scene(
  shell : NativeShell,
  input : NativeInputRouter,
  editor : @ui.EditorModel,
  rewind : @ui.RewindPickerModel,
  autocomplete : AutocompletePopupModel,
  width : UInt,
  height : UInt,
) -> @ui.Scene {
  let builder = @ui.SceneBuilder::new()
  builder.clear(0U, 0U, width, height)

  // Normal query/answer mode is bottom-anchored: the editor and one-line
  // status stay stable while Ratatui wraps the live answer in all rows above
  // them. Finalized rows leave this viewport through insert_before.
  if !input.ui_active() && !rewind.is_active() {
    if height == 0U {
      return builder.finish()
    }
    let status_y = height - 1U
    let requested_editor_rows = editor.line_count().reinterpret_as_uint()
    let available_editor_rows = status_y
    let editor_rows = if requested_editor_rows < available_editor_rows {
      requested_editor_rows
    } else {
      available_editor_rows
    }
    let editor_y = status_y - editor_rows
    let popup_capacity = if editor_y < 8U { editor_y } else { 8U }
    let requested_popup_rows = autocomplete.item_count().reinterpret_as_uint()
    let popup_rows = if requested_popup_rows < popup_capacity {
      requested_popup_rows
    } else {
      popup_capacity
    }
    let popup_y = editor_y - popup_rows
    let render_capacity = if popup_y < 4U { popup_y } else { 4U }
    let requested_render_rows = input.render_line_count().reinterpret_as_uint()
    let render_rows = if requested_render_rows < render_capacity {
      requested_render_rows
    } else {
      render_capacity
    }
    let render_y = popup_y - render_rows
    shell.append_live_block_scene(builder, 0U, 0U, width, render_y)
    if render_rows > 0U {
      ignore(
        append_extension_render_lines(
          builder, input, render_y, width, popup_y, render_rows,
        ),
      )
    }
    if popup_rows > 0U {
      autocomplete.append_scene(builder, 0U, popup_y, width, popup_rows)
    }
    ignore(
      append_editor_scene(builder, editor, editor_y, width, status_y, true),
    )
    let status = match shell.status() {
      ShellIdle => "idle"
      ShellWorking(detail) => detail
      ShellFailed(detail) => "error: " + detail
    }
    append_runtime_text(builder, 0U, status_y, width, "· " + status)
    return builder.finish()
  }

  let mut y = shell.append_live_scene(builder, 0U, 0U, width)
  if input.render_line_count() > 0 && y < height {
    y = append_extension_render_lines(builder, input, y, width, height, 4U)
  }
  if input.ui_active() {
    guard input.ui_prompt() is Some(prompt) else { return builder.finish() }
    y = append_multiline_runtime_text(builder, 0U, y, width, height, prompt)
    match input.ui_kind() {
      Some(UiPanelInput) | Some(UiPanelSecretInput) =>
        if y < height {
          let value = match input.ui_input_text() {
            Some(text) => text
            None => ""
          }
          append_runtime_text(builder, 0U, y, width, "> " + value)
        }
      Some(UiPanelConfirm) | Some(UiPanelSelect) => {
        let selected = match input.ui_selected_index() {
          Some(index) => index
          None => -1
        }
        let items : Array[String] = []
        for index in 0..<input.ui_option_count() {
          match input.ui_option_label(index) {
            Some(label) => items.push(label)
            None => ()
          }
        }
        let remaining = if y < height { height - y } else { 0U }
        builder.select_list(0U, y, width, remaining, items, selected)
        let item_rows = items.length().reinterpret_as_uint()
        y += if item_rows < remaining { item_rows } else { remaining }
      }
      None => ()
    }
  }

  if rewind.is_active() && !input.ui_active() {
    if y < height {
      append_runtime_text(builder, 0U, y, width, "Rewind to:")
      y += 1U
    }
    let remaining = if y < height { height - y } else { 0U }
    rewind.append_scene(builder, 0U, y, width, remaining)
    let point_rows = rewind.point_count().reinterpret_as_uint()
    y += if point_rows < remaining { point_rows } else { remaining }
  } else {
    y = append_editor_scene(
      builder,
      editor,
      y,
      width,
      height,
      !input.ui_active(),
    )
  }

  if y < height {
    let status = match shell.status() {
      ShellIdle => "idle"
      ShellWorking(detail) => detail
      ShellFailed(detail) => "error: " + detail
    }
    append_runtime_text(builder, 0U, y, width, "· " + status)
  }

  builder.finish()
}

///|
/// Paint current live state into the inline viewport.
///
/// Finalized transcript rows are never painted here: they move through
/// `flush_scrollback`, preserving one-owner rendering.
pub fn NativeRuntime::render(self : NativeRuntime) -> Int {
  let (size_status, size) = self.terminal.viewport_size()
  if size_status != 0 {
    return size_status
  }
  self.terminal.render(
    build_runtime_scene(
      self.shell,
      self.input,
      self.editor,
      self.rewind,
      self.autocomplete,
      size[0],
      size[1],
    ),
  )
}

///|
pub fn runtime_validation_marker() -> Int {
  let shell = NativeShell::new()
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  let rewind = @ui.RewindPickerModel::new()
  let scene = build_runtime_scene(
    shell,
    router,
    editor,
    rewind,
    AutocompletePopupModel::new(),
    40U,
    3U,
  )
  if scene.words.length() == 32 && scene.text == @utf8.encode("> · idle") {
    1
  } else {
    0
  }
}

///|
/// Poll one normalized terminal event and route it without applying business
/// side effects. The caller owns actions such as shutdown, interrupt, rewind,
/// editor mutation, or toggling presentation settings.
pub fn NativeRuntime::poll_once(
  self : NativeRuntime,
  timeout_ms : UInt64,
  state : RuntimeInputState,
) -> RuntimeEvent {
  ignore(self.input.pump_ui())
  if self.input.ui_active() || self.rewind.is_active() {
    self.autocomplete.close()
  }

  let (status, event) = self.terminal.poll(timeout_ms)
  if status == 1 {
    return RuntimeIdle
  }
  if status != 0 {
    return RuntimeTerminalError(status)
  }
  guard event is Some(value) else { return RuntimeTerminalError(2) }

  match value.kind_value() {
    @ui.EventKey =>
      if self.input.ui_active() {
        match
          self.input.route_key(
            value,
            state.now_ms,
            state.editor_has_text,
            state.in_turn,
            state.compact_pending,
            state.command_busy,
            state.dismissible_overlay_visible,
          ) {
          RouteUiActive => RuntimeUiUpdated
          RouteUiSettled => RuntimeUiSettled
          RouteShell(InputPass) => RuntimeEditorKey(value)
          RouteShell(action) => RuntimeShellAction(action)
        }
      } else if self.rewind.is_active() {
        RuntimeRewindAction(self.rewind.handle_key(value))
      } else if self.autocomplete.is_active() {
        match self.autocomplete.handle_key(value) {
          AutocompleteChanged | AutocompleteCancelled => RuntimeUiUpdated
          AutocompleteAccepted(prefix, replacement) => {
            ignore(self.editor.apply_completion(prefix, replacement))
            RuntimeUiUpdated
          }
          AutocompleteUnhandled =>
            match
              self.input.route_key(
                value,
                state.now_ms,
                state.editor_has_text,
                state.in_turn,
                state.compact_pending,
                state.command_busy,
                state.dismissible_overlay_visible,
              ) {
              RouteUiActive => RuntimeUiUpdated
              RouteUiSettled => RuntimeUiSettled
              RouteShell(InputPass) => RuntimeEditorKey(value)
              RouteShell(action) => RuntimeShellAction(action)
            }
        }
      } else {
        match
          self.input.route_key(
            value,
            state.now_ms,
            state.editor_has_text,
            state.in_turn,
            state.compact_pending,
            state.command_busy,
            state.dismissible_overlay_visible,
          ) {
          RouteUiActive => RuntimeUiUpdated
          RouteUiSettled => RuntimeUiSettled
          RouteShell(InputPass) => RuntimeEditorKey(value)
          RouteShell(action) => RuntimeShellAction(action)
        }
      }
    @ui.EventPaste =>
      match self.terminal.event_text() {
        None => RuntimeTerminalError(2)
        Some(bytes) => {
          let text = @utf8.decode(bytes) catch {
            _ => return RuntimeTerminalError(2)
          }
          if self.input.route_paste(text) {
            RuntimeUiUpdated
          } else if self.rewind.is_active() {
            RuntimeIdle
          } else {
            RuntimePaste(text)
          }
        }
      }
    @ui.EventResize => RuntimeResize(value.width, value.height)
    @ui.EventFocusIn => RuntimeFocus(true)
    @ui.EventFocusOut => RuntimeFocus(false)
    @ui.EventNone | @ui.EventMouse | @ui.EventUnknown(_) => RuntimeIdle
  }
}
