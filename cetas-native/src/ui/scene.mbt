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
pub fn Scene::validation() -> Scene {
  {
    words: [
      1U, 0U, 0U, 16U, 1U, 0U, 11U, 0U,
      3U, 5U, 0U, 0U, 0U, 0U, 0U, 0U,
    ],
    text: b"cetas-batch",
  }
}

///|
pub fn validation_marker() -> Int {
  1
}
