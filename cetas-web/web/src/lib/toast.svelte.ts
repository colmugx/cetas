export type ToastKind = "info" | "success" | "error";

export type Toast = {
  id: number;
  kind: ToastKind;
  text: string;
};

let nextId = 1;

class ToastStore {
  toasts = $state<Toast[]>([]);

  show(kind: ToastKind, text: string, ttlMs = 4000) {
    const id = nextId++;
    this.toasts = [...this.toasts, { id, kind, text }];
    setTimeout(() => this.dismiss(id), ttlMs);
  }

  dismiss(id: number) {
    this.toasts = this.toasts.filter((toast) => toast.id !== id);
  }
}

export const toastStore = new ToastStore();

export function toast(kind: ToastKind, text: string, ttlMs?: number) {
  toastStore.show(kind, text, ttlMs);
}
