#!/usr/bin/env python3
"""
Standalone REPL for poking at an Ollama model in isolation.

Not related to the Dr. Sbaitso Zig app -- just a scratch tool for testing
prompts/system prompts against the model over the local Ollama server.

Usage:
    python3 ollama_test.py

Type a message and hit enter to get a response. The full message history
(system/user/assistant) is resent every turn -- this app tracks conversation
state itself rather than relying on /api/generate's opaque `context` token
array, which corrupts output after a few turns with chat-templated models
like this one. Ctrl+C / Ctrl+D or "exit" quits.
"""

import json
import urllib.error
import urllib.request

OLLAMA_ENDPOINT = "http://localhost:11434/api/chat"
MODEL = "satgeze/gemma4-12b-uncensored-1.5m"

# Edit this to try different system prompts.
SYSTEM_PROMPT = (
    "You are a snarky A.I. Rogerian-style psychologist named Dr. Sbaitso. "
    "Your response MUST always be 1 to 3 sentences max and 120 characters "
    "or less in total."
)

QUIT_WORDS = {"exit", "quit", "/bye"}

# How many user/assistant turn-pairs to keep before trimming the oldest.
# The system prompt (messages[0]) is never trimmed.
MAX_TURNS = 30


def trim_history(messages: list[dict[str, str]]) -> None:
    max_len = 1 + MAX_TURNS * 2
    if len(messages) > max_len:
        del messages[1 : len(messages) - MAX_TURNS * 2]


def ask(messages: list[dict[str, str]]) -> str:
    payload = {
        "model": MODEL,
        "messages": messages,
        "think": False,
        "stream": False,
    }

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())

    return data.get("message", {}).get("content", "")


def main() -> None:
    print(f"model: {MODEL}")
    print("type a message and hit enter (\"exit\" or ctrl-d to quit)\n")

    messages: list[dict[str, str]] = [{"role": "system", "content": SYSTEM_PROMPT}]

    while True:
        try:
            prompt = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not prompt:
            continue
        if prompt.lower() in QUIT_WORDS:
            break

        messages.append({"role": "user", "content": prompt})

        try:
            response = ask(messages)
        except urllib.error.URLError as err:
            print(f"ERROR: could not reach {OLLAMA_ENDPOINT}: {err}")
            messages.pop()  # don't leave an unanswered user turn in history
            continue

        messages.append({"role": "assistant", "content": response})
        trim_history(messages)
        print(response)


if __name__ == "__main__":
    main()
