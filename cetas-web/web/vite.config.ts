import { defineConfig } from "vite";
import solid from "@solidjs/vite-plugin";

export default defineConfig({
  plugins: [
    solid({
      start: true,
    }),
  ],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8787",
      },
      "/ws": {
        target: "http://127.0.0.1:8787",
        ws: true,
      },
    },
  },
});
