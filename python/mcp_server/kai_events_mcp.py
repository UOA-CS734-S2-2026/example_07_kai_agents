# /// script
# requires-python = ">=3.11"
# dependencies = ["fastmcp>=3.4.4", "httpx>=0.28.1"]
# ///
"""The kai-events MCP server: the same three tools, behind a protocol.

Nothing about what these tools DO changes in this step. What changes is who
owns them. In step 02 the tools were functions in the agent's own process, so
using them from anywhere else meant copying the file. Here they sit behind the
Model Context Protocol, and any MCP client can mount them: this repo's agent,
opencode in the next lecture, your lab's concierge, Claude Desktop.

That is the M times N argument. Without a protocol, M agents times N tool
collections is M times N integrations. With one, it is M plus N.

An MCP server offers three kinds of thing, and this one has all three so you
can see the difference:

  TOOLS      - things the model can decide to call. Model-controlled.
  RESOURCES  - things the client can read, addressed by URI. App-controlled,
               like a file: nothing is executed, something is fetched.
  PROMPTS    - reusable templates the USER picks, usually from a menu.

Run it directly to talk to it by hand:

    uv run --directory .. mcp_server/kai_events_mcp.py

Or inspect it, which is much more informative:

    npx @modelcontextprotocol/inspector uv run mcp_server/kai_events_mcp.py

The PEP 723 header at the top of this file declares its own dependencies, so
uv can run it standalone, outside this project, with no install step. That is
what makes it easy to mount from somewhere else - the next lecture does exactly
that.

A version note, because this moves fast: FastMCP used to ship inside the
official `mcp` SDK as mcp.server.fastmcp, and most tutorials still import it
from there. The SDK dropped it in version 2.0, and FastMCP is now its own
package. Import it from `fastmcp`.
"""

import math
from datetime import datetime, timezone

import httpx
from fastmcp import FastMCP

mcp = FastMCP("kai-events")

KAI_BASE_URL = "http://localhost:3734"
WALKING_SPEED_M_PER_MIN = 80

CAMPUS_BUILDINGS = {
    "oggb": (-36.8529, 174.7702),
    "owen g glenn": (-36.8529, 174.7702),
    "business school": (-36.8529, 174.7702),
    "kate edger": (-36.8521, 174.7694),
    "general library": (-36.8521, 174.7694),
    "science centre": (-36.8525, 174.7629),
    "engineering": (-36.8527, 174.7666),
    "quad": (-36.8517, 174.7687),
    "clock tower": (-36.8523, 174.7683),
    "arts": (-36.8515, 174.7671),
    "grafton": (-36.8608, 174.7699),
    "newmarket": (-36.8656, 174.7742),
    "epsom": (-36.8877, 174.7756),
}


def _walk_minutes(from_lat: float, from_lng: float, to_lat: float, to_lng: float) -> float:
    radius_m = 6371000
    d_lat = math.radians(to_lat - from_lat)
    d_lng = math.radians(to_lng - from_lng)
    a = math.sin(d_lat / 2) ** 2 + math.cos(math.radians(from_lat)) * math.cos(
        math.radians(to_lat)
    ) * math.sin(d_lng / 2) ** 2
    return (2 * radius_m * math.asin(math.sqrt(a))) / WALKING_SPEED_M_PER_MIN


def _minutes_from_now(iso_timestamp: str) -> int:
    when = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    return round((when - datetime.now(timezone.utc)).total_seconds() / 60)


def _trim(event: dict) -> dict:
    """Cut a server record down to what a model needs. Context is a budget."""
    return {
        "id": event["id"],
        "name": event["name"],
        "description": event["description"],
        "location": event["location"],
        "portions_left": event["portionsLeft"],
        "dietary": event["dietary"],
        "lat": event["lat"],
        "lng": event["lng"],
        "on_now": event["isActive"],
        "ends_in_minutes": _minutes_from_now(event["endTime"]),
        "starts_in_minutes": _minutes_from_now(event["startTime"]),
    }


