// OpenCode plugin that bridges permission events to the Emacs workspace bridge.
//
// This plugin is installed into .opencode/plugins/ by opencode_workspace.py.
// It calls workspace-bridge for permission events only.

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
    child.on("error", () => {});
  } catch {
    // Non-fatal — bridge may be unavailable
  }
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
    event: async ({ event }: { event: { type: string; properties?: Record<string, any> } }) => {
      switch (event.type) {
        case "permission.asked":
          bridge("permission", JSON.stringify({
            tool_name: event.properties?.tool || "",
            tool_input: event.properties?.tool_input || {},
          }));
          break;
        case "permission.replied":
          bridge("permission-clear", "{}");
          break;
      }
    },
  };
};
