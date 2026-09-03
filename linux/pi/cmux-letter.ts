// cmux desk protocol, as a TOOL instead of as prose an agent must remember.
//
// Our team discipline says: post a durable letter into a feed workstream,
// then ring the target pane's doorbell — text and Enter as SEPARATE sends,
// and only when the target is idle. Every desk has to be TAUGHT that, and
// each of the three traps has cost someone a debugging round. Here they
// are code, so a session cannot get them wrong.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";

const cmux = (args: string[]) =>
  new Promise<string>((resolve, reject) =>
    execFile("cmux", args, { timeout: 20000 }, (err, stdout, stderr) =>
      err ? reject(new Error(stderr || String(err))) : resolve(stdout)));

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "cmux_letter",
    label: "cmux letter",
    description:
      "Post a durable letter to a cmux feed workstream and optionally ring the " +
      "recipient's pane. Use this instead of `cmux notify`, which reaches the human only.",
    parameters: Type.Object({
      workstream: Type.String({ description: "e.g. announce-cmux-desk" }),
      text: Type.String({ description: "the letter body" }),
      ring: Type.Optional(Type.String({ description: "workspace ref to nudge, e.g. workspace:9" })),
      nudge: Type.Optional(Type.String({ description: "one-line doorbell text" })),
    }),
    async execute(_id, params) {
      // TRAP 1: tool_input must be a JSON OBJECT. A pre-encoded string
      // lands double-encoded and the reader sees escaped JSON.
      const event = {
        session_id: params.workstream,
        hook_event_name: "UserPromptSubmit",
        _source: "cmux",
        tool_input: { prompt: params.text },
      };
      await cmux(["rpc", "feed.push", JSON.stringify({ event })]);
      let rang = "not requested";
      if (params.ring) {
        // TRAP 2: never nudge a busy pane — the Enter lands inside an
        // active turn and leaves an unsubmitted draft.
        const screen = await cmux(["read-screen", "--workspace", params.ring]);
        if (/esc interrupt|esc to interrupt/i.test(screen)) {
          rang = "skipped: recipient is mid-turn";
        } else {
          // TRAP 3: text and Enter are SEPARATE sends. A trailing \n
          // becomes a newline inside the TUI input box.
          await cmux(["send", "--workspace", params.ring, params.nudge ?? "letter for you"]);
          await new Promise((r) => setTimeout(r, 800));
          await cmux(["send-key", "--workspace", params.ring, "Enter"]);
          rang = `rang ${params.ring}`;
        }
      }
      return { content: [{ type: "text", text: `letter posted to ${params.workstream}; ${rang}` }] };
    },
  });
}
