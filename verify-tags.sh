#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# COMPSCI 734 example_07 - walk every step tag and check both trees.
#
# demo.sh has no verify hook, and demo.conf cannot express "run two
# toolchains", so this lives beside it rather than inside it. Do not patch
# demo.sh for this: it is the shared canonical copy from demo-controls.zip, and
# a repo that diverges from it is a repo whose tooling quietly rots.
#
# Run it like this, so that checking out a tag cannot swap the script out from
# under the shell that is reading it:
#
#     bash <(git show main:verify-tags.sh)            # static checks only
#     bash <(git show main:verify-tags.sh) --live     # also run the agents
#
# It leaves you on the branch you started from, whatever happens.
#
# Cells are four-valued: OK, FAIL, "-" (could have run, did not), and "n/a"
# (the check does not exist at this tag). Only FAIL affects the exit code.
#
# What it does NOT check: whether the answers are any good. The live checks
# assert the SHAPE of the loop - that a tool was called, that an answer came
# back afterwards - and nothing about the prose. A green table means the code
# runs at every step; it does not mean the demo lands on stage.
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

MODE=static
for arg in "$@"; do
  case "$arg" in
    --live) MODE=live ;;
    --static) MODE=static ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash first." >&2
  exit 1
fi

# --- preflight, once, on the branch we start from --------------------------
# These are properties of the day, not of a tag, so they belong above the
# table rather than in a column.
HAVE_KEY=0
[ -n "${UOA_API_KEY:-}" ] && HAVE_KEY=1
HAVE_KAI=0
curl -sf -m 3 http://localhost:3734/health >/dev/null 2>&1 && HAVE_KAI=1

echo "preflight"
echo "  uv        $(uv --version 2>/dev/null || echo 'MISSING')"
echo "  node      $(node --version 2>/dev/null || echo 'MISSING')"
echo "  UOA_API_KEY  $([ $HAVE_KEY = 1 ] && echo present || echo 'not set')"
echo "  Kai server   $([ $HAVE_KAI = 1 ] && echo 'up on :3734' || echo 'not answering on :3734')"
echo "  mode      $MODE"
echo

if [ "$MODE" = live ] && [ $HAVE_KEY = 0 ]; then
  echo "--live needs UOA_API_KEY. Nothing checked out, nothing changed." >&2
  exit 2
fi

# macOS has no timeout(1), and requiring coreutils for a script Andrew runs
# before a lecture is a bad trade.
#
# The redirections are load-bearing. A background watcher inherits the caller's
# stdout, and command substitution waits for EVERY inherited descriptor to
# close, not just the one it cares about - so a watcher that outlives the
# command hangs $(...) for the full timeout even when the command finished in a
# second. Send the watcher's output to /dev/null and it cannot hold the pipe.
with_timeout() {
  local secs=$1; shift
  "$@" &
  local pid=$!
  { sleep "$secs"; kill -9 "$pid" 2>/dev/null; } >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -9 "$watcher" 2>/dev/null
  return $rc
}

# Run one step file with a fixed prompt, writing its output to a file rather
# than capturing it, for the same reason.
run_step() {
  local file=$1 prompt=$2 out=$3
  ( cd python && with_timeout 300 uv run --quiet python "$file" "$prompt" ) >"$out" 2>&1
}

run_step_ts() {
  local file=$1 prompt=$2 out=$3
  ( cd typescript && with_timeout 300 npx tsx "src/$file" "$prompt" ) >"$out" 2>&1
}

rows=()
fails=0
skips=0

