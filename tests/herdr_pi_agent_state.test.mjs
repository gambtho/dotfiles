import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

// Exercise the real bridge through its Pi handler and a local Herdr socket.
// Dropping Windows recognition must fail the drive and UNC cases.
test("Herdr reports session paths with an ID fallback", { timeout: 10_000 }, async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "herdr-agent-test-"));
  const socketPath = path.join(directory, "state.sock");
  t.after(() => rm(directory, { recursive: true, force: true }));
  const previous = {};
  for (const [key, value] of Object.entries({
    HERDR_ENV: "1",
    HERDR_SOCKET_PATH: socketPath,
    HERDR_PANE_ID: "test-pane",
  })) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  t.after(() => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  let requests;
  let receivedBoth;
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      if (!buffer.includes("\n")) return;
      requests.push(JSON.parse(buffer.slice(0, buffer.indexOf("\n"))));
      socket.end("{}\n");
      if (requests.length === 2) receivedBoth();
    });
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  const { default: install } = await import("../ai/pi/extensions/herdr-agent-state.ts");
  const handlers = new Map();
  install({ on: (name, handler) => handlers.set(name, handler), events: { on() {} } });
  for (const [name, file, expected] of [
    ["POSIX", "/home/user/session.jsonl", { agent_session_path: "/home/user/session.jsonl" }],
    ["Windows drive", "C:\\Users\\user\\session.jsonl", { agent_session_path: "C:\\Users\\user\\session.jsonl" }],
    ["UNC", "\\\\server\\share\\session.jsonl", { agent_session_path: "\\\\server\\share\\session.jsonl" }],
    ["relative clears the previous path", "session.jsonl", { agent_session_id: "session-id" }],
    ["drive-relative", "C:session.jsonl", { agent_session_id: "session-id" }],
    ["missing", undefined, { agent_session_id: "session-id" }],
  ]) {
    await t.test(name, async () => {
      requests = [];
      const both = new Promise((resolve) => { receivedBoth = resolve; });
      await handlers.get("session_start")({ reason: "new" }, {
        mode: "tui",
        isIdle: () => true,
        sessionManager: { getSessionFile: () => file, getSessionId: () => "session-id" },
      });
      await both;
      assert.deepEqual(requests.map(({ method }) => method), ["pane.report_agent_session", "pane.report_agent"]);
      for (const { params } of requests) {
        assert.deepEqual(Object.fromEntries(Object.entries(params).filter(([key]) => key.startsWith("agent_session_"))), expected);
      }
    });
  }
});
