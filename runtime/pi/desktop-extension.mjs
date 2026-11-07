import { registerDesktopProviders, shouldConfirm } from './desktop-config.mjs';

// Loaded explicitly by pi-desktop. Credentials arrive in the child's environment,
// never in its command line, settings.json, or a generated extension file.
export default async function desktopExtension(pi) {
  registerDesktopProviders(pi, process.env);
  let permission = process.env.PI_DESKTOP_PERMISSION ?? 'ask';
  pi.registerCommand('desktop-permission', {
    description: 'Set the desktop tool approval policy',
    handler: async (args) => {
      if (!['ask', 'full'].includes(args.trim())) throw new Error('Unknown approval policy');
      permission = args.trim();
    },
  });
  let rpc;
  pi.on('tool_call', async (event, ctx) => {
    if (shouldConfirm(event.toolName, permission)) {
      if (!ctx.hasUI) return { block: true, reason: 'Desktop approval is unavailable' };
      const confirmed = await ctx.ui.confirm(
        `Allow ${event.toolName}?`,
        JSON.stringify(event.input, null, 2),
      );
      if (!confirmed) return { block: true, reason: 'The user denied this tool call' };
    }
    if (rpc && ['edit', 'write'].includes(event.toolName) && typeof event.input.path === 'string') {
      await rpc('desktop/before_edit', { path: event.input.path });
    }
  });
  pi.on('tool_result', async (event) => {
    if (rpc && ['edit', 'write'].includes(event.toolName) && typeof event.input.path === 'string') {
      await rpc('desktop/after_edit', { path: event.input.path });
    }
  });

  const endpoint = process.env.PI_DESKTOP_HOST_URL;
  const token = process.env.PI_DESKTOP_HOST_TOKEN;
  if (!endpoint || !token) return;
  let requestId = 0;
  rpc = async (method, params, signal) => {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++requestId, method, params }),
      signal,
    });
    if (!response.ok) throw new Error(`Desktop tools returned HTTP ${response.status}`);
    const message = await response.json();
    if (message.error) throw new Error(message.error.message);
    return message.result;
  };
  const initialized = await rpc('initialize', { protocolVersion: '2024-11-05' });
  if (initialized.instructions) {
    pi.on('before_agent_start', async (event) => ({
      systemPrompt: `${event.systemPrompt}\n\n${initialized.instructions}`,
    }));
  }
  const { tools = [] } = await rpc('tools/list', {});
  for (const tool of tools) {
    pi.registerTool({
      name: `mcp__pi_desktop__${tool.name}`,
      label: tool.name,
      description: tool.description,
      parameters: tool.inputSchema,
      execute: async (toolCallId, args, signal) => {
        const result = await rpc('tools/call', {
          name: tool.name,
          arguments: args,
          _meta: { 'claudecode/toolUseId': toolCallId },
        }, signal);
        if (result.isError) {
          throw new Error(result.content?.filter((block) => block.type === 'text')
            .map((block) => block.text).join('\n') || 'Desktop tool failed');
        }
        return { content: result.content ?? [], details: {} };
      },
    });
  }
}
