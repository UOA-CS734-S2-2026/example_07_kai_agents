# Kai agents

Four agents, each exactly one idea bigger than the last. The demo repo for
**Lecture 10, Intro to Agentic AI**.

Everything runs on the UoA Agentic Gateway, and everything talks to the Kai
Events server, so no step needs an API key of its own or a paid service.

| Step | File | New idea | What changes |
|---|---|---|---|
| 1 | `1_simple_agent` | a model on its own | one node, no tools; it cannot answer, and says so |
| 2 | `2_react_agent_with_tools` | the ReAct loop | `ToolNode` + `tools_condition`, three Kai tools |
| 3 | `3_react_agent_with_tools_memory` | short and long term memory | a checkpointer per thread, a store per user |
| 4 | `4_react_agent_with_tools_memory_mcp` | the protocol boundary | the same tools, now an MCP server |

All four are on `main`, side by side. Read them in order and each one is a
short diff on the one before; that is the whole design of the repo. The
Python and TypeScript trees carry the same four files under the same names.

## Before anything

Two things have to exist first.

**1. A gateway key.** Copy `.env.example` to `.env` and paste yours in. It is
issued to you individually; do not commit it and do not share it.

```bash
cp .env.example .env
```

**2. The Kai Events server**, running in its own terminal and left there:

```bash
cd ../example_07b_kai_server_agentic
npm install
npm run dev
```

It answers on `http://localhost:3734`. Steps 2 onward call it. Before a demo,
reset it so the food is back:

```bash
curl -X POST localhost:3734/reset
```

## Running the Python steps

This is the tree used in the lecture. [uv](https://docs.astral.sh/uv/) handles
Python and the dependencies; there is no virtualenv to activate.

```bash
cd python
uv run python 1_simple_agent.py
```

Each step is a REPL. Type a question, watch the trace, type `quit` to leave.
Pass a question as an argument instead and it answers once and exits.

| Step | Command | Try |
|---|---|---|
| 1 | `uv run python 1_simple_agent.py` | *What free food is on campus today?* |
| 2 | `uv run python 2_react_agent_with_tools.py` | *I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?* |
| 3 | `uv run python 3_react_agent_with_tools_memory.py` | *I'm vegan, and I'm usually around the Science Centre.* then *Anything to eat right now?* |
| 4 | `uv run python 4_react_agent_with_tools_memory_mcp.py` | the step 2 question again: same answer, different plumbing |

Steps 3 and 4 also take `--demo`, which plays a scripted conversation. For step
3 that is the two-thread demonstration: it is told something in thread A and
still knows it in a brand new thread B, because that fact went to the store
rather than the transcript.

## Running the TypeScript steps

The same four agents, for reading rather than for the lecture.

```bash
cd typescript
npm install
npm run simple      # or: react, memory, mcp
npm run react -- "I'm at OGGB and vegetarian - anything in the next 20 minutes?"
```

Step 4 does **not** reimplement the MCP server. It starts the Python one and
talks to it, which is the entire point of a protocol: the server is Python, the
client is TypeScript, and neither one knows or cares. Porting it would have
been the M times N problem happening again in miniature.

## Looking inside the MCP server

The Inspector is the best way to see what a server actually offers. It shows
the three tools, the `campus://buildings` resource and the `find_me_food`
prompt template, and lets you call any of them by hand:

```bash
cd python
npx @modelcontextprotocol/inspector uv run mcp_server/kai_events_mcp.py
```

The server declares its own dependencies in a PEP 723 header, so it also runs
standalone, from anywhere, with no install step. That is what lets Lecture 11
mount it from a completely different repo.

## Things worth knowing

- **Do not set `temperature: 0`.** MiniMax-M3 is a reasoning model, and at
  temperature 0 with no system prompt it loops on its own reasoning until it
  hits the token limit. Every step here sends a system prompt and leaves
  temperature alone. There is a longer note in `python/llm.py`.
- **FastMCP moved.** It used to ship inside the `mcp` SDK as
  `mcp.server.fastmcp`, which is what most tutorials still import. The SDK
  dropped it in version 2.0. Import from `fastmcp`.
- The tool docstrings **are** the prompt. The model never sees the code, only
  the name, the parameter schema and the description.
- **The gateway is not hardcoded.** `UOA_BASE_URL` and `UOA_MODEL` in `.env`
  override the defaults in `python/llm.py` and `typescript/src/runtime.ts`, so
  the same four agents run against any OpenAI-compatible endpoint, a local
  Ollama included. Change the model and the temperature note above stops
  applying: it is about MiniMax-M3.

## Watching the graph run: LangGraph Studio

Everything above prints its trace to the terminal. Studio draws the graph
instead, lights each node as it fires, and lets you open the state between
nodes to see what the last one actually put there. It is the same four graphs,
looked at from the side.

```bash
cd python
uv run --with "langgraph-cli[inmem]" langgraph dev
```

`--with` layers the CLI on top of the project rather than adding it to
`pyproject.toml`: Studio is a thing you look at the code with, not something
the code depends on. uv caches the layer, so only the first run is slow.

That starts a local server on port 2024 and opens Studio in the browser,
pointed at it. Nothing is deployed and nothing leaves the machine: Studio is a
web front end talking to `localhost`. Ctrl-C stops it.

Pick a graph from the dropdown at the top left, type into the input panel on
the left, and press Submit. The graph runs, and the nodes light up as it goes.

### What each graph wants as input

Step 01's state is a single `message` field, so its input is:

```json
{ "message": "What free food is on campus today?" }
```

Steps 02 to 04 take a message list:

```json
{ "messages": [{ "role": "user", "content": "Anything to eat right now?" }] }
```

with one catch on **step 02**: it is the only step that does not build its own
system prompt, because `answer_stream` supplies one when it runs from the
terminal. In Studio you have to add it yourself, as a `system` message ahead of
the user one, or the model gets no system prompt at all - which is exactly the
condition `llm.py` warns about. Steps 03 and 04 assemble their own, so a bare
user message is fine there.

Steps 03 and 04 also read `user_id` to decide whose memories to look up. Open
the assistant's config in Studio and set it, or accept `default_user`.

### The two-thread memory demo, in Studio

This is the one worth doing here rather than in the terminal, because Studio
makes the thread boundary visible instead of asking the room to take it on
trust.

1. Pick `3_react_agent_memory`, set `user_id` to `student`.
2. Tell it *I'm vegan, and I'm usually around the Science Centre.* Watch it
   call `save_preference` on its own.
3. Start a **new thread** (the + button on the thread list), leaving `user_id`
   alone.
4. Ask *Anything to eat right now?*

The new thread has an empty transcript and still knows. Open the `agent` node's
input and the fact is sitting in the system message, put there by the store
rather than by the conversation.

### Things worth knowing in Studio

- **Steps 02 to 04 still need the Kai Events server** on port 3734, same as the
  terminal steps.
- **Step 04 takes about eight seconds to open.** Building its graph means
  starting the MCP server and asking it what tools it has, and Studio logs that
  delay as an error. It is not one.
- Studio supplies its own persistence, so the `InMemorySaver` and
  `InMemoryStore` that step 03 compiles in are ignored here. The behaviour is
  the same; the threads just outlive the process, which they do not in the
  terminal.
- `python/studio.py` is only the wiring: it hands Studio the same
  `build_graph()` every step already had. Nothing in a step file changed for
  it.
