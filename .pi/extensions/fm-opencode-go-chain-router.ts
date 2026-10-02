// Firstmate Stage 2 Pi fallback chain for normal workers.
//
// Registers the virtual model opencode-go/fm-fallback-chain: an ordered
// three-model chain (muse-spark-1.3-contributor, then mimo-v2.6-flash, then
// deepseek-v4.1-flash) that advances only on the retry path with a retryable
// provider failure, keeps thinking low on every hop, and ends after the third
// model with a surfaced error. There is no fourth model and no fallback to
// another provider or harness. Dispatch names this virtual id like any
// physical id; the live default still names the primary physical id until the
// captain approves the switch, so loading this extension changes nothing until
// dispatch points at it. Expo-bowling-journal stays on qwen-local untouched.
//
// Failure classification (stated once here): quota exhaustion, rate limiting,
// and transient provider failures are retryable; context overflow,
// content-filter refusal, cancellation or abort, and ordinary task or
// application errors are terminal. Classification is content-based over the
// failed assistant message's stopReason and errorMessage, terminal patterns
// win over retryable ones, and anything unrecognized is terminal, so a
// non-retryable failure can never advance the chain. Attempt position rides
// router state on the session branch and only moves forward.
//
// Wiring owner: bin/fm-spawn.sh loads this tracked file as a second -e next to
// the per-task Pi extension. Usage: pi -e .pi/extensions/fm-opencode-go-chain-router.ts --model opencode-go/fm-fallback-chain --thinking low

import type {
  ExtensionAPI,
  ExtensionContext,
  ModelRoute,
  ModelRouteRequest,
} from "@earendil-works/pi-coding-agent";

// Virtual model identity dispatch names. The id must stay distinct from every
// physical model id on the opencode-go provider.
export const FM_CHAIN_PROVIDER = "opencode-go";
export const FM_CHAIN_VIRTUAL_ID = "fm-fallback-chain";
// Thinking level attached to every routed model on every hop.
export const FM_CHAIN_THINKING = "low";
// Ordered chain. The chain ends at the last entry: no fourth model follows it.
export const FM_CHAIN_MODELS = [
  "muse-spark-1.3-contributor",
  "mimo-v2.6-flash",
  "deepseek-v4.1-flash",
] as const;

export interface ChainState {
  attempt: number;
}

export type ChainRequest = ModelRouteRequest<ChainState>;

export type FailureVerdict = "retryable" | "terminal";

// Terminal first: a failure matching any of these never advances the chain,
// even when its text also matches a retryable pattern.
const TERMINAL_PATTERNS = [
  /context (window|length|overflow)|context_length|max(imum)? context|prompt (is )?too (long|large)|input (is )?too (long|large)|too many tokens|tokens? (exceed|exceeds|exceeded)|exceeds? (the |its |their )?(context|token|input|prompt|maximum)/i,
  /content.?filter|moderation|safety (block|filter|refusal|violation)|blocked by|policy (violation|refusal)|disallowed|inappropriate|harmful content|(?<!connection |connect |econn)refus(e|ed|al)/i,
  /\babort(ed|ing)?\b|cancell?ed|cancellation|AbortError|interrupted by user|stopped by user/i,
];

// Retryable only when no terminal pattern matched: quota exhaustion, rate
// limiting, and transient provider failures, including transport-level
// connection, socket, DNS, reset, refused, and unreachable failures.
const RETRYABLE_PATTERNS = [
  /quota|exhaust(ed|ion)?|usage.?limit|out of (credits?|quota)|insufficient (credits?|quota|balance|funds?)|credit (exhausted|expired|limit)|billing|payment required/i,
  /rate.?limit|too many requests|\b429\b|throttl/i,
  /overload|temporar|transient|unavailable|server_?error|upstream|timed? ?out|network|econn|socket hang|eai_again|service unavailable|bad gateway|gateway (timeout|error)|internal (server )?error|try again|5\d\d/i,
  /connection error|connection (refused|reset|failed|closed|timed? ?out)|connect ECONN|ECONN(REFUSED|RESET|ABORTED)|socket (closed|ended|destroyed|reset|refused)|EPIPE|ENOTFOUND|getaddrinfo|EHOST(UNREACH|DOWN)?|ENET(UNREACH|DOWN|RESET)?|DNS|host (unreachable|not found|unknown)|no route to host|destination unreachable|network (down|failure|reset)|transport (error|failure|closed|reset)|fetch failed|connection failure/i,
];

