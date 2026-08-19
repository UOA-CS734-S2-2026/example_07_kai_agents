// Step 03 - the agent remembers, in two different ways.
//
// Step 02 forgot everything between questions. Two kinds of memory fix that,
// and the difference between them is the point of this step:
//
//   SHORT TERM, the checkpointer. Saves the message list against a thread_id,
//   so a follow-up can say "the second one" and mean something. Scope: one
//   conversation.
//
//   LONG TERM, the store. A separate key-value space scoped to a USER rather
//   than a thread, which the agent writes to deliberately by calling a tool. A
//   fact saved here survives into conversations that have not happened yet.
//
// That second one is why savePreference is a tool rather than a hidden
// mechanism: the model decides something is worth keeping and writes it down.
//
//   npm run memory -- --demo

import { AIMessage, type BaseMessage, HumanMessage, SystemMessage } from "@langchain/core/messages";
import { tool } from "@langchain/core/tools";
import { Annotation, END, MemorySaver, START, StateGraph, messagesStateReducer } from "@langchain/langgraph";
import { InMemoryStore } from "@langchain/langgraph";
import { ToolNode } from "@langchain/langgraph/prebuilt";
import { z } from "zod";

import { createModel } from "./runtime.js";
import { getTools as getKaiTools } from "./tools.js";

const SYSTEM =
  "You are Kai Finder, an assistant that helps University of Auckland students find free " +
  "food on campus. Use the tools to find out what is actually on right now rather than " +
  "guessing. When someone tells you something durable about themselves - a dietary need, " +
  "where they usually are, something they dislike - call save_preference so you remember " +
  "it next time. Never ask again for something you already know. Be brief.";

// One store for the whole process, so it outlives any single thread. In
// production this is Postgres and the code below does not change.
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

const getTools = () => [...getKaiTools(), savePreference];

const KaiState = Annotation.Root({
  messages: Annotation<BaseMessage[]>({ reducer: messagesStateReducer, default: () => [] }),
});

// Reading the store here, on every turn, and pasting it into the system
// message IS retrieval: the facts are fetched and put in the context window,
// because that is the only place a model can read anything.
async function agentNode(state: typeof KaiState.State) {
  const remembered = (await store.search(NAMESPACE)).map((item) => String(item.value.text));
  const system = remembered.length
    ? `${SYSTEM}\n\nWhat you already know about this student: ${remembered.join("; ")}`
    : SYSTEM;

  const model = createModel().bindTools(getTools());
  return { messages: [await model.invoke([new SystemMessage(system), ...state.messages])] };
}

function shouldContinue(state: typeof KaiState.State) {
  const last = state.messages[state.messages.length - 1] as AIMessage;
  return last.tool_calls?.length ? "tools" : END;
}

export function buildGraph() {
  return new StateGraph(KaiState)
    .addNode("agent", agentNode)
    .addNode("tools", new ToolNode(getTools()))
    .addEdge(START, "agent")
    .addConditionalEdges("agent", shouldContinue, ["tools", END])
    .addEdge("tools", "agent")
    .compile({ checkpointer: new MemorySaver() });
}

export async function answerStream(userQuery: string, graph: ReturnType<typeof buildGraph>, threadId = "thread-a") {
  const config = { configurable: { thread_id: threadId } };
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
          console.log("Tool ran >", (result as { name?: string }).name, ">", String(result.content).slice(0, 300));
        }
      }
      console.log("\n -----\n");
    }
  }
}

// The two-thread demo, scripted, because both memories die with the process.
async function runDemo(graph: ReturnType<typeof buildGraph>) {
  const script: [string, string][] = [
    ["thread-a", "I'm vegan, and I'm usually around the Science Centre."],
    ["thread-a", "Anything to eat right now?"],
    ["thread-b", "Anything to eat right now?"],
  ];
  for (const [threadId, question] of script) {
    console.log(`\n=========== ${threadId} > ${question}\n`);
    await answerStream(question, graph, threadId);
  }
  console.log("\nThread B never heard the word vegan. The fact came out of the store.");
}

const graph = buildGraph();
if (process.argv.includes("--demo")) {
  await runDemo(graph);
} else {
  await answerStream(process.argv.slice(2).join(" ") || "Anything to eat right now?", graph);
}
