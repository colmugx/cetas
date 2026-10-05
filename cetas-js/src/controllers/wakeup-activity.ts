/**
 * wakeup-activity.ts — host-side fold of the frozen `posoco.wakeup`
 * projection (requested/executing/satisfied/completed/failed/cancelled/
 * dropped). Pure state, no timers, no TUI: the shell renders it.
 *
 * One terminal per ticket: `satisfied`/`completed`/`failed`/`cancelled`/
 * `dropped` freeze the ticket, and any later event for it is a no-op.
 * `executing` is the display window — the ticket may carry the environment
 * envelope, which hosts show as an ambient signal (never as user-typed
 * input) and which survives transcript rebuilds because it is re-read from
 * this store on every render.
 */

import type { CoreWakeupEvent, CoreWakeupState } from "../core-events.ts";

const WAKEUP_TERMINAL_STATES: readonly CoreWakeupState[] = [
  "satisfied",
  "completed",
  "failed",
  "cancelled",
  "dropped",
];

export interface WakeupTicket {
  readonly ticket_id: string;
  readonly session: string;
  readonly tag: string;
  readonly extension_id: string;
  state: CoreWakeupState;
  enqueued_at: number;
  operation_id?: string;
  envelope?: string;
}

function isTerminal(state: CoreWakeupState): boolean {
  return WAKEUP_TERMINAL_STATES.includes(state);
}

export class WakeupActivityStore {
  private readonly tickets = new Map<string, WakeupTicket>();

  get(ticket_id: string): WakeupTicket | undefined {
    return this.tickets.get(ticket_id);
  }

  /**
   * Fold one parsed wakeup event; returns whether any state changed.
   * Unknown events open tickets, later events of a ticket update it until
   * its single terminal, and post-terminal repeats are ignored.
   */
  apply(event: CoreWakeupEvent): boolean {
    const existing = this.tickets.get(event.ticket_id);
    if (existing === undefined) {
      this.tickets.set(event.ticket_id, {
        ticket_id: event.ticket_id,
        session: event.session,
        tag: event.tag,
        extension_id: event.extension_id,
        state: event.state,
        enqueued_at: event.enqueued_at,
        ...(event.operation_id === undefined ? {} : { operation_id: event.operation_id }),
        ...(event.envelope === undefined ? {} : { envelope: event.envelope }),
      });
      return true;
    }
    if (isTerminal(existing.state)) return false;
    let changed = false;
    if (existing.state !== event.state) {
      existing.state = event.state;
      changed = true;
    }
    if (event.operation_id !== undefined && existing.operation_id !== event.operation_id) {
      existing.operation_id = event.operation_id;
      changed = true;
    }
    if (event.envelope !== undefined && existing.envelope !== event.envelope) {
      existing.envelope = event.envelope;
      changed = true;
    }
    return changed;
  }

  /** Tickets currently executing, first-requested first, scoped to a session. */
  executing(ownerSession?: string): readonly WakeupTicket[] {
    return [...this.tickets.values()].filter(
      (ticket) =>
        ticket.state === "executing" && this.inScope(ticket, ownerSession),
    );
  }

  clear(): void {
    this.tickets.clear();
  }

  private inScope(ticket: WakeupTicket, ownerSession?: string): boolean {
    return ownerSession === undefined || ticket.session === ownerSession;
  }
}
