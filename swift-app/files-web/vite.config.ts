import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// Same contract as agent-web: WKWebView serves this from goty:// where
// module scripts would be CORS-blocked — everything inlines into one
// index.html.
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: "./",
  build: { outDir: "dist", assetsInlineLimit: 0 },
});
