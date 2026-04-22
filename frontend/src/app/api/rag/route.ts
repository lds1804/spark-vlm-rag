import { NextRequest, NextResponse } from "next/server";
import { Groq } from "@llamaindex/groq";
import { HuggingFaceEmbedding } from "@llamaindex/huggingface";
import { Settings } from "llamaindex";
import * as lancedb from "@lancedb/lancedb";

// Initialize Settings (runs server-side only)
Settings.llm = new Groq({
  apiKey: process.env.GROQ_API_KEY!,
  model: "llama-3.3-70b-versatile",
});

Settings.embedModel = new HuggingFaceEmbedding({
  modelType: "Xenova/bge-small-en-v1.5",
});

export async function POST(req: NextRequest) {
  try {
    const { query } = await req.json();
    if (!query) {
      return NextResponse.json({ error: "Missing query" }, { status: 400 });
    }

    const uri = process.env.NEXT_PUBLIC_LANCEDB_URI || "s3://vllm-chunking/lancedb";
    const tableName = process.env.TABLE_NAME || "chunks";

    // 1. Connect to LanceDB
    const storageOptions: Record<string, string> = {
      aws_region: process.env.AWS_REGION || "us-east-1",
    };
    if (process.env.AWS_ACCESS_KEY_ID)     storageOptions.aws_access_key_id     = process.env.AWS_ACCESS_KEY_ID;
    if (process.env.AWS_SECRET_ACCESS_KEY) storageOptions.aws_secret_access_key = process.env.AWS_SECRET_ACCESS_KEY;
    if (process.env.AWS_SESSION_TOKEN)     storageOptions.aws_session_token     = process.env.AWS_SESSION_TOKEN;

    const db = await lancedb.connect(uri, { storageOptions });
    const table = await db.openTable(tableName);

    // 2. EMBED the query
    console.log("Embedding query:", query);
    const embeddingModel = Settings.embedModel;
    const queryVector = await embeddingModel.getTextEmbedding(query);
    console.log("Query vector generated (length):", queryVector?.length);

    if (!queryVector) {
      throw new Error("Failed to generate query embedding");
    }

    // 3. Perform Vector Search
    console.log("Searching table:", tableName);
    const results = await table.search(queryVector).limit(5).toArray();
    console.log("Search results received:", results?.length);

    if (!results) {
      console.warn("Search returned null/undefined results");
    }

    // 4. Build context
    const context = results
      .map((r: any) => r.chunk_text || r.text || "")
      .filter(Boolean)
      .join("\n\n---\n\n");

    if (!context) {
      return NextResponse.json({
        answer: "Não encontrei conteúdo relevante no banco de dados. Execute a ingestão primeiro.",
        sources: [],
      });
    }

    // 4. Call Groq for final answer
    const llm = Settings.llm as Groq;
    const response = await llm.chat({
      messages: [
        {
          role: "system",
          content:
            "You are a helpful research assistant. Answer the user's question based ONLY on the provided context. Be concise and cite the relevant information.",
        },
        {
          role: "user",
          content: `Context:\n${context}\n\nQuestion: ${query}`,
        },
      ],
    });

    const answer = response.message?.content ?? "No answer generated.";

    // 5. Return answer + sources for the UI Source Attribution panel
    return NextResponse.json({
      answer,
      sources: results.map((r: any) => ({
        text: (r.chunk_text || r.text || "").substring(0, 300),
        metadata: { doc_id: r.doc_id, source: r.source },
      })),
    });
  } catch (error: any) {
    console.error("RAG API Error:", error);
    return NextResponse.json(
      { error: "Internal Server Error", details: error.message },
      { status: 500 }
    );
  }
}
