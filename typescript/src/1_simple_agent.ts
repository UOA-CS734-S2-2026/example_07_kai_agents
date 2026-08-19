// Step 01 - the smallest thing LangGraph will let you build.
//
// One node. A message goes in, a response comes out. No loop, no tool, no
// memory. The graph is pure scaffolding here: everything below could be one
// call to the model. Building it as a graph anyway means step 02 changes the
// SHAPE of the graph rather than rewriting the program.
//
//   npm run simple -- "What free food is on campus today?"

import { END, START, StateGraph, Annotation } from "@langchain/langgraph";

import { createModel } from "./runtime.js";

// Every step sends a system message. It costs one line, it keeps the model on
// topic, and with this particular model it is also load-bearing: see the
// comment in runtime.ts.
const SYSTEM =
  "You are Kai Finder, an assistant that helps University of Auckland students " +
  "find free food on campus. Be brief and concrete.";

// What flows through the graph. One field, because one is enough here.
const GraphState = Annotation.Root({
  message: Annotation<string>(),
});

async function chatAgent(state: typeof GraphState.State) {
  const response = await createModel().invoke([
    ["system", SYSTEM],
    ["user", state.message],
  ]);
  return { message: String(response.content) };
}

export function buildGraph() {
  return new StateGraph(GraphState)
    .addNode("agent", chatAgent)
    .addEdge(START, "agent")
    .addEdge("agent", END)
    .compile();
}

export async function answer(userQuery: string): Promise<string> {
  const result = await buildGraph().invoke({ message: userQuery });
  return result.message;
}

const query = process.argv.slice(2).join(" ") || "What free food is on campus today?";
console.log(await answer(query));
