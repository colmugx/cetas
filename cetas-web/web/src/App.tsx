import { Router } from "./router";
import { RuntimeProvider } from "./cetas/runtime";
import AppShell from "./components/AppShell";
import "./app.css";

export default function App() {
  return (
    <RuntimeProvider>
      <Router>
        {(props) => <AppShell>{props.children}</AppShell>}
      </Router>
    </RuntimeProvider>
  );
}
