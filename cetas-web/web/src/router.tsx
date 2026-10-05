import { createRouter } from "@solidjs/router";
import ChatPage from "./pages/ChatPage";
import SettingsPage from "./pages/SettingsPage";
import WorkspacePage from "./pages/WorkspacePage";

export const Router = createRouter({
  routes: [
    { path: "/", component: ChatPage },
    { path: "/workspace", component: WorkspacePage },
    { path: "/settings", component: SettingsPage },
    { path: "*404", component: ChatPage },
  ],
});
