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
  hashText,
  isDestructiveCommand,
  missileReadout,
  nextVisorMode,
  parseVisorMode,
  renderHudLines,
  tanksFilled,
  transformForVisor,
  THERMAL_WINDOW_MS,
  type HazardState,
  type HudInput,
  type VisorMode,
} from "../fm-prime-hud.ts";

function baseInput(overrides: Partial<HudInput> = {}): HudInput {
  return { visor: "combat", percent: 38, model: "openai/gpt-5.2", beam: "power", hazardLabel: null, ...overrides };
}

test("missile reserve renders honest unknowns with no source", () => {
  const unknown = missileReadout(null);
  assert.match(unknown.text, /\?/);
  assert.doesNotMatch(unknown.text, /\d+\s*%/);
  assert.equal(unknown.tone, "amber");
});

test("missile reserve formats known and partially known budgets", () => {
  const both = missileReadout({ fiveHourPercent: 12.4, sevenDayPercent: 40 });
  assert.match(both.text, /5h:12%/);
  assert.match(both.text, /7d:40%/);
  const one = missileReadout({ fiveHourPercent: null, sevenDayPercent: 40 });
  assert.match(one.text, /5h:\?/);
  assert.match(one.text, /7d:40%/);
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

function stripPrefix(markdown: string, prefix: string): string {
  return markdown
    .split("\n")
    .map((line) => (line.startsWith(prefix) ? line.slice(prefix.length) : line))
    .join("\n");
}

function normalizeEmphasis(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "").replace(/[*_`]/g, "");
}

const SAMPLE = [
  "Fix the **parser** and *fast* path",
  "",
  "```bash",
  "echo **not bolded**",
  "```",
  "",
  "| a | b |",
  "| - | - |",
  "",
  "Final _notes_ here",
].join("\n");

test("combat mode is byte-identical to the original markdown", () => {
  assert.equal(transformForVisor("combat", SAMPLE), SAMPLE);
  assert.equal(transformForVisor("combat", ""), "");
  assert.equal(transformForVisor("combat", "plain **text** `code`"), "plain **text** `code`");
});

test("scan mode adds a grid rule without losing or altering content", () => {
  const out = transformForVisor("scan", SAMPLE);
  assert.notEqual(out, SAMPLE);
  const restored = stripPrefix(out, "┃ ");
  assert.equal(restored, SAMPLE);
  const lines = SAMPLE.split("\n");
  const outLines = out.split("\n");
  assert.equal(outLines.length, lines.length);
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === "" || /^\s*(```|~~~)/.test(lines[i])) assert.equal(outLines[i], lines[i]);
  }
});

test("thermal mode marks only recent activity within the window", () => {
  const now = 1_000_000_000_000;
  const recent = transformForVisor("thermal", SAMPLE, { now, recentAt: () => now - 10_000 });
  assert.equal(stripPrefix(recent, "▌ "), SAMPLE);
  const stale = transformForVisor("thermal", SAMPLE, { now, recentAt: () => now - THERMAL_WINDOW_MS - 1 });
  assert.equal(stale, SAMPLE);
  const unknown = transformForVisor("thermal", SAMPLE, { now, recentAt: () => undefined });
  assert.equal(unknown, SAMPLE);
  const streaming = transformForVisor("thermal", SAMPLE, { now, isStreaming: true, recentAt: () => undefined });
  assert.equal(stripPrefix(streaming, "▌ "), SAMPLE);
});

test("xray mode strips emphasis while preserving every word", () => {
  const out = transformForVisor("xray", SAMPLE);
  assert.equal(normalizeEmphasis(out), normalizeEmphasis(SAMPLE));
  assert.match(out, /parser/);
  assert.match(out, /```bash/);
  assert.match(out, /echo \*\*not bolded\*\*/);
  assert.equal(transformForVisor("xray", SAMPLE), out);
});

test("xray mode never drops non-emphasis content", () => {
  assert.equal(transformForVisor("xray", "2**10 and 3**5"), "2**10 and 3**5");
  assert.equal(transformForVisor("xray", "`a**b` and `c**d`"), "`a**b` and `c**d`");
  assert.equal(transformForVisor("xray", "C:\\path\\*\\*"), "C:\\path\\*\\*");
  assert.equal(transformForVisor("xray", "```sh\nglob **/*.ts\n```"), "```sh\nglob **/*.ts\n```");
  assert.equal(transformForVisor("xray", "**bold** and ***strong*** and __under__"), "bold and strong and under");
  assert.equal(transformForVisor("xray", "foo *bar* baz"), "foo bar baz");
});

test("visor mode parsing and cycling are total", () => {
  assert.equal(parseVisorMode("scan"), "scan");
  assert.equal(parseVisorMode(" X-Ray "), "xray");
  assert.equal(parseVisorMode("bogus"), null);
  assert.equal(parseVisorMode(""), null);
  const cycle: VisorMode[] = [nextVisorMode("combat"), nextVisorMode("scan"), nextVisorMode("thermal"), nextVisorMode("xray")];
  assert.deepEqual(cycle, ["scan", "thermal", "xray", "combat"]);
});

test("visor switching changes rendering per mode", () => {
  const modes: VisorMode[] = ["combat", "scan", "thermal", "xray"];
  const outputs = new Set(modes.map((mode) => transformForVisor(mode, SAMPLE, { now: 0, recentAt: () => 0 })));
  assert.equal(outputs.size, 4);
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
  assert.match(lines, /VISOR:COMBAT/);
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

test("text hashing is stable for recency bookkeeping", () => {
  assert.equal(hashText("abc"), hashText("abc"));
  assert.notEqual(hashText("abc"), hashText("abd"));
});

// Registration and lifecycle wiring, driven through a mock extension API: the factory must
// register only the namespaced HUD surface, and every handler must stay cheap and total.

interface Harness {
  statuses: Map<string, string | undefined>;
  handlers: Map<string, (event: Record<string, unknown>, ctx: MockCtx) => unknown>;
  commands: Map<string, { handler: (args: string, ctx: MockCtx) => Promise<void> }>;
  shortcuts: Map<string, { handler: (ctx: MockCtx) => void }>;
  transformer: ((markdown: string, context: { messageType: string; isStreaming: boolean; availableWidth: number }) => string) | undefined;
  widgetKey: string | undefined;
  widgetFactory: ((tui: unknown, theme: unknown) => { render(width: number): string[] }) | undefined;
  toolRegistrationAttempts: string[];
}

interface MockCtx {
  mode: string;
  hasUI: boolean;
  model: { provider: string; id: string } | undefined;
  getContextUsage: () => { tokens: number | null; contextWindow: number; percent: number | null } | undefined;
  sessionManager: { getBranch: () => unknown[] };
  ui: {
    setStatus: (key: string, text: string | undefined) => void;
    setWidget: (key: string, content: unknown) => void;
    notify: (message: string, type?: string) => void;
  };
}

function harness(): Harness {
  const captured: Harness = {
    statuses: new Map(),
    handlers: new Map(),
    commands: new Map(),
    shortcuts: new Map(),
    transformer: undefined,
    widgetKey: undefined,
    widgetFactory: undefined,
    toolRegistrationAttempts: [],
  };
  const pi = {
    on(event: string, handler: (event: Record<string, unknown>, ctx: MockCtx) => unknown) {
      captured.handlers.set(event, handler);
    },
    registerCommand(name: string, options: { handler: (args: string, ctx: MockCtx) => Promise<void> }) {
      captured.commands.set(name, options);
    },
    registerShortcut(id: string, options: { handler: (ctx: MockCtx) => void }) {
      captured.shortcuts.set(id, options);
    },
    registerMarkdownTransformer(fn: Harness["transformer"]) {
      captured.transformer = fn ?? undefined;
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
    hasUI: true,
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
      notify: () => {},
    },
  };
}

const mockTheme = {
  appearance: "dark",
  colors: { dim: { kind: "indexed", index: 8 } },
  style: (text: string) => text,
};

test("factory registers no tools and only namespaced keys", () => {
  const captured = harness();
  assert.deepEqual(captured.toolRegistrationAttempts, []);
  assert.ok(captured.transformer);
  const start = captured.handlers.get("session_start");
  assert.ok(start);
  const ctx = ctxMock(undefined, captured);
  start({ type: "session_start" }, ctx);
  assert.ok(captured.widgetKey?.startsWith("fm-prime-hud-"));
  for (const key of captured.statuses.keys()) assert.ok(key.startsWith("fm-prime-hud-"), key);
  assert.ok(captured.commands.has("visor"));
  assert.ok(captured.shortcuts.has("alt+v"));
});

test("session lifecycle: start paints, shutdown clears", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  assert.equal(captured.statuses.get("fm-prime-hud-energy"), "NRG ?");
  assert.match(captured.statuses.get("fm-prime-hud-visor") ?? "", /VSR COMBAT BEAM \?/);
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

test("visor command and transformer drive mode switching", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  const transform = captured.transformer;
  assert.ok(transform);
  const md = "hello **world**";
  const context = { messageType: "user", isStreaming: false, availableWidth: 80 };
  assert.equal(transform(md, context), md);
  void captured.commands.get("visor")?.handler("scan", ctx);
  assert.equal(transform(md, context), "┃ hello **world**");
  void captured.commands.get("visor")?.handler("bogus", ctx);
  assert.equal(transform(md, context), "┃ hello **world**");
  assert.match(captured.statuses.get("fm-prime-hud-visor") ?? "", /VSR SCAN/);
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
  ctx.model = { provider: "openai", id: "gpt-5.2" };
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

test("thermal recency keys each rendered assistant block", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  void captured.commands.get("visor")?.handler("thermal", ctx);
  captured.handlers.get("message_end")?.({
    type: "message_end",
    message: {
      role: "assistant",
      content: [
        { type: "text", text: "Before tool\n" },
        { type: "toolCall", id: "t1", name: "bash", input: { command: "ls" } },
        { type: "text", text: " After tool" },
        { type: "thinking", thinking: " thinking one " },
        { type: "thinking", thinking: "thinking two" },
      ],
    },
  }, ctx);
  const transform = captured.transformer;
  assert.ok(transform);
  const context = { messageType: "assistant", isStreaming: false, availableWidth: 80 };
  assert.equal(transform("Before tool", context), "▌ Before tool");
  assert.equal(transform("After tool", context), "▌ After tool");
  assert.equal(transform("thinking one\n\nthinking two", context), "▌ thinking one\n\n▌ thinking two");
  assert.equal(transform("Unrecorded row", context), "Unrecorded row");
});

test("thermal recency keys the user message of a skill block", () => {
  const captured = harness();
  const ctx = ctxMock(undefined, captured);
  captured.handlers.get("session_start")?.({ type: "session_start" }, ctx);
  void captured.commands.get("visor")?.handler("thermal", ctx);
  const skill = '<skill name="x" location="/tmp/x">\nbody text\n</skill>\n\nactual question';
  captured.handlers.get("message_start")?.({ type: "message_start", message: { role: "user", content: skill } }, ctx);
  const transform = captured.transformer;
  assert.ok(transform);
  const context = { messageType: "user", isStreaming: false, availableWidth: 80 };
  assert.equal(transform("actual question", context), "▌ actual question");
  assert.equal(transform(skill, context), skill);
});
