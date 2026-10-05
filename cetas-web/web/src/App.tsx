import { Router } from "./router";
import { RuntimeProvider } from "./cetas/runtime";
import AppShell from "./components/AppShell";
import { ThemeProvider } from "./theme";
import "./app.css";

export default function App() {
  return (
    <ThemeProvider>
      <RuntimeProvider>
        <Router>
          {(props) => <AppShell>{props.children}</AppShell>}
        </Router>
      </RuntimeProvider>
    </ThemeProvider>
  );
}
