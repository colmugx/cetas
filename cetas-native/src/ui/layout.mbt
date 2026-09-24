/// Pure MoonBit layout primitives.
///
/// Coordinates are terminal-cell UInt values so a Rect can lower into Scene
/// commands without another representation conversion.

///|
pub(all) struct Rect {
  x : UInt
  y : UInt
  width : UInt
  height : UInt
}

///|
pub fn Rect::new(
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
) -> Rect {
  { x, y, width, height }
}

///|
pub fn Rect::right(self : Rect) -> UInt {
  self.x + self.width
}

///|
pub fn Rect::bottom(self : Rect) -> UInt {
  self.y + self.height
}

///|
pub fn Rect::inset(self : Rect, margin : UInt) -> Rect {
  let horizontal = margin * 2U
  let vertical = margin * 2U
  if horizontal >= self.width || vertical >= self.height {
    return { x: self.x, y: self.y, width: 0U, height: 0U }
  }
  {
    x: self.x + margin,
    y: self.y + margin,
    width: self.width - horizontal,
    height: self.height - vertical,
  }
}

///|
pub fn Rect::centered_percent(
  self : Rect,
  width_percent : UInt,
  height_percent : UInt,
) -> Rect {
  let wp = if width_percent > 100U { 100U } else { width_percent }
  let hp = if height_percent > 100U { 100U } else { height_percent }
  let width = self.width * wp / 100U
  let height = self.height * hp / 100U
  {
    x: self.x + (self.width - width) / 2U,
    y: self.y + (self.height - height) / 2U,
    width,
    height,
  }
}

///|
pub fn layout_validation_marker() -> Int {
  let outer = Rect::new(0U, 0U, 80U, 24U)
  let centered = outer.centered_percent(76U, 70U).inset(1U)
  if centered.x == 10U &&
    centered.y == 5U &&
    centered.width == 58U &&
    centered.height == 14U {
    1
  } else {
    0
  }
}
