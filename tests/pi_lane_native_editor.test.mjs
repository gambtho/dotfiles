import assert from "node:assert/strict";
import test from "node:test";

import installLaneNativeEditor from "../ai/pi/extensions/lane-native-editor.ts";

function sessionHarness(name, editor, initialEditorText = "") {
  const listeners = new Map();
  let footer = Symbol("custom footer");
  let editorText = initialEditorText;
  const terminalListeners = new Set();
  const widgets = new Map([["powerline-top", Symbol("powerline widget")], ["other", Symbol("other widget")]]);
  const ui = {
    get editor() {
      return editor;
    },
    get footer() {
      return footer;
    },
    getEditorComponent() {
      return editor;
    },
    setEditorComponent(value) {
      editor = value;
    },
    getEditorText() {
      return editorText;
    },
    actualEditorText() {
      return editorText;
    },
    setEditorText(value) {
      editorText = value;
    },
    setFooter(value) {
      footer = value;
    },
    setWidget(name, value) {
      if (value === undefined) widgets.delete(name);
      else widgets.set(name, value);
    },
    onTerminalInput(listener) {
      terminalListeners.add(listener);
      return () => terminalListeners.delete(listener);
    },
    widget(name) {
      return widgets.get(name);
    },
  };
  installLaneNativeEditor({
    on(event, listener) {
      listeners.set(event, listener);
    },
  });
  return {
    async start() {
      await listeners.get("session_start")?.({}, {
        hasUI: true,
        ui,
        sessionManager: { getSessionName: () => name },
      });
    },
    ui,
    input(value) {
      for (const listener of terminalListeners) listener(value);
    },
  };
}

test("lane-started Pi rejects custom editors but keeps ordinary sessions unchanged", async () => {
  const original = Symbol("original editor");
  const late = Symbol("late editor");

  process.env.HERDR_ENV = "1";
  process.env.HERDR_PANE_ID = "lane:p1";
  process.env.HERDR_WORKSPACE_ID = "lane";
  const lane = sessionHarness("dotfiles-183", original);
  await lane.start();
  assert.equal(lane.ui.editor, undefined, "a lane must start with Pi's native editor");
  assert.equal(lane.ui.footer, undefined, "a lane must use Pi's native footer");
  assert.equal(lane.ui.widget("powerline-top"), undefined, "a lane must remove Powerline widgets");
  assert.ok(lane.ui.widget("other"), "a lane keeps unrelated widgets");
  assert.ok(lane.ui.getEditorText(), "a lane briefly blocks startup welcome overlays");
  assert.equal(lane.ui.actualEditorText(), "", "the startup guard must not create a visible draft");
  lane.input("\u001b[6;20;10t");
  assert.ok(lane.ui.getEditorText(), "terminal protocol replies must keep the welcome guard active");
  lane.input("R");
  assert.equal(lane.ui.getEditorText(), "", "the startup guard ends when lane input begins");
  lane.ui.setEditorComponent(late);
  lane.ui.setFooter(late);
  lane.ui.setWidget("powerline-late", late);
  assert.equal(lane.ui.editor, undefined, "a later extension cannot replace the lane editor");
  assert.equal(lane.ui.footer, undefined, "a later Powerline setup cannot replace the lane footer");
  assert.equal(lane.ui.widget("powerline-late"), undefined, "later Powerline widgets stay disabled");

  const interactive = sessionHarness("Refactor auth", original);
  await interactive.start();
  assert.equal(interactive.ui.editor, original, "ordinary named Pi keeps its configured editor");
  assert.ok(interactive.ui.footer, "ordinary Pi keeps its configured footer");
  assert.ok(interactive.ui.widget("powerline-top"), "ordinary Pi keeps its Powerline widget");
  interactive.ui.setEditorComponent(late);
  assert.equal(interactive.ui.editor, late, "ordinary Pi keeps accepting editor changes");

  const resumed = sessionHarness("dotfiles-184", original, "existing draft");
  await resumed.start();
  assert.equal(resumed.ui.actualEditorText(), "existing draft", "lane reloads preserve existing draft text");
});
