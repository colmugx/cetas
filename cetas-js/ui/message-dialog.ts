import { Text, type Component, type OverlayHandle } from "@earendil-works/pi-tui";
import type { ModalVeilHost } from "./modal-mask.ts";
import { OverlayChoice } from "./overlay-choice.ts";

class DismissiblePanel implements Component {
  constructor(private readonly body: Text, private readonly close: () => void) {}
  render(width: number): string[] { return this.body.render(width); }
  handleInput(_data: string): void { this.close(); }
  invalidate(): void { this.body.invalidate(); }
}

/** Any keystroke dismisses the notice. Abort/shutdown dismisses it too. */
export class MessageDialog {
  private handle?: OverlayHandle;
  private readonly choice = new OverlayChoice<void>();
  constructor(private readonly tui: Pick<ModalVeilHost, "showOverlay" | "requestRender">) {}

  async show(message: string, signal?: AbortSignal): Promise<void> {
    await this.choice.wait(() => {
      if (this.handle !== undefined) throw new Error("message dialog is already open");
      const panel = new DismissiblePanel(
        new Text(message.slice(0, 16000), 1, 1),
        () => this.hide(),
      );
      this.handle = this.tui.showOverlay(panel, {
        width: "76%", maxHeight: "78%", anchor: "center", margin: 1,
      });
      this.tui.requestRender();
    }, () => this.hide(), signal);
  }

  hide(): void {
    this.choice.cancel();
    const handle = this.handle;
    this.handle = undefined;
    handle?.hide();
    this.tui.requestRender();
  }
}
