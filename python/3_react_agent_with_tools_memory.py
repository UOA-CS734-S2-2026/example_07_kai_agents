"""Step 03 - the agent remembers, in two different ways.

Step 02 forgot everything between questions. Two kinds of memory fix that, and
the difference between them is the point of this step:

  SHORT TERM, the checkpointer. Saves the message list against a thread_id, so
  a follow-up question can say "the second one" and mean something. Scope: one
  conversation. This is what a chat window gives you for free.

  LONG TERM, the store. A separate key-value space, scoped to a USER rather
  than a thread, that the agent writes to deliberately by calling a tool. A
  fact saved here survives into conversations that have not happened yet.

That second one is the interesting one, and it is why save_preference is a
tool rather than a hidden mechanism. The model decides something is worth
keeping and writes it down, in the middle of a sentence, the same way it
decides to look up an event. Nothing here is automatic.

    uv run python 3_react_agent_with_tools_memory.py
    uv run python 3_react_agent_with_tools_memory.py --demo
"""

import sys
import uuid
from typing import Annotated, TypedDict

from langchain_core.runnables import RunnableConfig
from langchain_core.tools import tool
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.config import get_store
from langgraph.graph import START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.store.memory import InMemoryStore

from kai_tools import get_tools as get_kai_tools
from llm import get_llm

SYSTEM = (
    "You are Kai Finder, an assistant that helps University of Auckland "
    "students find free food on campus. Use the tools to find out what is "
    "actually on right now rather than guessing. When someone tells you "
    "something durable about themselves - a dietary need, where they usually "
    "are, something they dislike - call save_preference so you remember it "
    "next time. Never ask again for something you already know. Be brief."
)


class KaiState(TypedDict):
    messages: Annotated[list, add_messages]


@tool
def save_preference(fact: str, config: RunnableConfig) -> str:
    """Remember a durable fact about this student, so it is known in future conversations.

    Use for things that stay true: 'is vegan', 'usually around the Science
    Centre', 'allergic to peanuts', 'does not like seafood'. Do not use it for
    one-off requests like 'wants lunch now'.
    """
    store = get_store()
    user_id = config["configurable"].get("user_id", "default_user")
    # The namespace is what makes this cross-thread: it is keyed on the user,
    # and no thread_id appears in it anywhere.
    store.put((user_id, "kai_preferences"), str(uuid.uuid4()), {"text": fact})
    return f"Saved: {fact}"


def get_tools():
    return [*get_kai_tools(), save_preference]


def agent_node(state: KaiState, config: RunnableConfig):
    """Same node as step 02, plus a lookup of what we already know.

    Reading the store here, on every turn, and pasting it into the system
    message is retrieval: the facts are fetched and put in the context window,
    because that is the only place a model can read anything.
    """
    store = get_store()
    user_id = config["configurable"].get("user_id", "default_user")
    remembered = [item.value["text"] for item in store.search((user_id, "kai_preferences"))]

    system = SYSTEM
    if remembered:
        system += "\n\nWhat you already know about this student: " + "; ".join(remembered)

    llm_with_tools = get_llm().bind_tools(get_tools())
    return {"messages": [llm_with_tools.invoke([("system", system), *state["messages"]])]}


def build_graph():
    builder = StateGraph(KaiState)
    builder.add_node("agent", agent_node)
    builder.add_node("tools", ToolNode(get_tools()))
    builder.add_edge(START, "agent")
    builder.add_conditional_edges("agent", tools_condition)
    builder.add_edge("tools", "agent")

    # The two memories, handed to the graph at compile time. Both are in
    # memory, so both die with the process: swapping in a Postgres-backed
    # checkpointer and store is a configuration change, not a rewrite.
    return builder.compile(store=InMemoryStore(), checkpointer=InMemorySaver())


def answer_stream(user_query: str, graph, user_id: str = "student", thread_id: str = "thread-a"):
    config = {"configurable": {"user_id": user_id, "thread_id": thread_id}}
    for output in graph.stream({"messages": [("user", user_query)]}, config=config):
        for node, value in output.items():
            message = value["messages"][-1]
            if node == "agent":
                if message.content:
                    print("Agent >", message.content)
                else:
                    for call in message.tool_calls:
                        print("Agent (tool calls) >", call["name"], call["args"])
            elif node == "tools":
                for result in value["messages"]:
                    print("Tool ran >", result.name, ">", result.content[:300])
            print("\n -----\n")


def run_demo(graph):
    """The two-thread demo, scripted, because both memories die with the process.

    Thread A teaches it something. Thread B is a brand new conversation that
    has never heard of it, and still knows.
    """
    script = [
        ("thread-a", "I'm vegan, and I'm usually around the Science Centre."),
        ("thread-a", "Anything to eat right now?"),
        ("thread-b", "Anything to eat right now?"),
    ]
    for thread_id, question in script:
        print(f"\n=========== {thread_id} > {question}\n")
        answer_stream(question, graph=graph, thread_id=thread_id)
    print(
        "\nThread B never heard the word vegan. The fact came out of the store, "
        "not out of the conversation."
    )


if __name__ == "__main__":
    graph = build_graph()

    if "--demo" in sys.argv:
        run_demo(graph)
        raise SystemExit(0)

    if len(sys.argv) > 1:
        answer_stream(" ".join(sys.argv[1:]), graph=graph)
        raise SystemExit(0)

    print("Kai agent, step 03. It remembers. Type 'quit' to exit.")
    print('Try telling it "I\'m vegan", then ask what is on.\n')
    while True:
        try:
            user_input = input("You: ")
        except EOFError:
            break
        if user_input.lower() in ("quit", "exit"):
            break
        answer_stream(user_input, graph=graph)
