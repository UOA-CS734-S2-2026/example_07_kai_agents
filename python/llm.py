"""The one place this repo decides which model it is talking to.

Every step imports get_llm() from here, so the four steps differ by exactly
the idea each one adds and not by a line of provider plumbing.

The UoA Agentic Gateway is OpenAI-compatible. That is worth a sentence: the
OpenAI HTTP API has become the shape everything speaks, so pointing a client
at a different base URL is the whole of "changing provider". Nothing below is
specific to OpenAI the company.

Which is why the base URL and the model are read from the environment, with
the course gateway as the default. Set UOA_BASE_URL and UOA_MODEL in .env and
every step here talks to something else, with no code change at all.
"""

import os

from dotenv import load_dotenv
from langchain_openai import ChatOpenAI

load_dotenv()

# Both are overridable from the environment, so pointing this at a different
# gateway, or at a local Ollama, is a .env edit rather than a code edit. The
# defaults are what the course runs on.
BASE_URL = os.getenv("UOA_BASE_URL", "https://agent.elliottwen.info/v1")
MODEL = os.getenv("UOA_MODEL", "MiniMax-M3")


def get_llm(**kwargs) -> ChatOpenAI:
    """Return a chat model pointed at the UoA gateway.

    Built on demand rather than at import time, so that importing a step file
    without a key is harmless. Reaching for the key at import is a habit that
    makes code impossible to test.
    """
    api_key = os.getenv("UOA_API_KEY")
    if not api_key:
        raise RuntimeError(
            "UOA_API_KEY is not set. Copy .env.example to .env and paste in your key."
        )
    return ChatOpenAI(
        base_url=BASE_URL,
        api_key=api_key,
        model=MODEL,
        # Do NOT set temperature=0 here. MiniMax-M3 is a reasoning model, and
        # at temperature 0 with no system prompt it reliably degenerates: it
        # loops on its own reasoning until it hits the token limit. Measured on
        # 2026-08-19: 32,722 completion tokens and finish_reason "length" for a
        # question that answers in 400. A system prompt alone fixes it, and so
        # does leaving temperature at the model default. Every step here does
        # both, because a lecture should not depend on either one holding.
        #
        # The cap is the third belt: whatever else happens, a runaway costs a
        # few seconds rather than the rest of the demo.
        max_tokens=2048,
        **kwargs,
    )
