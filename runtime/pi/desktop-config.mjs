const readOnlyTools = new Set(['read', 'grep', 'find', 'ls']);

export function shouldConfirm(toolName, permission) {
  return permission !== 'full' && !readOnlyTools.has(toolName);
}

export function registerDesktopProviders(pi, environment) {
  const providers = JSON.parse(environment.PI_DESKTOP_PROVIDERS ?? '[]');
  if (!Array.isArray(providers)) throw new Error('Invalid desktop model configuration');
  for (const provider of providers) {
    if (typeof provider.id !== 'string' || !Array.isArray(provider.models)) {
      throw new Error('Invalid desktop provider');
    }
    // Pi treats !commands and $references in apiKey/headers as configuration
    // expressions. Use an environment reference so user keys stay literal.
    const keyVariable = provider.keyVariable;
    if (!/^PI_DESKTOP_KEY_\d+$/.test(keyVariable ?? '')) {
      throw new Error('Invalid desktop credential reference');
    }
    pi.registerProvider(provider.id, {
      name: provider.name,
      baseUrl: provider.baseUrl,
      api: provider.api,
      apiKey: `$${keyVariable}`,
      authHeader: provider.authHeader === true,
      headers: Object.fromEntries(Object.entries(provider.headers ?? {})
        .map(([name, value]) => [name, String(value).replaceAll('$', () => '$$').replace(/^!/, () => '$!')])),
      models: provider.models,
    });
  }
}