for tag in $(git tag -l 'step-*' | sort -V); do
  git checkout -q "$tag" || { echo "could not check out $tag" >&2; exit 1; }
  echo "════════ $tag ════════"

  uvs=FAIL; ruf=FAIL; imp=FAIL; tsc=FAIL; mcp="n/a"; rpy='-'; rts='-'; sec=FAIL

  # A tracked .env or a literal key is the one mistake that cannot be walked
  # back once a repo is public, so it is checked at every tag, not once.
  if git ls-files | grep -Eq '(^|/)\.env$' \
     || git grep -I -lE 'sk-[A-Za-z0-9_-]{16,}' -- . >/dev/null 2>&1; then
    echo "  CREDENTIAL TRACKED AT $tag"
  else
    sec=OK
  fi

  # --- python tree -------------------------------------------------------
  # --frozen makes this a real per-tag check: it fails if that tag's lock and
  # pyproject have drifted apart.
  ( cd python && uv sync --frozen --quiet ) >/dev/null 2>&1 && uvs=OK
  ( cd python && uv run --quiet ruff check . ) >/dev/null 2>&1 && ruf=OK

  # Load every step file WITHOUT a key in the environment. This only passes if
  # llm.py builds its client lazily and the REPL sits under __main__, both of
  # which the live checks below depend on.
  if ( cd python && env -u UOA_API_KEY uv run --quiet python - <<'PY' >/dev/null 2>&1
import glob, importlib.util, sys
for path in sorted(glob.glob("[0-9]_*.py")) + sorted(glob.glob("*_tools.py")) + ["llm.py"]:
    spec = importlib.util.spec_from_file_location(path.replace(".", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
PY
  ); then imp=OK; fi

  # Step 04 only: the MCP server's shape, introspected in process. Cheaper and
  # more deterministic than a stdio handshake.
  if [ -f python/mcp_server/kai_events_mcp.py ]; then
    mcp=FAIL
    ( cd python && uv run --quiet python - <<'PY' >/dev/null 2>&1
import asyncio, importlib.util
spec = importlib.util.spec_from_file_location("kai_events_mcp", "mcp_server/kai_events_mcp.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tools = asyncio.run(m.mcp.list_tools())
resources = asyncio.run(m.mcp.list_resource_templates()) + asyncio.run(m.mcp.list_resources())
prompts = asyncio.run(m.mcp.list_prompts())
assert len(tools) == 3, tools
assert len(resources) >= 1, resources
assert len(prompts) >= 1, prompts
PY
    ) && mcp=OK
  fi

  # --- typescript tree ---------------------------------------------------
  # npm install rather than npm ci: node_modules is gitignored, so a checkout
  # never touches it and this is a no-op after the first tag.
  ( cd typescript && npm install --no-audit --no-fund --silent ) >/dev/null 2>&1
  ( cd typescript && npx tsc --noEmit ) >/dev/null 2>&1 && tsc=OK

  # --- live runs ---------------------------------------------------------
  # Skipped, never failed, when the key or the server is missing: that is an
  # environment fact rather than a defect in the repo.
  if [ "$MODE" = live ]; then
    step=$(ls python/[0-9]_*.py 2>/dev/null | tail -1)
    needs_kai=1
    case "$tag" in *simple-agent*) needs_kai=0 ;; esac
    if [ $needs_kai = 1 ] && [ $HAVE_KAI = 0 ]; then
      rpy='-'
    else
      rpy=FAIL
      out=$(mktemp)
      for attempt in 1 2; do
        run_step "$(basename "$step")" \
          "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?" "$out"
        if [ $needs_kai = 0 ]; then
          # Step 01 must answer, and must NOT call a tool: it has none.
          if [ -s "$out" ] && ! grep -q 'Tool ran >' "$out"; then rpy=OK; break; fi
        else
          # Any later step must show a tool call AND an answer after it.
          if grep -q 'Tool ran >' "$out" && grep -q '^Agent >' "$out"; then rpy=OK; break; fi
        fi
        echo "  live attempt $attempt did not satisfy the check, retrying"
      done
      rm -f "$out"
    fi

    # The TypeScript tree ships for reading, and steps 01-02 are the two the
    # instructions ask to see running. Steps 03-04 are n/a rather than a
    # silent pass: they are verified by tsc and by hand.
    ts_step=$(ls typescript/src/[0-9]_*.ts 2>/dev/null | tail -1)
    case "$tag" in
      *simple-agent* | *react-tools*)
        if [ $needs_kai = 1 ] && [ $HAVE_KAI = 0 ]; then
          rts='-'
        else
          rts=FAIL
          out=$(mktemp)
          for attempt in 1 2; do
            run_step_ts "$(basename "$ts_step")" \
              "I'm at OGGB and vegetarian - anything I can get to in the next 20 minutes?" "$out"
            if [ $needs_kai = 0 ]; then
              # Step 01 prints the answer alone: no trace, no tool call.
              if [ -s "$out" ] && ! grep -q 'Tool ran >' "$out"; then rts=OK; break; fi
            else
              if grep -q 'Tool ran >' "$out" && grep -q '^Agent >' "$out"; then rts=OK; break; fi
            fi
            echo "  live ts attempt $attempt did not satisfy the check, retrying"
          done
          rm -f "$out"
        fi
        ;;
      *) rts="n/a" ;;
    esac
  fi

  for v in "$uvs" "$ruf" "$imp" "$tsc" "$mcp" "$rpy" "$rts" "$sec"; do
    [ "$v" = FAIL ] && fails=$((fails + 1))
    [ "$v" = '-' ] && skips=$((skips + 1))
  done
  rows+=("| \`$tag\` | $uvs | $ruf | $imp | $tsc | $mcp | $rpy | $rts | $sec |")
done

printf '\n| Tag | uv | ruff | import | tsc | mcp | run py | run ts | secrets |\n'
printf '|:--|:--|:--|:--|:--|:--|:--|:--|:--|\n'
printf '%s\n' "${rows[@]}"
printf '\nfailures: %s   skipped: %s\n' "$fails" "$skips"
[ $skips -gt 0 ] && printf 'skips are "-" cells: static mode, or no key, or no Kai server on :3734.\n'
[ "$fails" -eq 0 ]
