import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROMPT_KIND_LABELS: Record<string, string> = {
  select: "Select",
  confirm: "Confirm",
  input: "Input",
  editor: "Editor",
  custom: "Custom prompt",
};

function promptLabel(event: { kind?: string; title?: string }): string {
  if (typeof event.title === "string" && event.title.trim().length > 0) {
    return event.title;
  }
  if (typeof event.kind === "string" && Object.hasOwn(PROMPT_KIND_LABELS, event.kind)) {
    return PROMPT_KIND_LABELS[event.kind];
  }
  return "Prompt";
}

export default function herdrPromptState(pi: ExtensionAPI): void {
  pi.on("ui_prompt_start", (event) => {
    pi.events.emit("herdr:blocked", {
      active: true,
      label: promptLabel(event),
    });
  });

  pi.on("ui_prompt_end", () => {
    pi.events.emit("herdr:blocked", { active: false });
  });
}
