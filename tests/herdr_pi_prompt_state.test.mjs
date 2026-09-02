import assert from "node:assert/strict";
import test from "node:test";

import installHerdrPromptState from "../ai/pi/extensions/herdr-prompt-state.ts";

function createHarness() {
  const handlers = new Map();
  const emitted = [];
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    events: {
      emit(event, data) {
        emitted.push({ event, data });
      },
    },
  };

  installHerdrPromptState(pi);
  return { emitted, handlers };
}

test("reports Pi UI prompts as blocked until the prompt ends", () => {
  const { emitted, handlers } = createHarness();

  handlers.get("ui_prompt_start")({ kind: "confirm", title: "Permission Required" });
  handlers.get("ui_prompt_end")({ kind: "confirm", title: "Permission Required" });

  assert.deepEqual(emitted, [
    {
      event: "herdr:blocked",
      data: { active: true, label: "Permission Required" },
    },
    {
      event: "herdr:blocked",
      data: { active: false },
    },
  ]);
});

test("uses a readable fallback when a prompt has no title", () => {
  const { emitted, handlers } = createHarness();

  handlers.get("ui_prompt_start")({ kind: "select" });

  assert.deepEqual(emitted, [
    {
      event: "herdr:blocked",
      data: { active: true, label: "Select" },
    },
  ]);
});

test("uses a generic fallback for an unknown prompt kind", () => {
  const { emitted, handlers } = createHarness();

  handlers.get("ui_prompt_start")({ kind: "future-prompt", title: "  " });

  assert.deepEqual(emitted, [
    {
      event: "herdr:blocked",
      data: { active: true, label: "Prompt" },
    },
  ]);
});
