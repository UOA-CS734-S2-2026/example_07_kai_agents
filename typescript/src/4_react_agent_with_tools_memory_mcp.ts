// Step 04 - the same three tools, now behind a protocol.
//
// Compare this file with step 03 and almost nothing has changed. The graph is
// identical, the memory is identical. One thing moved: the Kai tools are no
// longer functions in this process. They live in the Python tree, in
// mcp_server/kai_events_mcp.py, and this agent talks to them over MCP.
//
// Note what that sentence says. The server is written in Python and this
// client is TypeScript, and neither one knows or cares. That is the entire
// argument for a protocol, demonstrated by not having to do anything: we did
// NOT port the server, because porting it would have been the M times N
// problem happening again in miniature.
//
// The transport is stdio: this process starts the server as a subprocess and
// talks JSON-RPC over its pipes.
//
//   npm run mcp -- --demo

import { AIMessage, type BaseMessage, HumanMessage, SystemMessage } from "@langchain/core/messages";
import { tool, type StructuredToolInterface } from "@langchain/core/tools";
import { MultiServerMCPClient } from "@langchain/mcp-adapters";
import {
  Annotation,
  END,
  InMemoryStore,
  MemorySaver,
  START,
  StateGraph,
  messagesStateReducer,
} from "@langchain/langgraph";
import { ToolNode } from "@langchain/langgraph/prebuilt";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

import { createModel } from "./runtime.js";

const SYSTEM =
  "You are Kai Finder, an assistant that helps University of Auckland students find free " +
  "food on campus. Use the tools to find out what is actually on right now rather than " +
  "guessing. When someone tells you something durable about themselves - a dietary need, " +
  "where they usually are, something they dislike - call save_preference so you remember " +
  "it next time. Never ask again for something you already know. Be brief.";

// The Python tree, from here. One copy of the server, two hosts.
const pythonDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../python");

const mcpClient = new MultiServerMCPClient({
  mcpServers: {
    "kai-events": {
      transport: "stdio",
      command: "uv",
      args: ["run", "--directory", pythonDir, "mcp_server/kai_events_mcp.py"],
      // The adapter opens a fresh session per call, which starts the
      // subprocess again each time, so anything the server logs at startup is
      // printed on every tool call. Quiet it from this side.
      env: { FASTMCP_LOG_ENABLED: "false", PATH: process.env.PATH ?? "" },
    },
  },
});

const store = new InMemoryStore();
const USER_ID = "student";
const NAMESPACE = [USER_ID, "kai_preferences"];

const savePreference = tool(
  async ({ fact }) => {
    await store.put(NAMESPACE, crypto.randomUUID(), { text: fact });
    return `Saved: ${fact}`;
  },
  {
    name: "save_preference",
    description:
      "Remember a durable fact about this student, so it is known in future " +
      "conversations. Use for things that stay true: 'is vegan', 'usually around the " +
      "Science Centre', 'allergic to peanuts'. Do not use it for one-off requests.",
    schema: z.object({ fact: z.string() }),
  },
);

const KaiState = Annotation.Root({
  messages: Annotation<BaseMessage[]>({ reducer: messagesStateReducer, default: () => [] }),
});

// MCP hands results back as a list of content blocks, not a bare string,
// because the protocol also allows images and embedded resources.
function contentOf(message: BaseMessage): string {
  const textOf = (block: unknown): string => {
    if (typeof block !== "string") return (block as { text?: string })?.text ?? String(block);
    // The JS adapter serialises the content block to a string, so what arrives
    // is the JSON of {"type":"text","text":...} rather than the text itself.
    try {
      const parsed = JSON.parse(block);
      return typeof parsed?.text === "string" ? parsed.text : block;
    } catch {
      return block;
    }
  };

  const content = message.content as unknown;
  return Array.isArray(content) ? content.map(textOf).join("") : textOf(content);
}

async function buildGraph(toolList: StructuredToolInterface[]) {
  async function agentNode(state: typeof KaiState.State) {
    const remembered = (await store.search(NAMESPACE)).map((item) => String(item.value.text));
    const system = remembered.length
      ? `${SYSTEM}\n\nWhat you already know about this student: ${remembered.join("; ")}`
      : SYSTEM;
    const model = createModel().bindTools(toolList);
    return { messages: [await model.invoke([new SystemMessage(system), ...state.messages])] };
  }

  function shouldContinue(state: typeof KaiState.State) {
    const last = state.messages[state.messages.length - 1] as AIMessage;
    return last.tool_calls?.length ? "tools" : END;
  }

  return new StateGraph(KaiState)
    .addNode("agent", agentNode)
    .addNode("tools", new ToolNode(toolList))
    .addEdge(START, "agent")
    .addConditionalEdges("agent", shouldContinue, ["tools", END])
    .addEdge("tools", "agent")
    .compile({ checkpointer: new MemorySaver() });
}

async function answerStream(userQuery: string, graph: Awaited<ReturnType<typeof buildGraph>>) {
  const config = { configurable: { thread_id: "thread-a" } };
  const input = { messages: [new HumanMessage(userQuery)] };
  for await (const output of await graph.stream(input, config)) {
    for (const [node, value] of Object.entries(output as Record<string, { messages: BaseMessage[] }>)) {
      const message = value.messages[value.messages.length - 1] as AIMessage;
      if (node === "agent") {
        if (message.content) console.log("Agent >", message.content);
        for (const call of message.tool_calls ?? []) {
          console.log("Agent (tool calls) >", call.name, JSON.stringify(call.args));
        }
      } else if (node === "tools") {
        for (const result of value.messages) {
          console.log("Tool ran >", (result as { name?: string }).name, ">", contentOf(result).slice(0, 300));
        }
      }
      console.log("\n -----\n");
    }
  }
}

const DEMO_QUESTION = "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?";

console.log("Connecting to the kai-events MCP server over stdio...");
// Ask the server what it has ONCE, then reuse it: every call opens a fresh
// session and starts the subprocess again.
const mcpTools = await mcpClient.getTools();
const tools = [savePreference, ...mcpTools];
console.log(`Tools available: ${tools.map((t) => t.name).join(", ")}\n`);

const graph = await buildGraph(tools);
const question = process.argv.filter((a) => a !== "--demo").slice(2).join(" ") || DEMO_QUESTION;
await answerStream(question, graph);
await mcpClient.close();
