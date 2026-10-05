import { createSignal, onCleanup, onMount } from "solid-js";
import { probeHealth, websocketUrl } from "./cetas/client";
import "./app.css";

type ConnectionState = "checking" | "online" | "offline";

export default function App() {
  const [http, setHttp] = createSignal<ConnectionState>("checking");
  const [socket, setSocket] = createSignal<ConnectionState>("checking");
  const [protocol, setProtocol] = createSignal("—");

  onMount(() => {
    const controller = new AbortController();
    void probeHealth(controller.signal)
      .then((health) => {
        setProtocol(health.protocol);
        setHttp("online");
      })
      .catch(() => setHttp("offline"));

    const ws = new WebSocket(websocketUrl());
    ws.addEventListener("open", () => setSocket("online"));
    ws.addEventListener("close", () => setSocket("offline"));
    ws.addEventListener("error", () => setSocket("offline"));

    onCleanup(() => {
      controller.abort();
      ws.close();
    });
  });

  return (
    <main class="shell">
      <section class="hero">
        <span class="eyebrow">cetas-web / bootstrap</span>
        <h1>Cetas is getting a web-native surface.</h1>
        <p>
          Solid 2 owns browser interaction. Moonback owns HTTP, WebSocket, and
          the future native asset bundle. Cetas protocol stays between them.
        </p>
      </section>

      <section class="status-grid" aria-label="bootstrap connectivity">
        <StatusCard label="HTTP control plane" value={http()} />
        <StatusCard label="WebSocket realtime plane" value={socket()} />
        <StatusCard label="Protocol draft" value={protocol()} />
      </section>

      <section class="next">
        <h2>Next slice</h2>
        <p>
          Replace the connectivity probe with session attach, turn streaming,
          tool lifecycle, approvals, and reconnect/replay semantics.
        </p>
      </section>
    </main>
  );
}

function StatusCard(props: { label: string; value: string }) {
  return (
    <article class="status-card">
      <span>{props.label}</span>
      <strong>{props.value}</strong>
    </article>
  );
}
