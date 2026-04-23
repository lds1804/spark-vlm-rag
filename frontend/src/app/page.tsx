"use client";

import React, { useState, useRef, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Send, FileText, Database, Zap, Loader2, Sparkles, ServerCrash, ThumbsUp, ThumbsDown, Copy, Check, Paperclip, Cpu, PlusCircle, ArrowUpRight, ChevronRight, ArrowUp } from "lucide-react";
import { Button } from "@/components/ui/button";
import TextareaAutosize from 'react-textarea-autosize';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";

// Typing effect component with citations
const TypewriterText = ({ text, onCitationClick }: { text: string, onCitationClick: (idx: number) => void }) => {
  const [displayedText, setDisplayedText] = useState("");
  const [isFinished, setIsFinished] = useState(false);

  useEffect(() => {
    let i = 0;
    const intervalId = setInterval(() => {
      setDisplayedText(text.substring(0, i));
      i++;
      if (i > text.length) {
        clearInterval(intervalId);
        setIsFinished(true);
      }
    }, 8);
    return () => clearInterval(intervalId);
  }, [text]);

  const parts = displayedText.split(/(\[\d+\])/);

  return (
    <span>
      {parts.map((part, i) => {
        const match = part.match(/\[(\d+)\]/);
        if (match) {
          const idx = parseInt(match[1]) - 1;
          return (
            <button
              key={i}
              onClick={() => onCitationClick(idx)}
              className="text-indigo-400 font-bold hover:text-indigo-300 mx-0.5 px-1 rounded bg-indigo-500/10 cursor-pointer transition-colors"
            >
              {part}
            </button>
          );
        }
        return <span key={i}>{part}</span>;
      })}
      {!isFinished && <span className="inline-block w-1.5 h-4 bg-indigo-500 ml-1 animate-pulse" />}
    </span>
  );
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

// Copy Button Component
const CopyButton = ({ text }: { text: string }) => {
  const [copied, setCopied] = useState(false);
  const handleCopy = () => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };
  return (
    <button onClick={handleCopy} className="p-1.5 bg-black/40 hover:bg-black/60 border border-white/10 rounded-md text-white/50 hover:text-white transition-all shadow-xl">
      {copied ? <Check className="w-3.5 h-3.5 text-green-400" /> : <Copy className="w-3.5 h-3.5" />}
    </button>
  );
};

