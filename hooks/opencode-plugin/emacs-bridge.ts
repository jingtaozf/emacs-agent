// OpenCode plugin that bridges events to the Emacs workspace bridge.
//
// This plugin is installed into .opencode/plugins/ by opencode_workspace.py.
// It reads CLAUDE_PLUGIN_ROOT and calls workspace-bridge with the appropriate
// event type, mirroring the hook pattern used by Claude Code and Copilot CLI.
//
// OpenCode plugin API: the default export is a function that receives
// { project, client, $, directory } and returns an object with event handlers.
//
// Unlike Claude Code (JSONL transcript files) and Copilot (events.jsonl),
// OpenCode stores sessions in SQLite.  We use the `client` SDK to read the
// last assistant message and pass it directly as `last_assistant_message` in
// the bridge payload, which workspace_bridge.py already supports as a fallback.

import { spawn } from "child_process";

function bridge(event: string, input?: string): void {
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return;

  const cmd = "uv";
  const args = ["run", "--project", `${pluginRoot}/python`, "workspace-bridge", event];
  try {
    const child = spawn(cmd, args, {
      stdio: ["pipe", "inherit", "inherit"],
      env: process.env,
    });
    if (input) {
      child.stdin.write(input);
      child.stdin.end();
    } else {
      child.stdin.end();
    }
    // Fire-and-forget — don't block the event loop
    child.on("error", () => {});
  } catch {
    // Non-fatal — bridge may be unavailable
  }
}

/**
 * Fetch all messages from an OpenCode session.
 * Returns the raw messages array (each with .info.role and .parts).
 */
async function fetchMessages(client: any, sessionID: string): Promise<any[]> {
  if (!sessionID || !client?.session?.messages) return [];
  try {
    const result = await client.session.messages({ path: { id: sessionID } });
    const messages = result?.data ?? result ?? [];
    return Array.isArray(messages) ? messages : [];
  } catch {
    return [];
  }
}

/**
 * Extract the last assistant response text from session messages.
 * Collects text parts from assistant messages after the last user message.
 */
function extractLastResponse(messages: any[]): string {
  const texts: string[] = [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    const role = msg?.info?.role ?? msg?.role ?? "";
    if (role === "user") break;
    if (role === "assistant") {
      const parts = msg?.parts ?? [];
      for (const part of parts) {
        if (part?.type === "text" && part?.text) {
          texts.unshift(part.text);
        }
      }
    }
  }
  return texts.join("\n\n");
}

/**
 * Extract the last user message text from session messages.
 * Finds the last message with role "user" and collects its text parts.
 */
function extractLastUserMessage(messages: any[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    const role = msg?.info?.role ?? msg?.role ?? "";
    if (role === "user") {
      const parts = msg?.parts ?? [];
      const texts: string[] = [];
      for (const part of parts) {
        if (part?.type === "text" && part?.text) {
          texts.push(part.text);
        }
      }
      return texts.join("\n\n");
    }
  }
  return "";
}

export default async ({
  project,
  client,
  $,
  directory,
}: {
  project: any;
  client: any;
  $: any;
  directory: string;
}) => {
  return {
    // Session-level events from OpenCode
    event: async ({ event }: { event: { type: string; properties?: Record<string, any> } }) => {
      switch (event.type) {
        case "session.idle": {
          const sessionID = event.properties?.sessionID || "";
          const messages = await fetchMessages(client, sessionID);
          const response = extractLastResponse(messages);
          const prompt = extractLastUserMessage(messages);
          bridge("response", JSON.stringify({
            session_id: sessionID,
            last_assistant_message: response,
            last_user_message: prompt,
          }));
          break;
        }
        case "session.error":
          bridge("response", JSON.stringify({
            session_id: event.properties?.sessionID || "",
            error: event.properties?.message || "unknown error",
          }));
          break;
        case "permission.asked":
          bridge("permission", JSON.stringify({
            tool: event.properties?.tool || "",
            permission_id: event.properties?.permissionID || "",
          }));
          break;
        case "permission.replied":
          bridge("permission-clear", "{}");
          break;
      }
    },

    // Tool execution hooks — only fire "tool" events, NOT permission events.
    // Permission events come from "permission.asked" / "permission.replied" above.
    // Firing permission from tool.execute.before would cause double events.
    "tool.execute.before": async (input: any, _output: any) => {
      if (input?.tool) {
        bridge("tool", JSON.stringify({
          tool: input.tool,
          phase: "pre",
        }));
      }
    },

    "tool.execute.after": async (input: any, _output: any) => {
      if (input?.tool) {
        bridge("tool", JSON.stringify({
          tool: input.tool,
          phase: "post",
        }));
      }
    },
  };
};