export function classifyRouterFailure(stopReason: string, errorMessage: string): FailureVerdict {
  const text = `${stopReason ?? ""}\n${errorMessage ?? ""}`;
  if (TERMINAL_PATTERNS.some((pattern) => pattern.test(text))) return "terminal";
  if (RETRYABLE_PATTERNS.some((pattern) => pattern.test(text))) return "retryable";
  return "terminal";
}

function lookupChainModel(ctx: ExtensionContext, index: number) {
  const id = FM_CHAIN_MODELS[index];
  const model = ctx.modelRegistry.find(FM_CHAIN_PROVIDER, id);
  if (!model) throw new Error(`[fm-fallback-chain] model ${FM_CHAIN_PROVIDER}/${id} is not in the catalog`);
  return model;
}

function routeTo(ctx: ExtensionContext, index: number, state: ChainState): ModelRoute<ChainState> {
  return { model: lookupChainModel(ctx, index), thinkingLevel: FM_CHAIN_THINKING, state };
}

export default function (pi: ExtensionAPI) {
  pi.registerVirtualModel<ChainState>({
    provider: FM_CHAIN_PROVIDER,
    id: FM_CHAIN_VIRTUAL_ID,
    name: "Fallback chain (Firstmate)",
    thinkingLevels: [FM_CHAIN_THINKING],
    route(request: ChainRequest, ctx: ExtensionContext) {
      const state: ChainState = request.state ?? { attempt: 0 };
      if (request.reason === "retry") {
        const failed = request.failed;
        if (!failed) {
          // Pi leaves failed absent when routing itself failed
          // (docs/virtual-models.md: "Absent when routing itself failed"), so
          // there is no provider failure to classify and no evidence to advance
          // on: hold the current attempt's model for one more dispatch. A
          // successful route ends routing, so this cannot loop; the next genuine
          // provider failure arrives with detail and classifies normally.
          const index = Math.min(state.attempt, FM_CHAIN_MODELS.length - 1);
          return routeTo(ctx, index, { attempt: index });
        }
        const message = failed.message as { stopReason?: string; errorMessage?: string } | undefined;
        const stopReason = message?.stopReason ?? "";
        const errorMessage = message?.errorMessage ?? "";
        if (classifyRouterFailure(stopReason, errorMessage) === "terminal") {
          const failedId = (failed.model as { id?: string } | undefined)?.id ?? FM_CHAIN_MODELS[state.attempt] ?? "unknown";
          throw new Error(`[fm-fallback-chain] terminal failure on ${failedId}; the chain does not advance: ${errorMessage || stopReason || "no error detail"}`);
        }
        const next = state.attempt + 1;
        if (next >= FM_CHAIN_MODELS.length) {
          throw new Error(`[fm-fallback-chain] chain exhausted after ${FM_CHAIN_MODELS[FM_CHAIN_MODELS.length - 1]}; the last error stands: ${errorMessage || stopReason || "no error detail"}`);
        }
        return routeTo(ctx, next, { attempt: next });
      }
      // Tool follow-ups stay on the model that handled the turn, keeping the
      // prompt cache valid; thinking stays low either way.
      if (request.reason === "continuation" && request.previous) {
        return { model: request.previous.model, thinkingLevel: FM_CHAIN_THINKING, state };
      }
      const index = Math.min(state.attempt, FM_CHAIN_MODELS.length - 1);
      return routeTo(ctx, index, { attempt: index });
    },
  });
}
