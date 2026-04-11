---
description: Start structured brainstorm → spec → plan → implement workflow for a new feature or idea
---

# Brainstorm → Design → Plan → Build

Start a structured workflow for turning an idea into working code. $ARGUMENTS

## Instructions

Load the `brainstorming` skill using the skill tool and follow it exactly. The skill defines the full workflow:

1. **Brainstorming** — explore context, ask clarifying questions, propose approaches, present design, write spec
2. **Writing plans** — the brainstorming skill transitions to the `writing-plans` skill automatically after spec approval
3. **Execution** — the writing-plans skill offers execution options after the plan is written

**Do NOT skip the skill or improvise your own workflow.** The skill has a detailed checklist, visual companion support, spec self-review process, and user approval gates. Follow all of it.

### OpenCode-specific notes

**Visual companion:** If the brainstorming skill offers the visual companion and the user accepts, the server scripts are located at:

```
~/.cache/opencode/packages/superpowers@git+https:/github.com/obra/superpowers.git/node_modules/superpowers/skills/brainstorming/scripts/
```

To start the server:
```bash
SCRIPTS_DIR="$(find ~/.cache/opencode/packages -path '*/superpowers/skills/brainstorming/scripts/start-server.sh' 2>/dev/null | head -1 | xargs dirname)"
"$SCRIPTS_DIR/start-server.sh" --project-dir "$(pwd)"
```

If running in a devcontainer or remote environment, add `--host 0.0.0.0 --url-host localhost`.

**Visual companion — terminal vs browser (strictly enforced):**

Once the user accepts the visual companion, apply this rule to EVERY question:

- **Use the terminal** for: scope, requirements, feature priorities, tradeoffs, conceptual A/B choices, anything where the answer is words. This includes most early brainstorming questions.
- **Use the browser** only when you are showing actual visual content: rendered wireframes, layout comparisons, color/typography comparisons, UI structure diagrams.

**When using the browser, you MUST render real mockups — not text descriptions.**

Wrong (never do this):
```html
<div class="option" data-choice="a">
  <div class="letter">A</div>
  <div class="content"><h3>Sidebar Layout</h3><p>Navigation on the left</p></div>
</div>
```

Right — use the mock-* CSS classes to render the actual UI structure:
```html
<div class="card" data-choice="a" onclick="toggleSelect(this)">
  <div class="card-image">
    <div class="mockup-body">
      <div class="mock-nav">Logo | Home | Settings</div>
      <div style="display:flex">
        <div class="mock-sidebar">Nav items</div>
        <div class="mock-content">Main content area</div>
      </div>
    </div>
  </div>
  <div class="card-body"><h3>Sidebar Layout</h3></div>
</div>
```

For color/typography comparisons, render real examples with inline styles — actual font sizes, actual color swatches, actual spacing. Never describe visual properties in text when you can show them.

**Subagent execution:** When the writing-plans skill offers "Subagent-Driven" vs "Inline Execution" at the end, use OpenCode's `task` tool with `subagent_type: "general"` to dispatch subagents for individual plan tasks. This is the OpenCode equivalent of Claude Code's `Task` tool.

**Hard rule:** Do NOT write any code until the spec has been approved and the implementation plan has been written. The entire point of `/brainstorm` is design before implementation.
