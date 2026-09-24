/// Batched scene boundary.
///
/// A Scene owns the flat command words and UTF-8 payload arena passed to the
/// native renderer for one frame. Rust borrows both buffers only for the
/// duration of the render call.
///
/// Command v1 is 8 UInt words:
///   kind, x, y, width, height, text_offset, text_len, flags

///|
pub(all) struct Scene {
  words : FixedArray[UInt]
  text : Bytes
}

///|
pub struct SceneBuilder {
  words : Array[UInt]
  text : Array[Byte]
}

///|
pub fn SceneBuilder::new() -> SceneBuilder {
  { words: [], text: [] }
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
  flags : UInt,
) -> Unit {
  self.words.push(kind)
  self.words.push(x)
  self.words.push(y)
  self.words.push(width)
  self.words.push(height)
  self.words.push(text_offset)
  self.words.push(text_len)
  self.words.push(flags)
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
pub fn SceneBuilder::finish(self : SceneBuilder) -> Scene {
  {
    words: FixedArray::makei(self.words.length(), i => self.words[i]),
    text: Bytes::from_array(self.text),
  }
}

///|
pub fn Scene::validation() -> Scene {
  let builder = SceneBuilder::new()
  builder.text(0U, 0U, 16U, 1U, b"cetas-batch")
  builder.cursor(5U, 0U)
  builder.finish()
}

///|
pub fn validation_marker() -> Int {
  1
}
