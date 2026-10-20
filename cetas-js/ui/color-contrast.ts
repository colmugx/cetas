/** Shared sRGB contrast primitives for semantic activity colors and UI surfaces. */
import type { RgbColor } from "@earendil-works/pi-tui";

function channel(value: number): number {
  const v = value / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

export function relativeLuminance(color: RgbColor): number {
  return channel(color.r) * 0.2126 + channel(color.g) * 0.7152 + channel(color.b) * 0.0722;
}

export function contrastRatio(a: RgbColor, b: RgbColor): number {
  const first = relativeLuminance(a), second = relativeLuminance(b);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

export function mixColor(base: RgbColor, tint: RgbColor, opacity: number): RgbColor {
  const blend = (a: number, b: number): number =>
    Math.round(a * (1 - opacity) + b * opacity);
  return {
    r: blend(base.r, tint.r),
    g: blend(base.g, tint.g),
    b: blend(base.b, tint.b),
  };
}