export default function App() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [highlightedSourceIdx, setHighlightedSourceIdx] = useState<number | null>(null);
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

      // Cleanup trailing references from LLM text
      let cleanAnswer = data.answer || "No answer generated.";
      const refIndex = cleanAnswer.search(/\n\s*References:|\n\s*Sources:|\n\s*Fontes:/i);
      if (refIndex !== -1) {
        cleanAnswer = cleanAnswer.substring(0, refIndex).trim();
      }

      const assistantMessage: Message = {
        id: (Date.now() + 1).toString(),
        role: "assistant",
        content: cleanAnswer,
        sources: data.sources || [],
        latency: data.latency || latencyMs,
        costEstimate: data.costEstimate ? `$${parseFloat(data.costEstimate).toFixed(5)}` : "~1¢"
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
    <div className="flex h-screen bg-[#050505] text-white font-sans selection:bg-indigo-500/30 overflow-hidden relative">
      
      {/* Dynamic Background */}
      <div className="absolute top-0 left-0 w-full h-full overflow-hidden pointer-events-none z-0">
        <div className="absolute top-[-10%] left-[-20%] w-[50%] h-[50%] rounded-full bg-indigo-600/5 blur-[120px]" />
        <div className="absolute bottom-[-10%] right-[-20%] w-[60%] h-[60%] rounded-full bg-blue-600/5 blur-[150px]" />
      </div>

      {/* Left Sidebar */}
      <div className="w-72 border-r border-white/5 bg-[#0A0A0C]/50 backdrop-blur-xl z-20 hidden lg:flex flex-col pt-8 p-6 shrink-0">
        <div className="mb-10">
          <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-blue-400 to-indigo-400 flex items-center gap-2">
            <Sparkles className="w-5 h-5 text-indigo-400" />
            RAG<span className="font-light text-white">Scale</span>
          </h1>
          <p className="text-white/30 text-[10px] mt-2 font-bold tracking-[0.2em] uppercase">Enterprise Build</p>
        </div>

        <ScrollArea className="flex-1 -mr-2 pr-2">
          <div className="space-y-8">
            {/* Status */}
            <div>
               <div className="flex items-center gap-2 mb-4 px-1">
                  <div className="w-2 h-2 rounded-full bg-teal-400 animate-pulse shadow-[0_0_8px_rgba(45,212,191,0.5)]" />
                  <span className="text-[10px] font-bold text-teal-400 uppercase tracking-widest">System Online</span>
               </div>
            </div>

            {/* Architecture */}
            <div>
              <h3 className="text-[11px] font-bold text-white/30 mb-4 uppercase tracking-[0.1em]">Architecture</h3>
              <div className="space-y-4">
                <div className="flex items-center gap-3 group">
                  <div className="w-8 h-8 rounded-lg bg-indigo-500/10 flex items-center justify-center border border-indigo-500/20 group-hover:border-indigo-500/40 transition-colors">
                    <Database className="w-4 h-4 text-indigo-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white/80 text-xs font-semibold">LanceDB</span>
                    <span className="text-white/30 text-[10px]">Cloud Store (S3)</span>
                  </div>
                </div>
                <div className="flex items-center gap-3 group">
                  <div className="w-8 h-8 rounded-lg bg-orange-500/10 flex items-center justify-center border border-orange-500/20 group-hover:border-orange-500/40 transition-colors">
                    <Zap className="w-4 h-4 text-orange-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white/80 text-xs font-semibold">Groq API</span>
                    <span className="text-white/30 text-[10px]">Llama 3 70B</span>
                  </div>
                </div>
                <div className="flex items-center gap-3 group">
                  <div className="w-8 h-8 rounded-lg bg-emerald-500/10 flex items-center justify-center border border-emerald-500/20 group-hover:border-emerald-500/40 transition-colors">
                    <ServerCrash className="w-4 h-4 text-emerald-400" />
                  </div>
                  <div className="flex flex-col">
                    <span className="text-white/80 text-xs font-semibold">AWS Lambda</span>
                    <span className="text-white/30 text-[10px]">Orchestrator</span>
                  </div>
                </div>
              </div>
            </div>

            <Separator className="bg-white/5" />

            {/* Stats */}
            <div>
              <h3 className="text-[11px] font-bold text-white/30 mb-4 uppercase tracking-[0.1em]">Metrics</h3>
              <Card className="bg-white/[0.02] border-white/5 !shadow-none">
                <CardContent className="p-4 flex flex-col gap-4">
                  <div>
                    <div className="text-white/30 text-[9px] uppercase font-bold mb-1">Total Infra Cost/Day</div>
                    <div className="text-lg font-light text-teal-300">$0.01 <span className="text-[10px] text-white/20">/ day</span></div>
                  </div>
                  <div className="h-px bg-white/5 w-full" />
                  <div>
                    <div className="text-white/30 text-[9px] uppercase font-bold mb-1">Session Estimated Cost</div>
                    <div className="text-sm font-semibold text-white/80">
                      ${messages.reduce((acc, m) => {
                        const val = m.costEstimate?.startsWith('$') ? parseFloat(m.costEstimate.substring(1)) : 0;
                        return acc + (isNaN(val) ? 0 : val);
                      }, 0).toFixed(5)}
                    </div>
                  </div>
                  <div>
                    <div className="text-white/30 text-[9px] uppercase font-bold mb-1">Knowledge Base</div>
                    <div className="text-xs font-medium text-white/60">3.3M Research Chunks</div>
                  </div>
                </CardContent>
              </Card>
            </div>
          </div>
        </ScrollArea>

        <div className="mt-auto pt-6 border-t border-white/5 flex flex-col gap-2">
          <div className="flex justify-between text-[9px] font-bold text-white/20 uppercase tracking-widest px-1">
            <span>Enterprise Build</span>
            <span>v1.0.0</span>
          </div>
        </div>
      </div>

      {/* Main Container */}
      <div className="flex-1 flex flex-col relative z-10 w-full h-full min-w-0">
        
        {/* Mobile Header only */}
        <div className="h-16 border-b border-white/5 flex items-center px-6 lg:hidden bg-black/40 backdrop-blur-md shrink-0">
          <h1 className="text-xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-blue-400 to-indigo-400 flex items-center gap-2">
            <Sparkles className="w-5 h-5 text-indigo-400" />
            RAG<span className="font-light text-white">Scale</span>
          </h1>
          <div className="flex items-center gap-4">
             <div className="flex items-center gap-2 px-3 py-1 rounded-full bg-white/5 border border-white/10">
                <div className="w-2 h-2 rounded-full bg-teal-400 animate-pulse" />
                <span className="text-[10px] font-bold text-teal-400 uppercase tracking-tighter">System Live</span>
             </div>
          </div>
        </div>

        {/* Chat Content */}
        <div className="flex-1 overflow-y-auto">
          <div className="max-w-3xl mx-auto w-full py-12 px-6 flex flex-col gap-12">
            
            {messages.length === 0 && !isLoading && (
              <div className="flex flex-col items-center justify-center py-20 text-center">
                <div className="w-16 h-16 rounded-2xl bg-indigo-500/10 flex items-center justify-center border border-indigo-500/20 mb-8 shadow-2xl">
                   <Database className="w-8 h-8 text-indigo-400" />
                </div>
                <h2 className="text-3xl font-bold mb-4 tracking-tight">Scientific Knowledge Hub</h2>
                <p className="text-white/40 text-base max-w-sm leading-relaxed mb-10">
                  Query 3.3 million research chunks using serverless vector search.
                </p>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 w-full">
                  {[
                    "Effects of COVID-19 on renal cells",
                    "Advances in Remdesivir treatments",
                    "Impact of superspreaders",
                    "Herd immunity studies"
                  ].map((p, i) => (
                    <button key={i} onClick={() => setInput(p)} className="p-4 rounded-xl bg-white/[0.03] border border-white/5 hover:bg-white/[0.06] hover:border-white/10 text-left transition-all">
                      <p className="text-sm font-medium text-white/70">{p}</p>
                    </button>
                  ))}
                </div>
              </div>
            )}

            <AnimatePresence>
              {messages.map((message) => (
                <motion.div
                  key={message.id}
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  className={`flex flex-col gap-4 ${message.role === "user" ? "items-end" : "items-start"}`}
                >
                  <div className={`flex items-start gap-4 max-w-[90%] ${message.role === "user" ? "flex-row-reverse" : "flex-row"}`}>
                    <div className={`w-8 h-8 rounded-lg flex items-center justify-center shrink-0 mt-1 border ${
                      message.role === "user" ? "bg-indigo-600 border-indigo-400" : "bg-white/5 border-white/10"
                    }`}>
                      {message.role === "user" ? <Cpu className="w-4 h-4 text-white" /> : <Sparkles className="w-4 h-4 text-indigo-400" />}
                    </div>
                    
                    <div className={`flex flex-col gap-3 ${message.role === "user" ? "items-end" : "items-start"}`}>
                      <div className={`px-6 py-4 rounded-2xl text-[15px] leading-relaxed relative group ${
                        message.role === "user" 
                          ? "bg-indigo-600/90 text-white rounded-tr-sm" 
                          : "bg-[#111113] text-white/90 border border-white/10 rounded-tl-sm shadow-xl"
                      }`}>
                         {message.role === "assistant" && !message.error ? (
                            <TypewriterText 
                              text={message.content} 
                              onCitationClick={(idx) => {
                                setHighlightedSourceIdx(idx);
                                setTimeout(() => setHighlightedSourceIdx(null), 3000);
                              }} 
                            />
                         ) : message.content}
                         
                         {message.role === "assistant" && !message.error && (
                            <div className="absolute -bottom-3 right-4 opacity-0 group-hover:opacity-100 transition-opacity">
                              <CopyButton text={message.content} />
                            </div>
                         )}
                      </div>

                      {/* Assistant Extras: Metrics & Sources */}
                      {message.role === "assistant" && !message.error && (
                        <div className="flex flex-col gap-4 w-full">
                          {/* Sources row inside the message */}
                          {message.sources && message.sources.length > 0 && (
                            <div className="flex flex-wrap gap-2">
                               {message.sources.map((src, sIdx) => (
                                 <Badge 
                                   key={sIdx} 
                                   variant="secondary" 
                                   className={`bg-white/5 border-white/5 text-[10px] text-white/40 transition-all duration-500 ${
                                     highlightedSourceIdx === sIdx 
                                      ? "ring-2 ring-indigo-500 border-indigo-500/50 bg-indigo-500/20 text-indigo-300 scale-105 shadow-[0_0_15px_rgba(99,102,241,0.3)]" 
                                      : "hover:bg-white/10"
                                   }`}
                                 >
                                   <span className="font-bold mr-1">[{sIdx + 1}]</span>
                                   {src.metadata?.title?.substring(0, 30) || "Source Document"}...
                                 </Badge>
                               ))}
                            </div>
                          )}

                          {/* Latency & Cost */}
                          <div className="flex gap-2">
                            {message.latency && (
                              <Badge variant="outline" className="text-[10px] text-teal-400 border-teal-500/20 bg-teal-500/5">
                                <Zap className="w-3 h-3 mr-1" /> {message.latency}ms
                              </Badge>
                            )}
                            {message.costEstimate && (
                              <Badge variant="outline" className="text-[10px] text-white/30 border-white/5 bg-white/5">
                                💰 {message.costEstimate}
                              </Badge>
                            )}
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                </motion.div>
              ))}
            </AnimatePresence>

            {isLoading && (
              <div className="flex gap-4 items-start">
                <div className="w-8 h-8 rounded-lg bg-white/5 border border-white/10 flex items-center justify-center shrink-0 animate-pulse">
                  <Loader2 className="w-4 h-4 text-indigo-400 animate-spin" />
                </div>
                <div className="flex flex-col gap-2 flex-1">
                  <div className="h-4 bg-white/5 rounded-md w-full animate-pulse" />
                  <div className="h-4 bg-white/5 rounded-md w-4/5 animate-pulse" />
                  <div className="h-4 bg-white/5 rounded-md w-2/3 animate-pulse" />
                </div>
              </div>
            )}

            <div ref={scrollRef} className="h-10" />
          </div>
        </div>

        {/* Floating Input bar */}
        <div className="p-6 pt-0 bg-gradient-to-t from-[#050505] to-transparent relative z-20">
          <form onSubmit={handleSubmit} className="max-w-3xl mx-auto relative">
            <div className="relative flex items-center bg-[#131315]/80 backdrop-blur-xl border border-white/10 rounded-2xl shadow-2xl focus-within:border-indigo-500/50 transition-all">
              <div className="p-3 pr-0">
                 <Paperclip className="w-5 h-5 text-white/20" />
              </div>
              <TextareaAutosize
                minRows={1}
                maxRows={8}
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    handleSubmit(e as any);
                  }
                }}
                placeholder="Message RAGScale..."
                className="flex-1 bg-transparent border-0 focus:ring-0 text-white placeholder:text-white/20 text-sm p-4 resize-none outline-none leading-relaxed"
                disabled={isLoading}
              />
              <div className="p-2">
                <Button 
                  type="submit" 
                  size="icon" 
                  disabled={!input.trim() || isLoading}
                  className="bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl h-10 w-10 transition-all shadow-lg shadow-indigo-500/20"
                >
                   {isLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <ArrowUp className="w-4 h-4" />}
                </Button>
              </div>
            </div>
          </form>
        </div>

      </div>
    </div>
  );
}
