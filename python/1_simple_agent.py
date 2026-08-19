"""Step 01 - the smallest thing LangGraph will let you build.

One node. A message goes in, a response comes out. There is no loop, no tool,
no memory, and deliberately so: this is the baseline that the next three steps
each add exactly one idea to.

The graph here is pure scaffolding. Everything this file does could be one
call to llm.invoke(). Building it as a graph anyway means step 02 changes the
shape of the graph rather than rewriting the program.

Ask it what free food is on campus and watch it fail honestly: a model with no
tools cannot know anything that happened after it was trained.

    uv run python 1_simple_agent.py
    uv run python 1_simple_agent.py "What free food is on campus today?"
"""

import sys
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from llm import get_llm

# Every step in this repo sends a system message. It costs one line, it keeps
# the model on topic, and with this particular model it is also load-bearing:
# see the comment in llm.py.
SYSTEM = (
    "You are Kai Finder, an assistant that helps University of Auckland "
    "students find free food on campus. Be brief and concrete."
)


class GraphState(TypedDict):
    """What flows through the graph. One field, because one is enough here."""

    message: str


def chat_agent(state: GraphState) -> GraphState:
    """The only node: hand the message to the model, return what comes back."""
    response = get_llm().invoke([("system", SYSTEM), ("user", state["message"])])
    return {"message": response.content}


def build_graph():
    builder = StateGraph(GraphState)
    builder.add_node("agent", chat_agent)
    builder.add_edge(START, "agent")
    builder.add_edge("agent", END)
    return builder.compile()


# LangGraph Studio looks for a module-level graph, so it can draw this one.
graph = build_graph()


def answer(user_query: str) -> str:
    return graph.invoke({"message": user_query})["message"]


if __name__ == "__main__":
    # With an argument, answer once and exit. Without, sit in a REPL.
    if len(sys.argv) > 1:
        print(answer(" ".join(sys.argv[1:])))
        raise SystemExit(0)

    print("Kai agent, step 01. No tools yet. Type 'quit' to exit.\n")
    while True:
        try:
            user_input = input("You: ")
        except EOFError:
            break
        if user_input.lower() in ("quit", "exit"):
            break
        print("Agent >", answer(user_input), "\n")
