import type { NextConfig } from "next";
import path from "path";

const nextConfig: NextConfig = {
  turbopack: {
    root: path.resolve(__dirname),
  },
  // Prevent LlamaIndex/LanceDB server-only deps from being bundled for browser
  serverExternalPackages: ["@lancedb/lancedb", "llamaindex", "@llamaindex/groq", "@llamaindex/huggingface"],
};

export default nextConfig;
