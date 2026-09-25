/// Batched scene boundary.
///
/// A Scene owns three flat buffers borrowed by Rust for one render call:
/// command words, style words, and UTF-8 text bytes.
///
/// Command v1 is 8 UInt words:
///   kind, x, y, width, height, text_offset, text_len, style_ref
///
/// Style v1 is 4 UInt words:
///   fg_color, bg_color, modifiers, reserved
///
/// A style_ref of 0 means default style. Non-zero values are one-based indexes
/// into the style table.

///|
pub(all) enum TuiColor {
  ColorInherit
  ColorReset
  ColorIndexed(UInt)
  ColorRgb(UInt, UInt, UInt)
}

///|
pub(all) struct TextStyle {
  fg : TuiColor
  bg : TuiColor
  modifiers : UInt
}

///|
pub fn TextStyle::new(
  fg? : TuiColor = ColorInherit,
  bg? : TuiColor = ColorInherit,
  modifiers? : UInt = 0U,
) -> TextStyle {
  { fg, bg, modifiers }
}

///|
pub fn modifier_bold() -> UInt {
  1U << 0
}

///|
pub fn modifier_dim() -> UInt {
  1U << 1
}

///|
pub fn modifier_italic() -> UInt {
  1U << 2
}

///|
pub fn modifier_underlined() -> UInt {
  1U << 3
}

///|
pub fn modifier_reversed() -> UInt {
  1U << 6
}

///|
fn TuiColor::encode(self : TuiColor) -> UInt {
  match self {
    ColorInherit => 0U
    ColorReset => 0x10000000U
    ColorIndexed(index) => 0x20000000U | (index & 0xffU)
    ColorRgb(red, green, blue) =>
      0x30000000U |
      ((red & 0xffU) << 16) |
      ((green & 0xffU) << 8) |
      (blue & 0xffU)
  }
}

///|
pub(all) struct Scene {
  words : FixedArray[UInt]
  styles : FixedArray[UInt]
  text : Bytes
}

///|
pub struct SceneBuilder {
  words : Array[UInt]
  styles : Array[UInt]
  text : Array[Byte]
}

///|
pub fn SceneBuilder::new() -> SceneBuilder {
  { words: [], styles: [], text: [] }
}

///|
fn SceneBuilder::push_command(
  self : SceneBuilder,
  kind : UInt,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
  text_offset : UInt,
  text_len : UInt,
  style_ref : UInt,
) -> Unit {
  self.words.push(kind)
  self.words.push(x)
  self.words.push(y)
  self.words.push(width)
  self.words.push(height)
  self.words.push(text_offset)
  self.words.push(text_len)
  self.words.push(style_ref)
}

///|
fn SceneBuilder::append_text(self : SceneBuilder, text : Bytes) -> UInt {
  let offset = self.text.length().reinterpret_as_uint()
  for i in 0..<text.length() {
    self.text.push(text[i])
  }
  offset
}

///|
fn SceneBuilder::push_style(
  self : SceneBuilder,
  style : TextStyle,
) -> UInt {
  let style_ref = (self.styles.length() / 4).reinterpret_as_uint() + 1U
  self.styles.push(style.fg.encode())
  self.styles.push(style.bg.encode())
  self.styles.push(style.modifiers)
  self.styles.push(0U)
  style_ref
}

///|
pub fn SceneBuilder::text(
  self : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
  text : Bytes,
) -> Unit {
  let offset = self.append_text(text)
  self.push_command(
    1U,
    x,
    y,
    width,
    height,
    offset,
    text.length().reinterpret_as_uint(),
    0U,
  )
}

///|
pub fn SceneBuilder::text_styled(
  self : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
  text : Bytes,
  style : TextStyle,
) -> Unit {
  let offset = self.append_text(text)
  let style_ref = self.push_style(style)
  self.push_command(
    1U,
    x,
    y,
    width,
    height,
    offset,
    text.length().reinterpret_as_uint(),
    style_ref,
  )
}

///|
pub fn SceneBuilder::clear(
  self : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
) -> Unit {
  self.push_command(2U, x, y, width, height, 0U, 0U, 0U)
}

///|
pub fn SceneBuilder::cursor(
  self : SceneBuilder,
  x : UInt,
  y : UInt,
) -> Unit {
  self.push_command(3U, x, y, 0U, 0U, 0U, 0U, 0U)
}

///|
pub fn SceneBuilder::border(
  self : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
  title : Bytes,
  style : TextStyle,
) -> Unit {
  let offset = self.append_text(title)
  let style_ref = self.push_style(style)
  self.push_command(
    4U,
    x,
    y,
    width,
    height,
    offset,
    title.length().reinterpret_as_uint(),
    style_ref,
  )
}

///|
pub fn SceneBuilder::finish(self : SceneBuilder) -> Scene {
  {
    words: FixedArray::makei(self.words.length(), i => self.words[i]),
    styles: FixedArray::makei(self.styles.length(), i => self.styles[i]),
    text: Bytes::from_array(self.text),
  }
}

///|
pub fn Scene::validation() -> Scene {
  let builder = SceneBuilder::new()
  builder.text_styled(
    0U,
    0U,
    16U,
    1U,
    b"cetas-batch",
    TextStyle::new(
      fg=ColorRgb(10U, 200U, 100U),
      modifiers=modifier_bold(),
    ),
  )
  builder.border(
    0U,
    1U,
    16U,
    3U,
    b" Cetas ",
    TextStyle::new(fg=ColorIndexed(6U)),
  )
  builder.cursor(5U, 0U)
  builder.finish()
}

///|
pub fn validation_marker() -> Int {
  if layout_validation_marker() == 1 &&
    select_list_validation_marker() == 1 &&
    event_validation_marker() == 1 &&
    editor_validation_marker() == 1 &&
    overlay_validation_marker() == 1 &&
    transcript_validation_marker() == 1 &&
    tool_streaming_validation_marker() == 1 {
    1
  } else {
    0
  }
}
