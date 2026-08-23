"""Graph entry points for LangGraph Studio.

`langgraph dev` reads langgraph.json, which points at the four functions
below. Studio then draws each graph and lets you run it a node at a time,
watching the state change between them. Nothing here changes any step: every
graph returned is the graph that step's own build_graph() builds.

Two things stop langgraph.json pointing straight at the step files.

The step files are named 1_simple_agent.py, 2_react_agent_with_tools.py and so
on, so a directory listing reads in lecture order. Python cannot import a
module whose name starts with a digit - `import 1_simple_agent` is a syntax
error - so importlib loads them by name instead. The filenames are worth more
to a room full of students than importability is to this file.

Step 04's build_graph is async and takes its tools as an argument, because it
has to ask the MCP server what tools exist before it can bind them. Studio
wants something it can call with nothing, so it gets the wrapper below.
"""

import importlib
import sys
from pathlib import Path

# Studio imports this file by path, so the step files beside it are not
# necessarily importable yet.
sys.path.insert(0, str(Path(__file__).parent))


def _step(name):
    return importlib.import_module(name)


def simple_agent():
    """Step 01: one node, no tools."""
    return _step("1_simple_agent").build_graph()


def react_agent():
    """Step 02: the ReAct loop, three local tools."""
    return _step("2_react_agent_with_tools").build_graph()


def react_agent_memory():
    """Step 03: the same loop, plus a checkpointer and a store."""
    return _step("3_react_agent_with_tools_memory").build_graph()


async def react_agent_memory_mcp():
    """Step 04: the same graph again, with the tools behind MCP."""
    step = _step("4_react_agent_with_tools_memory_mcp")
    return await step.build_graph(await step.get_tools())
