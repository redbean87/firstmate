// fm-prime-hud: a Metroid Prime visor HUD for the Pi transcript, driven by live session data.
//
// Launch for isolated review with: pi --extension .pi/extensions/fm-prime-hud.ts
//
// Data honesty contract, fixed by the pre-implementation audit (data/fm-prime-hud-c1/report.md):
// - Energy meter and energy tanks come from ctx.getContextUsage(). Unknown usage renders as an
//   explicit "?", never as a fabricated percentage.
// - The missile reserve represents the provider usage budget (5-hour and 7-day windows). Pi
//   exposes no in-process source for it, so it always renders as unknown until one exists.
// - Beam selection is a documented thematic mapping over the real active model; the model id is
//   shown separately, and an unmapped model falls back to the Power beam.
// - The hazard exclamation tracks only real events: a matched destructive bash call in flight,
//   critical context (85 percent or more used), and a failed tool or compaction.
// - The mini-radar is decorative. It renders a fixed pattern and is labeled SIM so it can never
//   be mistaken for real fleet telemetry.
//
// Visor modes change how user and assistant Markdown renders: Combat is a byte-identical no-op,
// Scan prefixes content lines with a grid rule, Thermal marks activity from the last 60 seconds,
// and X-Ray strips emphasis for a monochrome look. Tool rows, diffs, and custom entries are
// outside the Markdown transformer's reach and keep stock rendering in every mode.
//
// Safety contract (audit section 6): the factory only registers; all state starts in
// session_start and cleans up idempotently in session_shutdown; updates ride lifecycle events
// with no timers or polling; the transformer never blanks or drops content; no built-in tools,
// headers, footers, editors, or themes are claimed; every status and widget key is namespaced.

