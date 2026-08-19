// The one place this tree decides which model it is talking to. The Python
// side has the same file, called llm.py, for the same reason: the four steps
// should differ by the idea each one adds, not by provider plumbing.
//
// The UoA Agentic Gateway is OpenAI-compatible, so "changing provider" is a
// base URL. Nothing here is specific to OpenAI the company.

import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { ChatOpenAI } from "@langchain/openai";
import { config as loadEnv } from "dotenv";

const currentDir = dirname(fileURLToPath(import.meta.url));
// One .env at the repo root, shared with the Python tree. Two copies of a
// secret is one copy too many.
loadEnv({ path: resolve(currentDir, "../../.env") });

export const BASE_URL = "https://agent.elliottwen.info/v1";
export const MODEL = "MiniMax-M3";

// Built on demand rather than at module load, so importing a step file without
// a key is harmless.
export function createModel(): ChatOpenAI {
  const apiKey = process.env.UOA_API_KEY;
  if (!apiKey) {
    throw new Error("UOA_API_KEY is not set. Copy .env.example to .env and paste in your key.");
  }
  return new ChatOpenAI({
    apiKey,
    model: MODEL,
    // Do NOT set temperature: 0 here. MiniMax-M3 is a reasoning model, and at
    // temperature 0 with no system prompt it reliably degenerates: it loops on
    // its own reasoning until it hits the token limit. Measured on 2026-08-19:
    // 32,722 completion tokens and finish_reason "length" for a question that
    // answers in 400. A system prompt alone fixes it, and so does leaving
    // temperature at the model default. Every step does both.
    //
    // The cap is the third belt: a runaway costs seconds, not the demo.
    maxTokens: 2048,
    configuration: { baseURL: BASE_URL },
  });
}
