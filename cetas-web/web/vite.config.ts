import solid from "@solidjs/vite-plugin";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    tailwindcss(),
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