import type { Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, MarkdownTransformContext } from "@earendil-works/pi-coding-agent";
import { rgbColor, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export type VisorMode = "combat" | "scan" | "thermal" | "xray";

export const VISOR_MODES: readonly VisorMode[] = ["combat", "scan", "thermal", "xray"];

export function parseVisorMode(arg: string): VisorMode | null {
  const normalized = arg.trim().toLowerCase().replace(/-/g, "");
  for (const mode of VISOR_MODES) {
    if (mode === normalized) return mode;
  }
  return null;
}

export function nextVisorMode(mode: VisorMode): VisorMode {
  const index = VISOR_MODES.indexOf(mode);
  return VISOR_MODES[(index + 1) % VISOR_MODES.length] ?? "combat";
}

// Beam mapping: a documented, deterministic table over provider and model-id patterns.
// Unmapped models are the Power beam by design; a missing model renders as unknown instead.
export type BeamName = "power" | "wave" | "ice" | "plasma";

export function beamForModel(model: Pick<Model<any>, "provider" | "id"> | undefined): BeamName | null {
  if (!model) return null;
  const provider = String(model.provider ?? "").toLowerCase();
  const id = String(model.id ?? "").toLowerCase();
  if (provider === "anthropic" || id.startsWith("claude")) return "plasma";
  if (provider === "google" || id.startsWith("gemini")) return "wave";
  if (provider === "ollama" || provider === "llamacpp" || id.startsWith("llama")) return "ice";
  return "power";
}

// Missile reserve: the provider usage budget. No in-process source exists, so the
// production wiring always passes null and the readout renders honest unknowns.
export interface MissileSource {
  fiveHourPercent: number | null;
  sevenDayPercent: number | null;
}

export interface HudLine {
  text: string;
  tone: "cyan" | "amber" | "dim";
}

export function missileReadout(source: MissileSource | null): HudLine {
  if (!source) return { text: " MSL 5h:? 7d:?", tone: "amber" };
  const fiveHour = source.fiveHourPercent === null ? "?" : `${Math.round(source.fiveHourPercent)}%`;
  const sevenDay = source.sevenDayPercent === null ? "?" : `${Math.round(source.sevenDayPercent)}%`;
  const unknown = source.fiveHourPercent === null && source.sevenDayPercent === null;
  return { text: ` MSL 5h:${fiveHour} 7d:${sevenDay}`, tone: unknown ? "amber" : "cyan" };
}

// Energy tanks: a presentation of the same context-usage number, one tank per 20 points
// of remaining context. The widget legend states the mapping so tanks never imply an
// independently measured reserve.
export function tanksFilled(remainingPercent: number | null): number | null {
  if (remainingPercent === null || Number.isNaN(remainingPercent)) return null;
  const clamped = Math.min(100, Math.max(0, remainingPercent));
  if (clamped <= 0) return 0;
  return Math.min(5, Math.ceil(clamped / 20));
}

export function contextCritical(percent: number | null): boolean {
  return percent !== null && !Number.isNaN(percent) && percent >= 85;
}

export interface HazardState {
  destructivePending: boolean;
  contextCritical: boolean;
  failureActive: boolean;
}

export type HazardKind = "destructive" | "context" | "failure" | "none";

export function evaluateHazard(state: HazardState): { kind: HazardKind; label: string | null } {
  if (state.destructivePending) return { kind: "destructive", label: "DESTRUCTIVE COMMAND PENDING" };
  if (state.contextCritical) return { kind: "context", label: "CONTEXT CRITICAL" };
  if (state.failureActive) return { kind: "failure", label: "LAST OPERATION FAILED" };
  return { kind: "none", label: null };
}

const DESTRUCTIVE_COMMAND_PATTERNS: readonly RegExp[] = [
  /\brm\s+-\w*[rf]\w*/,
  /\bgit\s+push\s+.*(--force\b|-f\b)/,
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\s+-\w*f/,
  /\bgit\s+branch\s+-D\b/,
  /\bgit\s+worktree\s+remove\b/,
  /\bdd\b.*\bof=/,
  /\bmkfs/,
  /\btruncate\b/,
  /\b(shutdown|reboot|halt)\b/,
  /\bdrop\s+(database|table)\b/i,
];

// A deliberately small, documented heuristic list. Its only consequence is a hazard
// glyph: this extension never blocks the call it matches.
export function isDestructiveCommand(command: string): boolean {
  return DESTRUCTIVE_COMMAND_PATTERNS.some((pattern) => pattern.test(command));
}

export interface HudInput {
  visor: VisorMode;
  percent: number | null;
  model: string | null;
  beam: string | null;
  hazardLabel: string | null;
}

const BAR_CELLS = 12;
const LEGEND_MIN_WIDTH = 56;
const RADAR_MIN_WIDTH = 64;

function remainingFromPercent(percent: number | null): number | null {
  if (percent === null || Number.isNaN(percent)) return null;
  return Math.min(100, Math.max(0, 100 - percent));
}

function energyLine(remaining: number | null): HudLine {
  if (remaining === null) {
    return { text: ` NRG [${"?".repeat(BAR_CELLS)}] ?`, tone: "amber" };
  }
  const filled = Math.round((remaining / 100) * BAR_CELLS);
  const bar = "=".repeat(filled) + "-".repeat(BAR_CELLS - filled);
  return { text: ` NRG [${bar}] ${Math.round(remaining)}%`, tone: "cyan" };
}

function tankLine(remaining: number | null): HudLine {
  if (remaining === null) return { text: " TANK [?????]", tone: "amber" };
  const filled = tanksFilled(remaining) ?? 0;
  return { text: ` TANK [${"#".repeat(filled)}${"-".repeat(5 - filled)}]`, tone: "cyan" };
}

function beamLine(input: HudInput, inner: number): HudLine {
  const beam = input.beam === null ? "?" : input.beam.toUpperCase();
  return { text: ` BEAM ${beam}  MDL ${input.model ?? "?"}`, tone: "cyan" };
}

// Fixed decorative pattern. It never reacts to any data source and carries the SIM
// label on every width that shows it, so it cannot read as real fleet activity.
function radarLines(): HudLine[] {
  const pattern = [" RADAR SIM", " | *   .  |", " |  . *   |", " +--------+"];
  return pattern.map((text) => ({ text, tone: "dim" as const }));
}

function borderLine(label: string, width: number): string {
  const inner = width - 2;
  const decorated = `${label}`;
  const fill = inner - visibleWidth(decorated);
  if (fill < 1) return truncateToWidth(`+${"-".repeat(Math.max(0, inner))}+`, width);
  const left = Math.floor(fill / 2);
  const right = fill - left;
  return `+${"-".repeat(left)}${decorated}${"-".repeat(right)}+`;
}

function frameRow(row: HudLine, inner: number): HudLine {
  const body = truncateToWidth(row.text, inner);
  const pad = " ".repeat(Math.max(0, inner - visibleWidth(body)));
  return { text: `|${body}${pad}|`, tone: row.tone };
}

export function renderHudLines(input: HudInput, width: number): HudLine[] {
  if (!Number.isFinite(width) || width < 4) return [];
  const inner = Math.max(1, width - 2);
  const remaining = remainingFromPercent(input.percent);
  const content: HudLine[] = [
    energyLine(remaining),
    tankLine(remaining),
    missileReadout(null),
    beamLine(input, inner),
  ];
  if (input.hazardLabel !== null) content.push({ text: ` !! ${input.hazardLabel}`, tone: "amber" });
  if (width >= LEGEND_MIN_WIDTH) {
    content.push({ text: " NRG/TANK=CONTEXT LEFT  MSL=NO SOURCE  RADAR=SIM", tone: "dim" });
  }
  const lines: HudLine[] = [{ text: borderLine(` VISOR:${input.visor.toUpperCase()} `, width), tone: "cyan" }];
  for (const row of content) lines.push(frameRow(row, inner));
  if (width >= RADAR_MIN_WIDTH) {
    for (const row of radarLines()) lines.push(frameRow(row, inner));
  }
  lines.push({ text: `+${"-".repeat(Math.max(0, inner))}+`, tone: "cyan" });
  return lines.map((line) => ({ text: truncateToWidth(line.text, width), tone: line.tone }));
}

// Visor transformations. Pure, synchronous, content-preserving: Combat returns its
// input unchanged, and every other mode only adds prefixes or removes emphasis markers.
export const THERMAL_WINDOW_MS = 60_000;

const SCAN_PREFIX = "┃ ";
const THERMAL_PREFIX = "▌ ";

function prefixContentLines(markdown: string, prefix: string): string {
  let inFence = false;
  return markdown
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence || line === "") return line;
      return prefix + line;
    })
    .join("\n");
}

