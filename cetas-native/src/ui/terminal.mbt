/// MoonBit-owned terminal resource wrapper.
///
/// Raw pointers stay in @native. Closing is idempotent and clears the stored
/// handle before returning to callers.

///|
pub struct Terminal {
  mut raw : @native.RawTui?
}

///|
pub fn Terminal::open_inline(rows : UInt) -> Terminal? {
  let raw = @native.open_inline(rows)
  if @native.is_null(raw) != 0 {
    return None
  }
  Some({ raw: Some(raw) })
}

///|
pub fn Terminal::is_open(self : Terminal) -> Bool {
  self.raw is Some(_)
}

///|
pub fn Terminal::close(self : Terminal) -> Unit {
  match self.raw {
    Some(raw) => {
      self.raw = None
      @native.close(raw)
    }
    None => ()
  }
}

///|
pub fn Terminal::suspend(self : Terminal) -> Int {
  match self.raw {
    Some(raw) => @native.suspend(raw)
    None => 2
  }
}

///|
pub fn Terminal::resume(self : Terminal) -> Int {
  match self.raw {
    Some(raw) => @native.resume(raw)
    None => 2
  }
}

///|
pub fn Terminal::render(self : Terminal, scene : Scene) -> Int {
  match self.raw {
    Some(raw) =>
      @native.render_scene(
        raw,
        scene.words,
        scene.words.length().reinterpret_as_uint(),
        scene.styles,
        scene.styles.length().reinterpret_as_uint(),
        scene.text,
        scene.text.length().reinterpret_as_uint(),
      )
    None => 2
  }
}

///|
pub fn Terminal::viewport_size(
  self : Terminal,
) -> (Int, FixedArray[UInt]) {
  let out : FixedArray[UInt] = FixedArray::make(2, 0U)
  let status = match self.raw {
    Some(raw) => @native.viewport_size(raw, out, 2U)
    None => 2
  }
  (status, out)
}

///|
pub fn Terminal::poll_raw(
  self : Terminal,
  timeout_ms : UInt64,
) -> (Int, FixedArray[UInt]) {
  let out : FixedArray[UInt] = FixedArray::make(14, 0U)
  let status = match self.raw {
    Some(raw) => @native.poll_words(raw, timeout_ms, out, 14U)
    None => 2
  }
  (status, out)
}


///|
pub fn Terminal::poll(
  self : Terminal,
  timeout_ms : UInt64,
) -> (Int, TerminalEvent?) {
  let (status, words) = self.poll_raw(timeout_ms)
  (status, decode_terminal_event(words))
}

///|
pub fn Terminal::event_text(self : Terminal) -> Bytes? {
  match self.raw {
    Some(raw) => {
      let len = @native.event_text_len(raw)
      let out : FixedArray[Byte] = FixedArray::make(
        len.reinterpret_as_int(),
        b'\x00',
      )
      if @native.event_text_copy(raw, out, len) == 0 {
        Some(Bytes::from_array(out))
      } else {
        None
      }
    }
    None => None
  }
}
