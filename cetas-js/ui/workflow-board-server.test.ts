import { afterEach, expect, test } from "bun:test";
import type { CetasApplication } from "../src/app/application.ts";
import {
  closeWorkflowBoards,
  openWorkflowBoard,
} from "./workflow-board-server.ts";

const SNAPSHOT = JSON.stringify({
  type: "snapshot",
  protocol_version: 1,
  last_seq: 0,
  board_revision: 7,
  payload: {
    board: {
      revision: 7,
      tasks: [
        {
          id: "task-1",
          title: "Wire task",
          description: "From the bridge",
          stage: "ready",
          priority: "high",
          definition_of_done: [],
          dependencies: [],
          created_at_ms: 1,
          updated_at_ms: 2,
          ready_since_ms: null,
        },
      ],
      attempts: [],
    },
    events: [],
  },
});

const RESULT = JSON.stringify({
  type: "command_result",
  command_id: "cmd-1",
  accepted: true,
  error: null,
  current_revision: 8,
});

function mockApp(): CetasApplication {
  return {
    invokeCommand: async (id: string) => {
      if (id === "board.wire.ready") {
        return JSON.stringify({ type: "success", structured: {} });
      }
      if (id === "board.wire.snapshot") {
        return JSON.stringify({ type: "success", structured: { frame: SNAPSHOT } });
      }
      if (id === "board.wire.command") {
        return JSON.stringify({ type: "success", structured: { frame: RESULT } });
      }
      if (id === "board.ticket.state") {
        return JSON.stringify({
          type: "success",
          structured: {
            questions: [
              {
                id: "q1",
                task_id: "task-1",
                question: "Which path should the worker take?",
                kind: "input",
                options: [],
                asked_at: 1,
              },
            ],
            runs: [],
          },
        });
      }
      if (id === "board.ticket.run_ready") {
        return JSON.stringify({
          type: "success",
          structured: {
            questions: [],
            runs: [
              {
                task_id: "task-1",
                session_id: "ticket-task-1-1",
                phase: "work",
                status: "running",
                error: null,
                result: null,
              },
            ],
          },
        });
      }
      throw new Error("unexpected command: " + id);
    },
  } as unknown as CetasApplication;
}

afterEach(async () => {
  await closeWorkflowBoards();
});

test("serves the same Rabbita app and bridges the Board wire protocol", async () => {
  let opened = "";
  const activities: string[] = [];
  const app = mockApp();
  const base = await openWorkflowBoard(app, {
    onOpen: (url) => {
      opened = url;
    },
    onTicketActivity: (text) => {
      activities.push(text);
    },
  });

  expect(opened).toContain("?token=");
  const page = await fetch(opened);
  expect(page.status).toBe(200);
  const html = await page.text();
  expect(html).toContain("<title>Board</title>");
  expect(html).toContain("/index.js");

  const js = await (await fetch(base + "index.js")).text();
  expect(js.length).toBeGreaterThan(1000);
  const css = await (await fetch(base + "board.css")).text();
  expect(css).toContain("--canvas: #f4f4f1");

  const wsUrl = opened
    .replace("http://", "ws://")
    .replace("/?token=", "/ws?token=");
  const socket = new WebSocket(wsUrl);
  const messages: string[] = [];
  const commandSettled = new Promise<void>((resolve) => {
    socket.onmessage = (event) => {
      messages.push(String(event.data));
      if (messages.some((m) => JSON.parse(m).type === "command_result")) {
        resolve();
      }
    };
  });
  await new Promise<void>((resolve, reject) => {
    socket.onopen = () => resolve();
    socket.onerror = () => reject(new Error("websocket failed"));
  });
  socket.send(
    JSON.stringify({
      type: "hello",
      protocol_version: 1,
      last_seq: 0,
      has_board_snapshot: false,
    }),
  );
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(messages.length).toBeGreaterThan(0);
  expect(JSON.parse(messages[0]!).type).toBe("snapshot");
  expect(
    activities.some((text) => text.includes("Worker needs your answer")),
  ).toBe(true);

  socket.send(
    JSON.stringify({
      type: "command",
      command_id: "cmd-1",
      name: "board.task.move",
      expected_revision: 7,
      args: {},
    }),
  );
  await Promise.race([
    commandSettled,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("board command did not settle")), 5000),
    ),
  ]);

  socket.send(
    JSON.stringify({
      type: "ticket_command",
      name: "board.ticket.run_ready",
      args: {},
    }),
  );
  await new Promise((resolve) => setTimeout(resolve, 250));
  const ticket = messages
    .map((frame) => JSON.parse(frame) as { type?: string; ok?: boolean })
    .find((frame) => frame.type === "ticket_result");
  expect(ticket?.ok).toBe(true);
  socket.close();
}, 10000);
