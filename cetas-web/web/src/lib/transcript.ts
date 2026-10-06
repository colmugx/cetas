/**
 * One rendered entry of a chat transcript. Shared by the live realtime path
 * and the persisted-transcript replay so both render identically.
 */
export type TranscriptItem =
  | { kind: "user"; turnId: string; text: string }
  | { kind: "assistant"; turnId: string; text: string; streaming: boolean }
  | { kind: "reasoning"; turnId: string; text: string }
  | {
      kind: "tool";
      turnId: string;
      callId: string;
      name: string;
      status: "running" | "done" | "error";
      args: Record<string, unknown>;
      result: string;
    }
  | { kind: "error"; turnId: string; text: string };
