// Behavior checks for the Metroid Prime HUD extension's pure surface.
// Run through tests/fm-prime-hud.test.sh (which mirrors this test/ subdirectory layout because Pi
// auto-loads top-level .ts files in .pi/extensions/), executing: node --test test/fm-prime-hud.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { visibleWidth } from "@earendil-works/pi-tui";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import extensionDefault,
{
  beamForModel,
  contextCritical,
  evaluateHazard,
  isDestructiveCommand,
  missileReadout,
  renderHudLines,
  tanksFilled,
  type HazardState,
  type HudInput,
} from "../fm-prime-hud.ts";

function baseInput(overrides: Partial<HudInput> = {}): HudInput {
  return { percent: 38, model: "openai/gpt-5.2", beam: "power", hazardLabel: null, ...overrides };
}

test("missile reserve always renders explicit unknowns", () => {
  const unknown = missileReadout();
  assert.match(unknown.text, /\?/);
  assert.doesNotMatch(unknown.text, /\d+\s*%/);
  assert.equal(unknown.tone, "amber");
});

test("energy tanks follow one tank per 20 points of remaining context", () => {
  assert.equal(tanksFilled(0), 0);
  assert.equal(tanksFilled(20), 1);
  assert.equal(tanksFilled(40), 2);
  assert.equal(tanksFilled(60), 3);
  assert.equal(tanksFilled(80), 4);
  assert.equal(tanksFilled(100), 5);
  assert.equal(tanksFilled(10), 1);
  assert.equal(tanksFilled(120), 5);
  assert.equal(tanksFilled(null), null);
});

test("beam mapping covers known providers, unmapped fallback, and missing model", () => {
  assert.equal(beamForModel({ provider: "openai", id: "gpt-5.2" }), "power");
  assert.equal(beamForModel({ provider: "anthropic", id: "claude-sonnet" }), "plasma");
  assert.equal(beamForModel({ provider: "google", id: "gemini-3-pro" }), "wave");
  assert.equal(beamForModel({ provider: "ollama", id: "qwen" }), "ice");
  assert.equal(beamForModel({ provider: "mystery", id: "unmapped-model" }), "power");
  assert.equal(beamForModel(undefined), null);
});

test("hazard evaluation is deterministic with fixed precedence and clears", () => {
  const none: HazardState = { destructivePending: false, contextCritical: false, failureActive: false };
  assert.equal(evaluateHazard(none).kind, "none");
  const failure: HazardState = { ...none, failureActive: true };
  assert.equal(evaluateHazard(failure).kind, "failure");
  const context: HazardState = { ...failure, contextCritical: true };
  assert.equal(evaluateHazard(context).kind, "context");
  const destructive: HazardState = { ...context, destructivePending: true };
  assert.equal(evaluateHazard(destructive).kind, "destructive");
  assert.equal(evaluateHazard({ ...destructive, destructivePending: false }).kind, "context");
  assert.equal(evaluateHazard({ ...destructive, destructivePending: false, contextCritical: false }).kind, "failure");
  assert.equal(evaluateHazard({ ...destructive, ...none }).kind, "none");
});

test("context hazard threshold is 85 percent used", () => {
  assert.equal(contextCritical(84.9), false);
  assert.equal(contextCritical(85), true);
  assert.equal(contextCritical(99.5), true);
  assert.equal(contextCritical(null), false);
});

test("destructive command heuristic matches documented patterns only", () => {
  assert.equal(isDestructiveCommand("rm -rf /tmp/scratch"), true);
  assert.equal(isDestructiveCommand("git push --force origin main"), true);
  assert.equal(isDestructiveCommand("git reset --hard HEAD~3"), true);
  assert.equal(isDestructiveCommand("DROP TABLE users"), true);
  assert.equal(isDestructiveCommand("ls -la"), false);
  assert.equal(isDestructiveCommand("echo hello"), false);
  assert.equal(isDestructiveCommand("man rm"), false);
  assert.equal(isDestructiveCommand("git push origin main"), false);
});

