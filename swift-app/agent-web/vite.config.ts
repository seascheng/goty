import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// WKWebView loads this from a file:// resource URL, where module scripts
// are blocked by CORS — the whole app must inline into index.html.
export default defineConfig({
  plugins: [react(), tailwindcss(), viteSingleFile()],
  base: "./",
  build: { outDir: "dist", assetsInlineLimit: 0 },
});
