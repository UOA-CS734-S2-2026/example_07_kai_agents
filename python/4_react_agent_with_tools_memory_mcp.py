"""Step 04 - the same three tools, now behind a protocol.

Compare this file with step 03 and almost nothing has changed. The graph is
identical, the memory is identical, the printing is identical. One thing moved:
the tools are no longer functions in this process. They live in
mcp_server/kai_events_mcp.py, a separate program, and this agent talks to them
over the Model Context Protocol.

The behaviour is unchanged, and that IS the demonstration. A protocol boundary
that changes what the agent can do would be a bad protocol boundary.

What it buys: those tools are now mountable by anything that speaks MCP. Next
lecture, opencode mounts this exact server and asks it the same questions. The
lab's concierge can be the third host. Write once, mount anywhere - M plus N
integrations instead of M times N.

The transport here is stdio: this process starts the server as a subprocess and
talks JSON-RPC over its pipes. No port, no network, no auth to get wrong. MCP
also has an HTTP transport for servers that are not on your machine.

    uv run python 4_react_agent_with_tools_memory_mcp.py
    uv run python 4_react_agent_with_tools_memory_mcp.py --demo
"""

import asyncio
import os
import sys
import uuid
from typing import Annotated, TypedDict

from langchain_core.runnables import RunnableConfig
from langchain_core.tools import tool
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.config import get_store
from langgraph.graph import START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.store.memory import InMemoryStore

from llm import get_llm

SYSTEM = (
    "You are Kai Finder, an assistant that helps University of Auckland "
    "students find free food on campus. Use the tools to find out what is "
    "actually on right now rather than guessing. When someone tells you "
    "something durable about themselves - a dietary need, where they usually "
    "are, something they dislike - call save_preference so you remember it "
    "next time. Never ask again for something you already know. Be brief."
)

# Where the tools live now. One entry per server: mount a second one and its
# tools simply join the list.
mcp_client = MultiServerMCPClient(
    {
        "kai-events": {
            "transport": "stdio",
            "command": "uv",
            "args": ["run", "mcp_server/kai_events_mcp.py"],
            # The adapter opens a fresh session per call, which starts the
            # subprocess again each time, so anything the server logs at
            # startup is printed on every tool call. Quiet it from this side.
            "env": {"FASTMCP_LOG_ENABLED": "false", "PATH": os.environ["PATH"]},
        }
    }
)


class KaiState(TypedDict):
    messages: Annotated[list, add_messages]


@tool
def save_preference(fact: str, config: RunnableConfig) -> str:
    """Remember a durable fact about this student, so it is known in future conversations.

    Use for things that stay true: 'is vegan', 'usually around the Science
    Centre', 'allergic to peanuts'. Do not use it for one-off requests.
    """
    store = get_store()
    user_id = config["configurable"].get("user_id", "default_user")
    store.put((user_id, "kai_preferences"), str(uuid.uuid4()), {"text": fact})
    return f"Saved: {fact}"


async def get_tools():
    """Local tools plus whatever the MCP server says it has.

    Note that nothing here names get_food_events or filter_events. The agent
    asks the server what it offers and binds the answer, so adding a tool to
    the server adds it to the agent with no change on this side.
    """
    return [save_preference, *await mcp_client.get_tools()]


async def build_graph(tools):

    async def agent_node(state: KaiState, config: RunnableConfig):
        store = get_store()
        user_id = config["configurable"].get("user_id", "default_user")
        remembered = [item.value["text"] for item in store.search((user_id, "kai_preferences"))]

        system = SYSTEM
        if remembered:
            system += "\n\nWhat you already know about this student: " + "; ".join(remembered)

        llm_with_tools = get_llm().bind_tools(tools)
        messages = [("system", system), *state["messages"]]
        return {"messages": [await llm_with_tools.ainvoke(messages)]}

    builder = StateGraph(KaiState)
    builder.add_node("agent", agent_node)
    builder.add_node("tools", ToolNode(tools))
    builder.add_edge(START, "agent")
    builder.add_conditional_edges("agent", tools_condition)
    builder.add_edge("tools", "agent")
    return builder.compile(store=InMemoryStore(), checkpointer=InMemorySaver())


async def answer_stream(
    user_query: str, graph, user_id: str = "student", thread_id: str = "thread-a"
):
    config = {"configurable": {"user_id": user_id, "thread_id": thread_id}}
    async for output in graph.astream({"messages": [("user", user_query)]}, config=config):
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
                    print("Tool ran >", result.name, ">", _content(result)[:300])
            print("\n -----\n")


def _content(message) -> str:
    """MCP hands results back as a list of content blocks, not a bare string.

    A local tool returns text and LangChain passes it straight through. An MCP
    tool returns [{"type": "text", "text": ...}], because the protocol also
    allows images and embedded resources. Unwrap it so the trace stays legible.
    """
    content = message.content
    if isinstance(content, list):
        return "".join(block.get("text", "") for block in content if isinstance(block, dict))
    return str(content)


DEMO_QUESTION = "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?"


async def main():
    print("Connecting to the kai-events MCP server over stdio...")
    # Ask the server what it has ONCE, then reuse it. Every call to
    # get_tools() opens a fresh session and starts the subprocess again.
    tools = await get_tools()
    graph = await build_graph(tools)
    print(f"Tools available: {', '.join(t.name for t in tools)}\n")

    if "--demo" in sys.argv:
        await answer_stream(DEMO_QUESTION, graph=graph)
        return

    if len(sys.argv) > 1:
        await answer_stream(" ".join(sys.argv[1:]), graph=graph)
        return

    print("Kai agent, step 04. Tools come from MCP now. Type 'quit' to exit.")
    print(f'Try: "{DEMO_QUESTION}"\n')
    while True:
        try:
            user_input = input("You: ")
        except EOFError:
            break
        if user_input.lower() in ("quit", "exit"):
            break
        await answer_stream(user_input, graph=graph)


if __name__ == "__main__":
    asyncio.run(main())
