// e2e fixture for the npm channel: run the Board transport under plain Node,
// where no `Bun` global exists. Started by smokes/board-node.test.ts.
import { openWorkflowBoard, closeWorkflowBoards } from "../../ui/workflow-board-server.ts";

const SNAPSHOT = JSON.stringify({
  type: "snapshot",
  protocol_version: 1,
  last_seq: 0,
  board_revision: 4,
  payload: { board: { revision: 4, tasks: [], attempts: [] }, events: [] },
});

const app = {
  invokeCommand: async (id) => {
    if (id === "board.wire.ready") return JSON.stringify({ type: "success", structured: {} });
    if (id === "board.wire.snapshot") {
      return JSON.stringify({ type: "success", structured: { frame: SNAPSHOT } });
    }
    if (id === "board.ticket.state") {
      return JSON.stringify({ type: "success", structured: { questions: [], runs: [] } });
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
};

const deadline = setTimeout(() => {
  console.error("board-node: timed out");
  process.exit(1);
}, 30_000);

let opened = "";
const base = await openWorkflowBoard(app, {
  onOpen: (url) => {
    opened = url;
  },
});

const page = await fetch(opened);
if (page.status !== 200) throw new Error("page status " + page.status);
if (!(await page.text()).includes('<div id="app">')) {
  throw new Error("served document is not the Board app shell");
}
const appJs = await fetch(base + "index.js");
if (appJs.status !== 200) throw new Error("app bundle status " + appJs.status);
if ((await appJs.text()).length < 1000) throw new Error("app bundle is empty");

// The token gate is the same on both transports.
const denied = await fetch(base + "?token=wrong");
if (denied.status !== 403) throw new Error("token gate status " + denied.status);

const socket = new WebSocket(
  opened.replace("http://", "ws://").replace("/?token=", "/ws?token="),
);
const frames = [];
await new Promise((resolve, reject) => {
  socket.onmessage = (event) => {
    frames.push(String(event.data));
    if (frames.some((frame) => JSON.parse(frame).type === "snapshot")) resolve();
  };
  socket.onerror = () => reject(new Error("websocket failed"));
  socket.onopen = () => {
    socket.send(
      JSON.stringify({
        type: "hello",
        protocol_version: 1,
        last_seq: 0,
        has_board_snapshot: false,
      }),
    );
  };
});

// Ticket commands travel the same serialized channel (Board inbox actions).
socket.send(
  JSON.stringify({
    type: "ticket_command",
    name: "board.ticket.run_ready",
    args: {},
  }),
);
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("ticket_result did not settle")), 10_000);
  const poll = setInterval(() => {
    if (frames.some((frame) => JSON.parse(frame).type === "ticket_result")) {
      clearInterval(poll);
      clearTimeout(timer);
      resolve();
    }
  }, 25);
});
const ticket = frames
  .map((frame) => JSON.parse(frame))
  .find((frame) => frame.type === "ticket_result");
if (ticket.ok !== true) throw new Error("ticket command rejected: " + JSON.stringify(ticket));

socket.close();
await closeWorkflowBoards();
clearTimeout(deadline);
console.log("board-node ok: " + frames.length + " frame(s)");
