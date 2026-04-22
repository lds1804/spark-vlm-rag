"use client";

import React, { useState, useRef, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Send, FileText, Database, Zap, Loader2, Sparkles, ServerCrash } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";

// Typing effect component
const TypewriterText = ({ text }: { text: string }) => {
  const [displayedText, setDisplayedText] = useState("");

  useEffect(() => {
    let i = 0;
    const intervalId = setInterval(() => {
      setDisplayedText(text.substring(0, i));
      i++;
      if (i > text.length) {
        clearInterval(intervalId);
      }
    }, 10);
    return () => clearInterval(intervalId);
  }, [text]);

  return <span>{displayedText}</span>;
};

type Message = {
  id: string;
  role: "user" | "assistant";
  content: string;
  sources?: any[];
  latency?: number;
  costEstimate?: string;
  error?: boolean;
};

export default function App() {
  const [messages, setMessages] = useState<Message[]>([
    {
      id: "init",
      role: "assistant",
      content: "Hello. I am the distributed RAG system. How can I help you query the 3.3 million processed chunks?",
    },
  ]);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [messages, isLoading]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isLoading) return;

    const userMessage: Message = { id: Date.now().toString(), role: "user", content: input };
    setMessages((prev) => [...prev, userMessage]);
    setInput("");
    setIsLoading(true);

    const startTime = performance.now();

    try {
      // Point this to your actual API Gateway or Lambda URL when deployed
      // For local testing, we might need a Next.js API route as a proxy, 
      // but here we just mock the request to the lambda structure.
      const lambdaUrl = process.env.NEXT_PUBLIC_LAMBDA_URL || "http://localhost:3000/api/rag";
      
      const res = await fetch(lambdaUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: userMessage.content }),
      });

      const endTime = performance.now();
      const latencyMs = Math.round(endTime - startTime);
      
      const data = await res.json();
      
      if (!res.ok) {
        throw new Error(data.error || "Failed to fetch response");
      }

      // Cost estimation based on Groq Llama3-70b approx pricing ($0.59 / 1M input tokens, $0.79 / 1M output tokens)
      // This is a rough estimation for "cheap to maintain" demonstration
      const promptTokens = userMessage.content.length / 4;
      const completionTokens = data.answer.length / 4;
      const estimatedCost = ((promptTokens * 0.59) / 1000000 + (completionTokens * 0.79) / 1000000) * 100; // Cent approximation
      const costDisplay = estimatedCost < 0.01 ? "< 1¢" : `~${estimatedCost.toFixed(2)}¢`;


      const assistantMessage: Message = {
        id: (Date.now() + 1).toString(),
        role: "assistant",
        content: data.answer || "No answer generated.",
        sources: data.sources || [],
        latency: latencyMs,
        costEstimate: costDisplay
      };

      setMessages((prev) => [...prev, assistantMessage]);
    } catch (error: any) {
      const errorMessage: Message = {
        id: (Date.now() + 1).toString(),
        role: "assistant",
        content: `Error: ${error.message || "Failed to connect to the Serverless Backend."}`,
        error: true
      };
      setMessages((prev) => [...prev, errorMessage]);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="flex h-screen bg-[#050505] text-white font-sans selection:bg-indigo-500/30 overflow-hidden">
      
      {/* Dynamic Background Elements */}
      <div className="absolute top-0 left-0 w-full h-full overflow-hidden pointer-events-none z-0">
        <div className="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] rounded-full bg-indigo-600/10 blur-[120px]" />
        <div className="absolute bottom-[-10%] right-[-10%] w-[50%] h-[50%] rounded-full bg-blue-600/10 blur-[150px]" />
      </div>

      {/* Sidebar / Dashboard */}
      <div className="w-80 border-r border-white/10 bg-white/[0.02] backdrop-blur-xl z-10 flex flex-col pt-8 p-6 hidden md:flex">
        <div className="mb-10">
          <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-blue-400 to-indigo-400 flex items-center gap-2">
            <Sparkles className="w-5 h-5 text-indigo-400" />
            RAG<span className="font-light text-white">Scale</span>
          </h1>
          <p className="text-white/40 text-xs mt-2 font-medium tracking-wider uppercase">Serverless Pipeline</p>
        </div>

        <ScrollArea className="flex-1 pr-4">
          <div className="space-y-6">
            
            {/* System Status */}
            <div>
              <h3 className="text-xs font-semibold text-white/50 mb-3 uppercase tracking-wider">System Architecture</h3>
              <div className="space-y-3">
                <div className="flex items-center gap-3 text-sm flex-row">
                  <div className="w-8 h-8 rounded-lg bg-indigo-500/20 flex items-center justify-center border border-indigo-500/30">
                    <Database className="w-4 h-4 text-indigo-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white text-xs">LanceDB (S3)</span>
                    <span className="text-white/40 text-[10px]">3.3M Chunks Indexed</span>
                  </div>
                </div>

                <div className="flex items-center gap-3 text-sm flex-row">
                  <div className="w-8 h-8 rounded-lg bg-orange-500/20 flex items-center justify-center border border-orange-500/30">
                    <Zap className="w-4 h-4 text-orange-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white text-xs">Groq API</span>
                    <span className="text-white/40 text-[10px]">Llama 3 70B</span>
                  </div>
                </div>

                <div className="flex items-center gap-3 text-sm flex-row">
                  <div className="w-8 h-8 rounded-lg bg-green-500/20 flex items-center justify-center border border-green-500/30">
                    <ServerCrash className="w-4 h-4 text-green-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white text-xs">AWS Lambda</span>
                    <span className="text-white/40 text-[10px]">Serverless Orchestration</span>
                  </div>
                </div>
              </div>
            </div>

            <Separator className="bg-white/10" />

            {/* Performance Metrics */}
            <div>
              <h3 className="text-xs font-semibold text-white/50 mb-3 uppercase tracking-wider">Session Metrics</h3>
              <Card className="bg-white/[0.03] border-white/10 !shadow-none">
                <CardContent className="p-4 flex flex-col gap-4">
                  <div>
                    <div className="text-white/50 text-[10px] uppercase mb-1">Total Infra Cost/Idle</div>
                    <div className="text-xl font-light text-emerald-400">$0.00 <span className="text-white/30 text-xs">/ hr</span></div>
                  </div>
                  <div>
                    <div className="text-white/50 text-[10px] uppercase mb-1">Avg Query Est. Cost</div>
                    <div className="text-sm font-medium text-white">~0.15 ¢</div>
                  </div>
                </CardContent>
              </Card>
            </div>
            
          </div>
        </ScrollArea>
        
        <div className="mt-auto pt-4 border-t border-white/10 flex justify-between items-center text-xs text-white/40">
          <span>v1.0.0</span>
          <span className="flex items-center gap-1"><span className="w-2 h-2 rounded-full bg-green-500"></span> Online</span>
        </div>
      </div>

      {/* Chat Area */}
      <div className="flex-1 flex flex-col relative z-10 w-full h-full">
        
        {/* Header for Mobile */}
        <div className="h-14 border-b border-white/10 flex items-center px-4 md:hidden bg-black/50 backdrop-blur-md">
          <h1 className="font-bold flex items-center gap-2">
            RAG<span className="font-light">Scale</span>
          </h1>
        </div>

        <ScrollArea className="flex-1 w-full h-[calc(100vh-140px)]">
          <div className="max-w-3xl mx-auto px-4 py-8 flex flex-col gap-8">
            <AnimatePresence initial={false}>
              {messages.map((message) => (
                <motion.div
                  key={message.id}
                  initial={{ opacity: 0, y: 20 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ duration: 0.4, ease: [0.23, 1, 0.32, 1] }}
                  className={`flex flex-col ${message.role === "user" ? "items-end" : "items-start"}`}
                >
                  <div
                    className={`max-w-[85%] rounded-2xl px-5 py-4 ${
                      message.role === "user"
                        ? "bg-gradient-to-br from-indigo-600 to-blue-700 text-white shadow-xl shadow-indigo-900/20"
                        : message.error 
                          ? "bg-red-950/40 border border-red-500/30 text-red-100"
                          : "bg-white/[0.04] border border-white/10 text-gray-200"
                    }`}
                  >
                    {message.role === "assistant" && !message.error ? (
                      <div className="leading-relaxed whitespace-pre-wrap font-light text-[15px]">
                          <TypewriterText text={message.content} />
                      </div>
                    ) : (
                      <div className="leading-relaxed whitespace-pre-wrap font-light text-[15px]">
                        {message.content}
                      </div>
                    )}
                  </div>

                  {/* Metadata / Sources (Assistant Only) */}
                  {message.role === "assistant" && !message.error && (message.sources?.length || message.latency) && (
                    <motion.div 
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      transition={{ delay: 0.5 }}
                      className="mt-3 flex flex-wrap flex-col gap-2 max-w-[85%]"
                    >
                      <div className="flex flex-wrap gap-2">
                        {message.latency && (
                            <Badge variant="secondary" className="bg-white/5 hover:bg-white/10 text-white/60 border-white/10 shadow-none font-mono text-[10px]">
                              <Zap className="w-3 h-3 mr-1 text-orange-400" />
                              {message.latency}ms
                            </Badge>
                        )}
                        {message.costEstimate && (
                            <Badge variant="secondary" className="bg-white/5 hover:bg-white/10 text-white/60 border-white/10 shadow-none font-mono text-[10px]">
                              💰 {message.costEstimate}
                            </Badge>
                        )}
                      </div>
                      
                      {message.sources && message.sources.length > 0 && (
                        <div className="mt-2">
                          <p className="text-[10px] uppercase tracking-wider text-white/40 mb-2 ml-1">Retrieved Sources ({message.sources.length})</p>
                          <div className="flex flex-wrap gap-2">
                            {message.sources.map((source, idx) => (
                              <div key={idx} className="flex items-center gap-1.5 bg-white/5 border border-white/10 rounded-md px-2.5 py-1.5 hover:bg-white/10 transition-colors cursor-pointer group">
                                <FileText className="w-3 h-3 text-indigo-400 group-hover:text-indigo-300" />
                                <span className="text-[10px] text-white/70 font-mono truncate max-w-[120px]">
                                  {source.metadata?.source || `Doc-${idx+1}`}
                                </span>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}
                    </motion.div>
                  )}
                </motion.div>
              ))}
            </AnimatePresence>
            
            {isLoading && (
              <motion.div
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                className="flex items-start"
              >
                <div className="flex items-center gap-3 bg-white/[0.04] border border-white/10 rounded-2xl px-5 py-4">
                  <div className="flex gap-1.5">
                    <motion.div animate={{ y: [0, -5, 0] }} transition={{ repeat: Infinity, duration: 0.6, delay: 0 }} className="w-1.5 h-1.5 bg-indigo-500 rounded-full" />
                    <motion.div animate={{ y: [0, -5, 0] }} transition={{ repeat: Infinity, duration: 0.6, delay: 0.2 }} className="w-1.5 h-1.5 bg-indigo-400 rounded-full" />
                    <motion.div animate={{ y: [0, -5, 0] }} transition={{ repeat: Infinity, duration: 0.6, delay: 0.4 }} className="w-1.5 h-1.5 bg-blue-400 rounded-full" />
                  </div>
                  <span className="text-white/50 text-sm font-light">Querying LanceDB / S3...</span>
                </div>
              </motion.div>
            )}
            <div ref={scrollRef} />
          </div>
        </ScrollArea>

        {/* Input Area */}
        <div className="p-4 md:p-6 bg-gradient-to-t from-[#050505] via-[#050505]/95 to-transparent pt-10">
          <form onSubmit={handleSubmit} className="max-w-3xl mx-auto relative group">
            <div className="absolute inset-0 bg-gradient-to-r from-indigo-500/20 to-blue-500/20 rounded-2xl blur-xl transition-opacity opacity-0 group-focus-within:opacity-100" />
            <div className="relative flex items-center bg-white/[0.03] border border-white/10 backdrop-blur-xl rounded-2xl p-2 transition-colors focus-within:border-indigo-500/50 focus-within:bg-white/[0.05]">
              <Input
                value={input}
                onChange={(e) => setInput(e.target.value)}
                placeholder="Ask anything about the 3.3M documents..."
                className="flex-1 bg-transparent border-0 focus-visible:ring-0 text-white placeholder:text-white/30 text-[15px] h-12"
                disabled={isLoading}
              />
              <Button 
                type="submit" 
                size="icon"
                disabled={!input.trim() || isLoading}
                className="rounded-xl bg-white text-black hover:bg-gray-200 h-10 w-10 shrink-0 transition-transform active:scale-95 disabled:opacity-50"
              >
                {isLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4 ml-0.5" />}
              </Button>
            </div>
            <p className="text-center text-[10px] text-white/30 mt-3 font-medium tracking-wide">
              Serverless RAG Architecture • Vector Search powered by LanceDB
            </p>
          </form>
        </div>
      </div>
    </div>
  );
}
