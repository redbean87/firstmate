// Fake Pi extension API for the moot-wake fork tests (fork/tests only).
//
// It implements exactly the surface the REAL upstream watch extension and the
// fork extension use: handler registration, tool registration, an
// accept-or-drop sendUserMessage that records every follow-up, and a
// synchronous in-order event bus shaped like Pi's shared `pi.events`.
// Nothing is consumed unless a test calls consume(), so a delivered wake stays
// "accepted but unconsumed" exactly as it does in a busy Pi session.
export function createFakePi() {
  const handlers = new Map();
  const listeners = new Map();
  const prompts = [];
  const emitted = [];
  let tool = null;
  const pi = {
    on(name, handler) { handlers.set(name, handler); },
    registerCommand() {},
    registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
    sendUserMessage: async (message) => { prompts.push(String(message)); },
    events: {
      on(name, listener) {
        if (!listeners.has(name)) listeners.set(name, []);
        listeners.get(name).push(listener);
        return () => {};
      },
      emit(name, data) {
        emitted.push({ name, data });
        for (const listener of listeners.get(name) ?? []) listener(data);
      },
    },
  };
  return {
    pi,
    prompts,
    emitted,
    handlers,
    get tool() { return tool; },
    async fire(name, event) { return handlers.get(name)?.(event, {}); },
  };
}

export async function waitFor(condition, timeoutMs, what) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${what}`);
}

export const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
