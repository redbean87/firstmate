// fm-prime-hud: a Metroid Prime visor HUD for the Pi transcript, driven by live session data.
//
// Launch for isolated review with: pi --extension .pi/extensions/fm-prime-hud.ts
//
// Data honesty contract, fixed by the pre-implementation audit (data/fm-prime-hud-c1/report.md):
// - Energy meter and energy tanks come from ctx.getContextUsage(). Unknown usage renders as an
//   explicit "?", never as a fabricated percentage.
// - The missile reserve represents the provider usage budget (5-hour and 7-day windows). Pi
//   exposes no in-process source for it, so it always renders as unknown.
// - Beam selection is a documented thematic mapping over the real active model; the model id is
//   shown separately, and an unmapped model falls back to the Power beam.
// - The hazard exclamation tracks only real events: a matched destructive bash call in flight,
//   critical context (85 percent or more used), and a failed tool or compaction.
// - The mini-radar is decorative. It renders a fixed pattern and is labeled SIM so it can never
//   be mistaken for real fleet telemetry.
//
// Safety contract (audit section 6): the factory only registers; all state starts in
// session_start and cleans up idempotently in session_shutdown; updates ride lifecycle events
// with no timers or polling; no built-in tools, headers, footers, editors, or themes are
// claimed; every status and widget key is namespaced.

import type { Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { rgbColor, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

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

export interface HudLine {
  text: string;
  tone: "cyan" | "amber" | "dim";
}

// Missile reserve: the provider usage budget. No in-process source exists, so the readout is a
// fixed honest unknown rather than any fabricated or inferred number.
export function missileReadout(): HudLine {
  return { text: " MSL 5h:? 7d:?", tone: "amber" };
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

const COMMAND_START = String.raw`(?:^|[\n;&|])\s*(?:(?:sudo|doas)\s+)?`;

const DESTRUCTIVE_COMMAND_PATTERNS: readonly RegExp[] = [
  new RegExp(`${COMMAND_START}rm\\s+-\\w*[rf]\\w*`),
  new RegExp(`${COMMAND_START}git\\s+push\\s+.*(?:--force(?![\\w-])|-f\\b)`),
  new RegExp(`${COMMAND_START}git\\s+reset\\s+--hard\\b`),
  new RegExp(`${COMMAND_START}git\\s+clean\\s+-\\w*f`),
  new RegExp(`${COMMAND_START}git\\s+branch\\s+-D\\b`),
  new RegExp(`${COMMAND_START}git\\s+worktree\\s+remove\\b`),
  new RegExp(`${COMMAND_START}dd\\s+.*\\bof=`),
  new RegExp(`${COMMAND_START}mkfs`),
  new RegExp(`${COMMAND_START}truncate\\b`),
  new RegExp(`${COMMAND_START}(?:shutdown|reboot|halt)\\b`),
  /\bdrop\s+(database|table)\b/i,
];

const QUOTED_SPAN_PATTERN = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g;

// A deliberately small, documented heuristic list. Its only consequence is a hazard
// glyph: this extension never blocks the call it matches.
export function isDestructiveCommand(command: string): boolean {
  const unquoted = command.replace(QUOTED_SPAN_PATTERN, " ");
  return DESTRUCTIVE_COMMAND_PATTERNS.some((pattern) => pattern.test(unquoted));
}

export interface HudInput {
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
  const content: HudLine[] = [energyLine(remaining), tankLine(remaining), missileReadout(), beamLine(input, inner)];
  if (input.hazardLabel !== null) content.push({ text: ` !! ${input.hazardLabel}`, tone: "amber" });
  if (width >= LEGEND_MIN_WIDTH) {
    content.push({ text: " NRG/TANK=CONTEXT LEFT  MSL=NO SOURCE  RADAR=SIM", tone: "dim" });
  }
  const lines: HudLine[] = [{ text: borderLine(" VISOR ", width), tone: "cyan" }];
  for (const row of content) lines.push(frameRow(row, inner));
  if (width >= RADAR_MIN_WIDTH) {
    for (const row of radarLines()) lines.push(frameRow(row, inner));
  }
  lines.push({ text: `+${"-".repeat(Math.max(0, inner))}+`, tone: "cyan" });
  return lines.map((line) => ({ text: truncateToWidth(line.text, width), tone: line.tone }));
}

const WIDGET_KEY = "fm-prime-hud-widget";
const STATUS_ENERGY = "fm-prime-hud-energy";
const STATUS_VISOR = "fm-prime-hud-visor";
const STATUS_HAZARD = "fm-prime-hud-hazard";

interface HudRuntimeState {
  percent: number | null;
  model: string | null;
  beam: string | null;
  hazard: HazardState;
  hazardLabel: string | null;
  destructiveCalls: Set<string>;
  widgetTui: { requestRender(): void } | undefined;
}

function freshState(): HudRuntimeState {
  return {
    percent: null,
    model: null,
    beam: null,
    hazard: { destructivePending: false, contextCritical: false, failureActive: false },
    hazardLabel: null,
    destructiveCalls: new Set(),
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

function hudInputOf(state: HudRuntimeState): HudInput {
  return {
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
    ctx.ui.setStatus(STATUS_VISOR, `VSR BEAM ${(state.beam ?? "?").toUpperCase()}`);
    ctx.ui.setStatus(STATUS_HAZARD, state.hazardLabel === null ? undefined : `!! ${state.hazardLabel}`);
    state.widgetTui?.requestRender();
  };

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

  pi.on("message_end", (_event, ctx) => paint(ctx));
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
}
