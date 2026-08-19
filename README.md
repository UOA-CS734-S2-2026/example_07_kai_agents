# Kai agents

Four agents, each exactly one idea bigger than the last. The demo repo for
**Lecture 10, Intro to Agentic AI**.

Everything runs on the UoA Agentic Gateway, and everything talks to the Kai
Events server, so no step needs an API key of its own or a paid service.

| Step | Tag | New idea | What changes |
|---|---|---|---|
| 1 | `step-01-simple-agent` | a model on its own | one node, no tools; it cannot answer, and says so |
| 2 | `step-02-react-tools` | the ReAct loop | `ToolNode` + `tools_condition`, three Kai tools |
| 3 | `step-03-memory` | short and long term memory | a checkpointer per thread, a store per user |
| 4 | `step-04-mcp` | the protocol boundary | the same tools, now an MCP server |

`main` sits at the final step.

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

## Verifying every step

```bash
bash <(git show main:verify-tags.sh)            # static checks
bash <(git show main:verify-tags.sh) --live     # also run the agents
```

### How to use the demo scripts

The buttons in the VS Code status bar step through the tags, or from a
terminal:

```bash
./demo.sh list          # every step, with the current one marked
./demo.sh next          # forward one step
./demo.sh prev          # back one step
./demo.sh jump 03       # straight to a step (two digits)
./demo.sh reset         # leave the demo, back to main
```

Stepping is destructive by design: it throws away uncommitted changes so the
code is exactly right for the next thing you want to show. Your `.env` and
`.venv` are ignored, so they survive.

`DEMO-CONTROLS.md` has the full write-up.
