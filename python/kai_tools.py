"""The three tools the Kai agent gets in step 02.

Read the docstrings below as prompts, because that is what they are. The model
never sees this code. It sees the function name, the parameter names and types,
and the docstring, serialised into a JSON schema and pasted into its context on
every single request. A vague docstring is a vague prompt, and the usual
symptom is an agent that has exactly the right tool available and does not use
it.

Everything here talks to the Kai Events server on localhost:3734. Start it
first, in its own terminal:

    cd ../../example_07b_kai_server_agentic && npm run dev
"""

import math
from datetime import datetime, timezone

import httpx
from langchain_core.tools import tool

KAI_BASE_URL = "http://localhost:3734"

# Metres per minute on foot. Slower than the 84 m/min people usually quote,
# because campus has stairs, doors and other students in it.
WALKING_SPEED_M_PER_MIN = 80

# Where things are. A real app would ask the phone; a lecture demo hardcodes it
# and gets on with the interesting part. Coordinates match the Kai server's
# seed data, so distances come out sensible.
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
    """Great-circle distance, converted to a walk. Straight lines, no buildings."""
    radius_m = 6371000
    d_lat = math.radians(to_lat - from_lat)
    d_lng = math.radians(to_lng - from_lng)
    a = math.sin(d_lat / 2) ** 2 + math.cos(math.radians(from_lat)) * math.cos(
        math.radians(to_lat)
    ) * math.sin(d_lng / 2) ** 2
    metres = 2 * radius_m * math.asin(math.sqrt(a))
    return metres / WALKING_SPEED_M_PER_MIN


def _minutes_from_now(iso_timestamp: str) -> int:
    when = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    return round((when - datetime.now(timezone.utc)).total_seconds() / 60)


def _trim(event: dict) -> dict:
    """Cut a server record down to what the model actually needs.

    This is not tidiness, it is context budget. The server sends thirteen
    fields per event and there are fourteen events; all of it would land in the
    context window on every turn, and the model would pay attention to the
    emoji. So: drop what nothing can use (emoji, postedById), and turn the two
    ISO timestamps into one number a model can reason about directly, because
    "ends in 34 minutes" is a fact and "2026-08-19T06:43:38.441Z" is arithmetic
    homework.
    """
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


@tool
def get_food_events() -> list:
    """List every free-food event on campus right now, with location and portions left.

    Returns one entry per event with: name, description, location, portions_left,
    dietary tags, lat, lng, on_now (false if it has ended or has not started),
    ends_in_minutes and starts_in_minutes.

    Use this first when asked what food is available. It returns everything,
    including events that are over or far away, so filter afterwards.
    """
    response = httpx.get(f"{KAI_BASE_URL}/events", timeout=10)
    response.raise_for_status()
    return [_trim(event) for event in response.json()]


@tool
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
    events = httpx.get(f"{KAI_BASE_URL}/events", timeout=10)
    events.raise_for_status()

    matches = []
    for event in (_trim(e) for e in events.json()):
        if not event["on_now"]:
            continue
        if dietary and dietary != "none" and dietary not in event["dietary"]:
            continue
        walk = _walk_minutes(lat, lng, event["lat"], event["lng"])
        if walk > max_walk_min:
            continue
        matches.append({**event, "walk_minutes": round(walk, 1)})

    return sorted(matches, key=lambda e: e["walk_minutes"])


@tool
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


def get_tools():
    """The tools the agent is allowed to use."""
    return [get_food_events, filter_events, where_am_i]