const ANSI_PATTERN = /\x1b\[[0-9;]*m/g;
const FENCE_PATTERN = /^\s*(```|~~~)/;

function maskInlineCode(line: string): { masked: string; restore: (value: string) => string } {
  const stash: string[] = [];
  const masked = line.replace(/(`+)([\s\S]*?)\1/g, (match) => {
    const token = `\u0001${stash.length}\u0001`;
    stash.push(match);
    return token;
  });
  return {
    masked,
    restore: (value) => value.replace(/\u0001(\d+)\u0001/g, (_match, index: string) => stash[Number(index)] ?? ""),
  };
}

function maskEscapedDelimiters(line: string): { masked: string; restore: (value: string) => string } {
  const stash: string[] = [];
  const masked = line.replace(/(\\+)([*_])/g, (match, backslashes: string) => {
    if (backslashes.length % 2 === 0) return match;
    const token = `\u0002${stash.length}\u0002`;
    stash.push(match);
    return token;
  });
  return {
    masked,
    restore: (value) => value.replace(/\u0002(\d+)\u0002/g, (_match, index: string) => stash[Number(index)] ?? ""),
  };
}

function stripEmphasisDelimiters(text: string): string {
  let out = text;
  out = out.replace(/(^|[^\w*])\*\*\*(?=\S)([^*]*?\S)\*\*\*(?=$|[^\w*])/g, "$1$2");
  out = out.replace(/(^|[^\w*])\*\*(?=\S)([^*]*?\S)\*\*(?=$|[^\w*])/g, "$1$2");
  out = out.replace(/(^|[^\w_])__(?=\S)([^_]*?\S)__(?=$|[^\w_])/g, "$1$2");
  out = out.replace(/(^|[^*\w])\*(?=\S)([^*\n]*?\S)\*(?=$|[^*\w])/g, "$1$2");
  return out;
}