test("unknown usage renders as unknown, never as a fabricated number", () => {
  const lines = renderHudLines(baseInput({ percent: null, model: null, beam: null }), 80).map((l) => l.text);
  const energy = lines.find((l) => l.includes("NRG")) ?? "";
  assert.match(energy, /\?/);
  assert.doesNotMatch(energy, /\d+%/);
  const tanks = lines.find((l) => l.includes("TANK")) ?? "";
  assert.match(tanks, /\?/);
  const beam = lines.find((l) => l.includes("BEAM")) ?? "";
  assert.match(beam, /BEAM \?/);
  const missile = lines.find((l) => l.includes("MSL")) ?? "";
  assert.doesNotMatch(missile, /\d+\s*%/);
});

test("every rendered line fits narrow, standard, and wide terminals", () => {
  const hazard = baseInput({ hazardLabel: "DESTRUCTIVE COMMAND PENDING" });
  for (const width of [12, 40, 80, 160]) {
    for (const input of [baseInput(), hazard, baseInput({ percent: null })]) {
      for (const line of renderHudLines(input, width)) {
        assert.ok(visibleWidth(line.text) <= width, `"${line.text}" overflows width ${width}`);
      }
    }
  }
});

test("essential telemetry stays readable at 40 columns", () => {
  const lines = renderHudLines(baseInput({ hazardLabel: "CONTEXT CRITICAL" }), 40).map((l) => l.text).join("\n");
  assert.match(lines, /NRG/);
  assert.match(lines, /TANK/);
  assert.match(lines, /MSL/);
  assert.match(lines, /BEAM/);
  assert.match(lines, /VISOR/);
  assert.match(lines, /CONTEXT CRITICAL/);
});

test("radar is present and labeled SIM only at widths that show it", () => {
  const wide = renderHudLines(baseInput(), 80).map((l) => l.text).join("\n");
  assert.match(wide, /RADAR SIM/);
  assert.match(wide, /MSL=NO SOURCE/);
  const narrow = renderHudLines(baseInput(), 40).map((l) => l.text).join("\n");
  assert.doesNotMatch(narrow, /RADAR/);
});

test("hazard line appears and disappears with the hazard label", () => {
  const armed = renderHudLines(baseInput({ hazardLabel: "DESTRUCTIVE COMMAND PENDING" }), 40).map((l) => l.text).join("\n");
  assert.match(armed, /!! DESTRUCTIVE COMMAND PENDING/);
  const clear = renderHudLines(baseInput(), 40).map((l) => l.text).join("\n");
  assert.doesNotMatch(clear, /!!/);
});

// Registration and lifecycle wiring, driven through a mock extension API: the factory must
// register only the namespaced HUD surface, and every handler must stay cheap and total.

interface Harness {
  statuses: Map<string, string | undefined>;
  handlers: Map<string, (event: Record<string, unknown>, ctx: MockCtx) => unknown>;
  commands: Map<string, unknown>;
  shortcuts: Map<string, unknown>;
  transformers: unknown[];
  widgetKey: string | undefined;
  widgetFactory: ((tui: unknown, theme: unknown) => { render(width: number): string[] }) | undefined;
  toolRegistrationAttempts: string[];
}

interface MockCtx {
  mode: string;
  model: { provider: string; id: string; contextWindow?: number } | undefined;
  getContextUsage: () => { tokens: number | null; contextWindow: number; percent: number | null } | undefined;
  sessionManager: { getBranch: () => unknown[] };
  ui: {
    setStatus: (key: string, text: string | undefined) => void;
    setWidget: (key: string, content: unknown) => void;
  };
}

function harness(): Harness {
  const captured: Harness = {
    statuses: new Map(),
    handlers: new Map(),
    commands: new Map(),
    shortcuts: new Map(),
    transformers: [],
    widgetKey: undefined,
    widgetFactory: undefined,
    toolRegistrationAttempts: [],
  };
  const pi = {
    on(event: string, handler: (event: Record<string, unknown>, ctx: MockCtx) => unknown) {
      captured.handlers.set(event, handler);
    },
    registerCommand(name: string, options: unknown) {
      captured.commands.set(name, options);
    },
    registerShortcut(id: string, options: unknown) {
      captured.shortcuts.set(id, options);
    },
    registerMarkdownTransformer(fn: unknown) {
      captured.transformers.push(fn);
    },
    registerTool(tool: { name?: string }) {
      captured.toolRegistrationAttempts.push(String(tool?.name));
    },
  };
  extensionDefault(pi as unknown as ExtensionAPI);
  return captured;
}

