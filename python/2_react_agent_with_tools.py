"""Step 02 - the same model, now with tools, and a loop around it.

Step 01 could not answer "what free food is on campus" because a model on its
own knows nothing that happened after training. This step changes that by
giving it three tools and, crucially, somewhere to go after it uses one.

The loop is four lines of graph:

    START -> agent
    agent -> tools        (only if the model asked for a tool)
    agent -> END          (otherwise)
    tools -> agent        (always: the result has to be read by someone)

That conditional edge IS the ReAct loop. Thought, action, observation, repeat,
until the model has nothing left to look up and just answers.

LangGraph ships a prebuilt agent - create_agent - that builds this exact graph
in one line, and in real code you would use it. It is spelled out here because
the graph is the lesson. (create_react_agent, which older tutorials use, is
deprecated in langchain v1.)

    cd ../../example_07b_kai_server_agentic && npm run dev     # first, elsewhere
    uv run python 2_react_agent_with_tools.py
    uv run python 2_react_agent_with_tools.py "I'm at OGGB and vegetarian ..."
"""

import sys
from typing import Annotated, TypedDict

from langgraph.graph import START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition

from kai_tools import get_tools
from llm import get_llm

SYSTEM = (
    "You are Kai Finder, an assistant that helps University of Auckland "
    "students find free food on campus. Use the tools to find out what is "
    "actually on right now rather than guessing. When you recommend "
    "something, say where it is, how far the walk is and how many portions "
    "are left. Be brief."
)


class KaiState(TypedDict):
    """The whole state is the conversation.

    add_messages is what makes this work: it APPENDS rather than replaces, so
    every tool result joins the transcript instead of overwriting it. That is
    also why the loop terminates - the model sees what it already looked up.
    """

    messages: Annotated[list, add_messages]


def agent_node(state: KaiState):
    """Ask the model what to do next: call a tool, or answer."""
    llm_with_tools = get_llm().bind_tools(get_tools())
    return {"messages": [llm_with_tools.invoke(state["messages"])]}


def build_graph():
    builder = StateGraph(KaiState)
    builder.add_node("agent", agent_node)
    builder.add_node("tools", ToolNode(get_tools()))

    builder.add_edge(START, "agent")
    # tools_condition reads the last message: if it carries tool calls, go to
    # "tools", otherwise go to END. One function, and it is the entire control
    # flow of an agent.
    builder.add_conditional_edges("agent", tools_condition)
    builder.add_edge("tools", "agent")

    return builder.compile()


def answer_stream(user_query: str, graph=None) -> str:
    """Run one question, printing the trace as it happens.

    The printing matters in a lecture: without it an agent is a box that pauses
    and then talks. With it you can watch it decide.
    """
    graph = graph or build_graph()
    query = {"messages": [("system", SYSTEM), ("user", user_query)]}
    final = ""
    for output in graph.stream(query):
        for node, value in output.items():
            message = value["messages"][-1]
            if node == "agent":
                if message.content:
                    final = message.content
                    print("Agent >", message.content)
                else:
                    for call in message.tool_calls:
                        print("Agent (tool calls) >", call["name"], call["args"])
            elif node == "tools":
                for result in value["messages"]:
                    print("Tool ran >", result.name, ">", result.content[:300])
            print("\n -----\n")
    return final


DEMO_QUESTION = "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?"

if __name__ == "__main__":
    graph = build_graph()
    if len(sys.argv) > 1:
        answer_stream(" ".join(sys.argv[1:]), graph=graph)
        raise SystemExit(0)

    print("Kai agent, step 02. Three tools. Type 'quit' to exit.")
    print(f'Try: "{DEMO_QUESTION}"\n')
    while True:
        try:
            user_input = input("You: ")
        except EOFError:
            break
        if user_input.lower() in ("quit", "exit"):
            break
        answer_stream(user_input, graph=graph)
