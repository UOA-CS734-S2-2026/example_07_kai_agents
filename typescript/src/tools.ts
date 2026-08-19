// The three tools the Kai agent gets in step 02.
//
// Read the descriptions below as prompts, because that is what they are. The
// model never sees this code. It sees the tool name, the parameter schema and
// the description, pasted into its context on every single request. A vague
// description is a vague prompt, and the usual symptom is an agent that has
// exactly the right tool available and does not use it.
//
// Everything here talks to the Kai Events server on localhost:3734.

import { tool } from "@langchain/core/tools";
import { z } from "zod";

const KAI_BASE_URL = "http://localhost:3734";

// Metres per minute on foot. Slower than the 84 m/min people usually quote,
// because campus has stairs, doors and other students in it.
const WALKING_SPEED_M_PER_MIN = 80;

// Where things are. A real app would ask the phone; a lecture demo hardcodes
// it and gets on with the interesting part.
const CAMPUS_BUILDINGS: Record<string, [number, number]> = {
  oggb: [-36.8529, 174.7702],
  "owen g glenn": [-36.8529, 174.7702],
  "business school": [-36.8529, 174.7702],
  "kate edger": [-36.8521, 174.7694],
  "general library": [-36.8521, 174.7694],
  "science centre": [-36.8525, 174.7629],
  engineering: [-36.8527, 174.7666],
  quad: [-36.8517, 174.7687],
  "clock tower": [-36.8523, 174.7683],
  arts: [-36.8515, 174.7671],
  grafton: [-36.8608, 174.7699],
  newmarket: [-36.8656, 174.7742],
  epsom: [-36.8877, 174.7756],
};

type KaiEvent = {
  id: string;
  name: string;
  description: string;
  location: string;
  portionsLeft: number;
  isActive: boolean;
  lat: number;
  lng: number;
  dietary: string[];
  startTime: string;
  endTime: string;
};

function walkMinutes(fromLat: number, fromLng: number, toLat: number, toLng: number): number {
  const radiusM = 6371000;
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(toLat - fromLat);
  const dLng = rad(toLng - fromLng);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(fromLat)) * Math.cos(rad(toLat)) * Math.sin(dLng / 2) ** 2;
  return (2 * radiusM * Math.asin(Math.sqrt(a))) / WALKING_SPEED_M_PER_MIN;
}

const minutesFromNow = (iso: string) => Math.round((Date.parse(iso) - Date.now()) / 60000);

// Cut a server record down to what the model actually needs. This is not
// tidiness, it is context budget: thirteen fields times fourteen events lands
// in the context window on every turn. Turning the timestamps into a number of
// minutes matters too - "ends in 34 minutes" is a fact, an ISO timestamp is
// arithmetic homework.
function trim(event: KaiEvent) {
  return {
    id: event.id,
    name: event.name,
    description: event.description,
    location: event.location,
    portions_left: event.portionsLeft,
    dietary: event.dietary,
    lat: event.lat,
    lng: event.lng,
    on_now: event.isActive,
    ends_in_minutes: minutesFromNow(event.endTime),
    starts_in_minutes: minutesFromNow(event.startTime),
  };
}

async function fetchEvents() {
  const response = await fetch(`${KAI_BASE_URL}/events`);
  if (!response.ok) throw new Error(`Kai server said ${response.status}`);
  return ((await response.json()) as KaiEvent[]).map(trim);
}

export const getFoodEvents = tool(async () => JSON.stringify(await fetchEvents()), {
  name: "get_food_events",
  description:
    "List every free-food event on campus right now, with location and portions left. " +
    "Returns one entry per event with: name, description, location, portions_left, " +
    "dietary tags, lat, lng, on_now (false if it has ended or has not started), " +
    "ends_in_minutes and starts_in_minutes. Use this first when asked what food is " +
    "available. It returns everything, including events that are over or far away, so " +
    "filter afterwards.",
  schema: z.object({}),
});

export const filterEvents = tool(
  async ({ dietary, max_walk_min, lat, lng }) => {
    const matches = (await fetchEvents())
      .filter((e) => e.on_now)
      .filter((e) => !dietary || dietary === "none" || e.dietary.includes(dietary))
      .map((e) => ({ ...e, walk_minutes: Math.round(walkMinutes(lat, lng, e.lat, e.lng) * 10) / 10 }))
      .filter((e) => e.walk_minutes <= max_walk_min)
      .sort((a, b) => a.walk_minutes - b.walk_minutes);
    return JSON.stringify(matches);
  },
  {
    name: "filter_events",
    description:
      "Filter current free-food events by dietary need and walking distance from a " +
      "position. Returns only events that are on right now, match the dietary need, and " +
      "are within the walking budget, each with a walk_minutes field, nearest first.",
    schema: z.object({
      dietary: z
        .string()
        .describe("e.g. 'vegan', 'vegetarian', 'halal', 'gluten-free', 'nut-free', or 'none'"),
      max_walk_min: z.number().describe("how many minutes the person is willing to walk"),
      lat: z.number().describe("where they are standing"),
      lng: z.number().describe("where they are standing"),
    }),
  },
);

export const whereAmI = tool(
  async ({ building }) => {
    const key = building.trim().toLowerCase().replace(/^the /, "");
    for (const [name, [lat, lng]] of Object.entries(CAMPUS_BUILDINGS)) {
      if (name.includes(key) || key.includes(name)) return JSON.stringify({ building, lat, lng });
    }
    return JSON.stringify({ error: `I do not know where '${building}' is.` });
  },
  {
    name: "where_am_i",
    description:
      "Turn a University of Auckland building or place name into coordinates. Accepts " +
      "names and nicknames: 'OGGB', 'Owen G Glenn', 'Kate Edger', 'General Library', " +
      "'Science Centre', 'Engineering', 'the quad', 'Clock Tower', 'Arts', and the " +
      "Grafton, Newmarket and Epsom campuses.",
    schema: z.object({ building: z.string() }),
  },
);

export const getTools = () => [getFoodEvents, filterEvents, whereAmI];