function ctxMock(usage: { tokens: number | null; contextWindow: number; percent: number | null } | undefined, captured: Harness): MockCtx {
  return {
    mode: "tui",
    model: undefined,
    getContextUsage: () => usage,
    sessionManager: { getBranch: () => [] },
    ui: {
      setStatus: (key, text) => {
        captured.statuses.set(key, text);
      },
      setWidget: (key, content) => {
        captured.widgetKey = key;
        captured.widgetFactory = (content as Harness["widgetFactory"]) ?? undefined;
      },
    },
  };
}

const mockTheme = {
  appearance: "dark",
  colors: { dim: { kind: "indexed", index: 8 } },
  style: (text: string) => text,
};

test("factory registers only the namespaced HUD surface", () => {
  const captured = harness();
  assert.deepEqual(captured.toolRegistrationAttempts, []);
  assert.deepEqual(captured.transformers, []);
  assert.equal(captured.commands.size, 0);
  assert.equal(captured.shortcuts.size, 0);
  const start = captured.handlers.get("session_start");
  assert.ok(start);
  const ctx = ctxMock(undefined, captured);
  start({ type: "session_start" }, ctx);
  assert.ok(captured.widgetKey?.startsWith("fm-prime-hud-"));
  for (const key of captured.statuses.keys()) assert.ok(key.startsWith("fm-prime-hud-"), key);
});

test("session lifecycle: start paints, shutdown clears", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-energy"), "NRG ?");
  assert.match(captured.statuses.get("fm-prime-hud-visor") ?? "", /VSR BEAM \?/);
  const component = captured.widgetFactory?.({ requestRender() {} }, mockTheme);
  assert.ok(component);
  const lines = component.render(40);
  assert.ok(lines.length > 0);
  for (const line of lines) assert.ok(visibleWidth(line) <= 40, line);
  captured.handlers.get("session_shutdown")?.({ type: "session_shutdown" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-energy"), undefined);
  assert.equal(captured.statuses.get("fm-prime-hud-hazard"), undefined);
  assert.equal(captured.widgetFactory, undefined);
});

test("non-tui modes keep the extension inert", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  ctx.mode = "json";
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.equal(captured.widgetFactory, undefined);
  assert.equal(captured.statuses.size, 0);
});

test("hazard status arms on a destructive call and clears on its result", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-hazard"), undefined);
  captured.handlers.get("tool_call")?.({ type: "tool_call", toolName: "bash", toolCallId: "t1", input: { command: "rm -rf build" } }, ctx);
  assert.match(captured.statuses.get("fm-prime-hud-hazard") ?? "", /DESTRUCTIVE COMMAND PENDING/);
  captured.handlers.get("tool_result")?.({ type: "tool_result", toolCallId: "t1", isError: false }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-hazard"), undefined);
  captured.handlers.get("tool_result")?.({ type: "tool_result", toolCallId: "t2", isError: true }, ctx);
  assert.match(captured.statuses.get("fm-prime-hud-hazard") ?? "", /LAST OPERATION FAILED/);
  captured.handlers.get("session_compact")?.({ type: "session_compact" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-hazard"), undefined);
});

test("model selection updates the beam readout", () => {
  const captured = harness();
  const ctx = ctxMock({ tokens: 1000, contextWindow: 200_000, percent: 0.5 }, captured);
  ctx.model = { provider: "anthropic", id: "claude-x" };
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.match(captured.statuses.get("fm-prime-hud-visor") ?? "", /BEAM PLASMA/);
  assert.match(captured.statuses.get("fm-prime-hud-energy") ?? "", /NRG 100%/);
  ctx.model = { provider: "mystery", id: "unmapped" };
  captured.handlers.get("model_select")?.({ type: "model_select" }, ctx);
  assert.match(captured.statuses.get("fm-prime-hud-visor") ?? "", /BEAM POWER/);
});

test("unknown context usage never fabricates a percent from branch history", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  ctx.model = { provider: "openai", id: "gpt-5.2", contextWindow: 200_000 };
  ctx.sessionManager = {
    getBranch: () =>
      Array.from({ length: 50 }, () => ({
        type: "message",
        message: { role: "assistant", usage: { input: 9_000, output: 1_000 } },
      })),
  };
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-energy"), "NRG ?");
  assert.equal(captured.statuses.get("fm-prime-hud-hazard"), undefined);
});
