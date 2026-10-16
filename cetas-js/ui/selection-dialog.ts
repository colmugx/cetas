import { SelectList, Text, type Component, type OverlayHandle, type SelectListTheme } from "@earendil-works/pi-tui";
import type { ModalVeilHost } from "./modal-mask.ts";
import { theme } from "./theme.ts";

interface DialogOptions<T extends string> {
  title: string;
  items: readonly { value: T; label: string; description?: string }[];
  width?: number | `${number}%`;
  maxHeight?: number | `${number}%`;
  onSelect(value: T): void;
  onCancel(): void;
}

class SelectionPanel implements Component {
  constructor(private readonly title: Text, private readonly list: SelectList) {}
  render(width: number): string[] { return [...this.title.render(width), ...this.list.render(width)]; }
  handleInput(data: string): void { this.list.handleInput(data); }
  invalidate(): void { this.title.invalidate(); this.list.invalidate(); }
}

/** Presentation only. The caller retains ownership of its command lease. */
export class SelectionDialog {
  private handle?: OverlayHandle;
  constructor(
    private readonly tui: Pick<ModalVeilHost, "showOverlay" | "requestRender">,
    private readonly listTheme: SelectListTheme,
  ) {}
  get isActive(): boolean { return this.handle !== undefined; }
  open<T extends string>(options: DialogOptions<T>): void {
    if (this.isActive) throw new Error("selection dialog is already open");
    if (options.items.length === 0) throw new Error("selection dialog requires entries");
    const list = new SelectList([...options.items], Math.min(8, options.items.length), this.listTheme);
    let settled = false;
    const finish = (): boolean => {
      if (settled) return false;
      settled = true;
      this.hide();
      return true;
    };
    list.onCancel = () => { if (finish()) options.onCancel(); };
    list.onSelect = (item) => { if (finish()) options.onSelect(item.value as T); };
    const panel = new SelectionPanel(new Text(theme.brandBold(options.title), 1, 1), list);
    this.handle = this.tui.showOverlay(panel, {
      width: options.width ?? "56%",
      maxHeight: options.maxHeight ?? "60%",
      anchor: "center",
      margin: 1,
    });
    this.tui.requestRender();
  }
  hide(): void {
    const handle = this.handle;
    this.handle = undefined;
    handle?.hide();
  }
}
