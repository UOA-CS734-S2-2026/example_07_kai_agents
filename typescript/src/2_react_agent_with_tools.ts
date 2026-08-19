// Step 02 - the same model, now with tools, and a loop around it.
//
// Step 01 could not answer "what free food is on campus" because a model on
// its own knows nothing that happened after training. This step changes that
// by giving it three tools and, crucially, somewhere to go after it uses one.
//
// The loop is four lines of graph:
//
//     START -> agent
//     agent -> tools        (only if the model asked for a tool)
//     agent -> END          (otherwise)
//     tools -> agent        (always: the result has to be read by someone)
//
// That conditional edge IS the ReAct loop. Thought, action, observation,
// repeat, until the model has nothing left to look up and just answers.
//
//   npm run react -- "I'm at OGGB and vegetarian - anything in 20 minutes?"

import { AIMessage, type BaseMessage, SystemMessage, HumanMessage } from "@langchain/core/messages";
import { Annotation, END, START, StateGraph, messagesStateReducer } from "@langchain/langgraph";
import { ToolNode } from "@langchain/langgraph/prebuilt";

import { createModel } from "./runtime.js";
import { getTools } from "./tools.js";

const SYSTEM =
  "You are Kai Finder, an assistant that helps University of Auckland students find free " +
  "food on campus. Use the tools to find out what is actually on right now rather than " +
  "guessing. When you recommend something, say where it is, how far the walk is and how " +
  "many portions are left. Be brief.";

// The whole state is the conversation. messagesStateReducer APPENDS rather
// than replaces, so every tool result joins the transcript instead of
// overwriting it. That is also why the loop terminates: the model sees what it
// already looked up.
const KaiState = Annotation.Root({
  messages: Annotation<BaseMessage[]>({ reducer: messagesStateReducer, default: () => [] }),
});

async function agentNode(state: typeof KaiState.State) {
  const model = createModel().bindTools(getTools());
  return { messages: [await model.invoke(state.messages)] };
}

// The conditional edge, spelled out: tool calls loop back, plain text ends.
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
    .compile();
}

// Printing the trace matters in a lecture: without it an agent is a box that
// pauses and then talks. With it you can watch it decide.
export async function answerStream(userQuery: string) {
  const graph = buildGraph();
  const input = { messages: [new SystemMessage(SYSTEM), new HumanMessage(userQuery)] };
  for await (const output of await graph.stream(input)) {
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

const DEMO_QUESTION = "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?";
await answerStream(process.argv.slice(2).join(" ") || DEMO_QUESTION);