def _fetch_events() -> list:
    response = httpx.get(f"{KAI_BASE_URL}/events", timeout=10)
    response.raise_for_status()
    return [_trim(event) for event in response.json()]


@mcp.tool()
def get_food_events() -> list:
    """List every free-food event on campus right now, with location and portions left.

    Returns one entry per event with: name, description, location, portions_left,
    dietary tags, lat, lng, on_now (false if it has ended or has not started),
    ends_in_minutes and starts_in_minutes.

    Use this first when asked what food is available. It returns everything,
    including events that are over or far away, so filter afterwards.
    """
    return _fetch_events()


@mcp.tool()
def filter_events(dietary: str, max_walk_min: int, lat: float, lng: float) -> list:
    """Filter current free-food events by dietary need and walking distance from a position.

    dietary: e.g. 'vegan', 'vegetarian', 'halal', 'gluten-free', 'nut-free', or
        'none' for no restriction.
    max_walk_min: how many minutes the person is willing to walk.
    lat, lng: where they are standing. Use where_am_i to turn a building name
        into coordinates.

    Returns only events that are on right now, match the dietary need, and are
    within the walking budget, each with a walk_minutes field, nearest first.
    """
    matches = []
    for event in _fetch_events():
        if not event["on_now"]:
            continue
        if dietary and dietary != "none" and dietary not in event["dietary"]:
            continue
        walk = _walk_minutes(lat, lng, event["lat"], event["lng"])
        if walk > max_walk_min:
            continue
        matches.append({**event, "walk_minutes": round(walk, 1)})
    return sorted(matches, key=lambda e: e["walk_minutes"])


@mcp.tool()
def where_am_i(building: str) -> dict:
    """Turn a University of Auckland building or place name into coordinates.

    Accepts names and nicknames: 'OGGB', 'Owen G Glenn', 'Kate Edger',
    'General Library', 'Science Centre', 'Engineering', 'the quad',
    'Clock Tower', 'Arts', and the Grafton, Newmarket and Epsom campuses.

    Returns {"lat": ..., "lng": ...}, or an error if the name is not known.
    """
    key = building.strip().lower().removeprefix("the ")
    for name, (lat, lng) in CAMPUS_BUILDINGS.items():
        if name in key or key in name:
            return {"building": building, "lat": lat, "lng": lng}
    return {"error": f"I do not know where '{building}' is."}


@mcp.resource("campus://buildings")
def campus_buildings() -> dict:
    """Every campus location this server knows about, as name to coordinates.

    A resource rather than a tool, because nothing is computed and nothing
    happens: the client reads it, the way it would read a file. The model does
    not decide to fetch this; the application does.
    """
    return {name: {"lat": lat, "lng": lng} for name, (lat, lng) in CAMPUS_BUILDINGS.items()}


@mcp.prompt()
def find_me_food(dietary: str = "none", location: str = "the quad") -> str:
    """A ready-made question, for a user to pick out of a menu rather than type.

    Prompts are the third thing MCP offers and the one people forget. They are
    user-controlled: the host shows them as slash-commands or menu items, and
    the user chooses. Nobody is asking the model to decide anything here.
    """
    return (
        f"I'm at {location} and my dietary requirement is {dietary}. "
        "What free food can I get to in the next 20 minutes? "
        "Tell me how far the walk is and how many portions are left."
    )


if __name__ == "__main__":
    # stdio: the client starts this file as a subprocess and talks JSON-RPC
    # over its stdin and stdout. No port, no network, no auth to get wrong.
    #
    # show_banner=False because FastMCP otherwise prints a large ASCII logo to
    # stderr every time it starts, and a client that reconnects prints it
    # again. Fine in a terminal you are watching, ruinous in a lecture.
    mcp.run(show_banner=False)