function stripEmphasis(markdown: string): string {
  let inFence = false;
  return markdown
    .replace(ANSI_PATTERN, "")
    .split("\n")
    .map((line) => {
      if (FENCE_PATTERN.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) return line;
      const code = maskInlineCode(line);
      const escaped = maskEscapedDelimiters(code.masked);
      const stripped = stripEmphasisDelimiters(escaped.masked);
      return code.restore(escaped.restore(stripped));
    })
    .join("\n");
}

export interface VisorTransformOptions {
  isStreaming?: boolean;
  now?: number;
  recentAt?: (markdown: string) => number | undefined;
}

export function transformForVisor(
  mode: VisorMode,
  markdown: string,
  options: VisorTransformOptions = {},
): string {
  if (mode === "combat") return markdown;
  if (mode === "scan") return prefixContentLines(markdown, SCAN_PREFIX);
  if (mode === "thermal") {
    const now = options.now ?? Date.now();
    const at = options.isStreaming ? now : options.recentAt?.(markdown);
    if (at === undefined || now - at > THERMAL_WINDOW_MS) return markdown;
    return prefixContentLines(markdown, THERMAL_PREFIX);
  }
  return stripEmphasis(markdown);
}

export function hashText(text: string): number {
  let hash = 5381;
  for (let index = 0; index < text.length; index++) {
    hash = ((hash << 5) + hash + text.charCodeAt(index)) | 0;
  }
  return hash >>> 0;
}

const WIDGET_KEY = "fm-prime-hud-widget";
const STATUS_ENERGY = "fm-prime-hud-energy";
const STATUS_VISOR = "fm-prime-hud-visor";
const STATUS_HAZARD = "fm-prime-hud-hazard";
const RECENT_MESSAGE_CAP = 128;

interface HudRuntimeState {
  visor: VisorMode;
  percent: number | null;
  model: string | null;
  beam: string | null;
  hazard: HazardState;
  hazardLabel: string | null;
  destructiveCalls: Set<string>;
  recent: Map<number, number>;
  widgetTui: { requestRender(): void } | undefined;
}

function freshState(): HudRuntimeState {
  return {
    visor: "combat",
    percent: null,
    model: null,
    beam: null,
    hazard: { destructivePending: false, contextCritical: false, failureActive: false },
    hazardLabel: null,
    destructiveCalls: new Set(),
    recent: new Map(),
    widgetTui: undefined,
  };
}

function modelLabel(model: Model<any> | undefined): string | null {
  if (!model) return null;
  const provider = String(model.provider ?? "");
  const id = String(model.id ?? "");
  if (!provider && !id) return null;
  return provider && id ? `${provider}/${id}` : provider || id;
}

const SKILL_BLOCK_PATTERN = /^<skill name="[^"]+" location="[^"]+">\n[\s\S]*?\n<\/skill>(?:\n\n([\s\S]+))?$/;

function userRenderedText(content: string): string | null {
  if (content === "") return null;
  const skill = content.match(SKILL_BLOCK_PATTERN);
  if (skill) {
    const userMessage = skill[1]?.trim();
    return userMessage ? userMessage : null;
  }
  return content;
}

// Mirror the exact strings Pi's renderer hands to the Markdown transformer: assistant text and
// thinking blocks are trimmed (consecutive thinking blocks join with a blank line), and a user
// skill block renders only its trailing user message.
function renderedTexts(message: { role?: unknown; content?: unknown }): string[] {
  if (message.role !== "user" && message.role !== "assistant") return [];
  const content = message.content;
  if (typeof content === "string") {
    if (message.role !== "user") return [];
    const text = userRenderedText(content);
    return text === null ? [] : [text];
  }
  if (!Array.isArray(content)) return [];
  if (message.role === "user") {
    const joined = content
      .filter(
        (part): part is { type: "text"; text: string } =>
          typeof part === "object" &&
          part !== null &&
          (part as { type?: unknown }).type === "text" &&
          typeof (part as { text?: unknown }).text === "string",
      )
      .map((part) => part.text)
      .join("");
    const text = userRenderedText(joined);
    return text === null ? [] : [text];
  }
  const blocks: string[] = [];
  for (let index = 0; index < content.length; index++) {
    const part = content[index];
    if (typeof part !== "object" || part === null) continue;
    const record = part as { type?: unknown; text?: unknown; thinking?: unknown };
    if (record.type === "text" && typeof record.text === "string") {
      const text = record.text.trim();
      if (text) blocks.push(text);
      continue;
    }
    if (record.type !== "thinking") continue;
    const thinkingBlocks: string[] = [];
    for (; index < content.length; index++) {
      const thinkingPart = content[index];
      if (typeof thinkingPart !== "object" || thinkingPart === null) break;
      const thinkingRecord = thinkingPart as { type?: unknown; thinking?: unknown };
      if (thinkingRecord.type !== "thinking") break;
      if (typeof thinkingRecord.thinking === "string") {
        const thinking = thinkingRecord.thinking.trim();
        if (thinking) thinkingBlocks.push(thinking);
      }
    }
    index--;
    if (thinkingBlocks.length > 0) blocks.push(thinkingBlocks.join("\n\n"));
  }
  return blocks;
}

function rememberRecent(state: HudRuntimeState, text: string, at: number): void {
  const key = hashText(text);
  state.recent.delete(key);
  state.recent.set(key, at);
  while (state.recent.size > RECENT_MESSAGE_CAP) {
    const oldest = state.recent.keys().next();
    if (oldest.done) break;
    state.recent.delete(oldest.value);
  }
}

function lookupRecent(state: HudRuntimeState, markdown: string): number | undefined {
  return state.recent.get(hashText(markdown));
}

function hudInputOf(state: HudRuntimeState): HudInput {
  return {
    visor: state.visor,
    percent: state.percent,
    model: state.model,
    beam: state.beam,
    hazardLabel: state.hazardLabel,
  };
}

function energyStatusText(state: HudRuntimeState): string {
  if (state.percent === null) return "NRG ?";
  const remaining = remainingFromPercent(state.percent) ?? 0;
  return `NRG ${Math.round(remaining)}%`;
}

export default function (pi: ExtensionAPI) {
  let state = freshState();

  const refreshDerived = (ctx: ExtensionContext): void => {
    state.percent = ctx.getContextUsage()?.percent ?? null;
    state.model = modelLabel(ctx.model);
    state.beam = beamForModel(ctx.model);
    state.hazard.contextCritical = contextCritical(state.percent);
    state.hazardLabel = evaluateHazard(state.hazard).label;
  };

  const paint = (ctx: ExtensionContext): void => {
    refreshDerived(ctx);
    if (ctx.mode !== "tui") return;
    ctx.ui.setStatus(STATUS_ENERGY, energyStatusText(state));
    ctx.ui.setStatus(
      STATUS_VISOR,
      `VSR ${state.visor.toUpperCase()} BEAM ${(state.beam ?? "?").toUpperCase()}`,
    );
    ctx.ui.setStatus(STATUS_HAZARD, state.hazardLabel === null ? undefined : `!! ${state.hazardLabel}`);
    state.widgetTui?.requestRender();
  };

  pi.registerMarkdownTransformer((markdown, context: MarkdownTransformContext) =>
    transformForVisor(state.visor, markdown, {
      isStreaming: context.isStreaming,
      now: Date.now(),
      recentAt: (text) => lookupRecent(state, text),
    }),
  );

  pi.on("session_start", (_event, ctx) => {
    state = freshState();
    if (ctx.mode !== "tui") return;
    ctx.ui.setWidget(WIDGET_KEY, (tui, theme) => {
      state.widgetTui = tui;
      const palette =
        theme.appearance === "light"
          ? { cyan: rgbColor(0, 90, 102), amber: rgbColor(140, 80, 0) }
          : { cyan: rgbColor(0, 229, 255), amber: rgbColor(255, 179, 0) };
      const tones = { cyan: palette.cyan, amber: palette.amber, dim: theme.colors.dim };
      return {
        dispose() {
          if (state.widgetTui === tui) state.widgetTui = undefined;
        },
        invalidate() {},
        render(width: number): string[] {
          return renderHudLines(hudInputOf(state), width).map((line) =>
            theme.style(line.text, { fg: tones[line.tone] }),
          );
        },
      };
    });
    paint(ctx);
  });

  pi.on("message_start", (event) => {
    if (event.message.role !== "user") return;
    const at = Date.now();
    for (const text of renderedTexts(event.message)) rememberRecent(state, text, at);
  });

  pi.on("message_end", (event, ctx) => {
    const at = Date.now();
    for (const text of renderedTexts(event.message)) rememberRecent(state, text, at);
    paint(ctx);
  });

  pi.on("after_provider_response", (_event, ctx) => paint(ctx));
  pi.on("agent_end", (_event, ctx) => paint(ctx));

  pi.on("agent_settled", (_event, ctx) => {
    state.destructiveCalls.clear();
    state.hazard.destructivePending = false;
    paint(ctx);
  });

  pi.on("model_select", (_event, ctx) => paint(ctx));

  pi.on("tool_call", (event, ctx) => {
    if (event.toolName === "bash") {
      const command = String((event.input as { command?: unknown })?.command ?? "");
      if (command && isDestructiveCommand(command)) {
        state.destructiveCalls.add(event.toolCallId);
        state.hazard.destructivePending = true;
      }
    }
    paint(ctx);
  });

  pi.on("tool_result", (event, ctx) => {
    state.destructiveCalls.delete(event.toolCallId);
    if (state.destructiveCalls.size === 0) state.hazard.destructivePending = false;
    // Documented clearing rule: a later successful tool result clears a failure warning.
    state.hazard.failureActive = event.isError === true;
    paint(ctx);
  });

  pi.on("session_compact", (_event, ctx) => {
    state.hazard.failureActive = false;
    paint(ctx);
  });

  pi.on("session_compact_failed", (event, ctx) => {
    if (!event.aborted) state.hazard.failureActive = true;
    paint(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    state.widgetTui = undefined;
    if (ctx.mode === "tui") {
      ctx.ui.setWidget(WIDGET_KEY, undefined);
      ctx.ui.setStatus(STATUS_ENERGY, undefined);
      ctx.ui.setStatus(STATUS_VISOR, undefined);
      ctx.ui.setStatus(STATUS_HAZARD, undefined);
    }
    state = freshState();
  });

  pi.registerCommand("visor", {
    description: "Set the Metroid Prime visor mode: combat, scan, thermal, or xray.",
    handler: async (args, ctx) => {
      const requested = args.trim();
      if (requested === "") {
        if (ctx.hasUI) ctx.ui.notify("visor: combat | scan | thermal | xray", "info");
        return;
      }
      const mode = parseVisorMode(requested);
      if (!mode) {
        if (ctx.hasUI) ctx.ui.notify("visor: combat | scan | thermal | xray", "warning");
        return;
      }
      state.visor = mode;
      paint(ctx);
      if (ctx.hasUI) ctx.ui.notify(`Visor: ${mode}`, "info");
    },
  });

  pi.registerShortcut("alt+v", {
    description: "Cycle the Metroid Prime visor mode.",
    handler: (ctx) => {
      state.visor = nextVisorMode(state.visor);
      paint(ctx);
      if (ctx.hasUI) ctx.ui.notify(`Visor: ${state.visor}`, "info");
    },
  });
}
