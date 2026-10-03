// Firstmate's explicitly-selected ChatGPT Web provider for Pi workers.
//
// Registers the `chatgpt-web` provider against the local codex-chatgpt-web
// bridge (openai-responses, loopback only) and stamps every bridge turn with
// the native Codex turn identity the bridge requires. The bridge carries its
// own ChatGPT browser session, so this extension holds no credentials and
// copies no session or browser state; Pi keeps executing all local tools and
// ChatGPT Web supplies inference only.
//
// Selection is explicit and per launch: bin/fm-spawn.sh loads this file with
// an extra `-e` only when the task names `--model chatgpt-web/<id>`, and
// bin/fm-pi-chatgpt-web-lib.sh owns that provider-to-extension mapping.
// Without that `-e` the provider is unknown to Pi, so ambient launches and
// the default routing are unchanged. The registered model id is the bare
// `gpt-5.6-luna`; the `chatgpt-web/` prefix in `--model` names the provider,
// never part of the id. bin/fm-pi-chatgpt-web-lib.sh also owns the endpoint,
// model id, and account-allowlist contract; this file only consumes them.
//
// Verified against the bridge behavior documented in
// ~/tools/codex-chatgpt-web/pi-test/extensions/codex-bridge-turn-metadata.ts:
// the bridge requires body.client_metadata["x-codex-turn-metadata"] and
// stable Codex item ids on every browser-backed Responses turn, which Pi's
// vanilla openai-responses payload does not send.
import { createHash, randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const CHATGPT_WEB_PROVIDER = "chatgpt-web";
export const CHATGPT_WEB_MODEL_ID = "gpt-5.6-luna";
export const CHATGPT_WEB_DEFAULT_BASE_URL = "http://127.0.0.1:17841/v1";

function bridgeBaseUrl(): string {
  const override = (process.env["CHATGPT_WEB_BRIDGE_URL"] ?? "").trim();
  return override === "" ? CHATGPT_WEB_DEFAULT_BASE_URL : override;
}

function bridgeModelSlug(model: unknown): string | null {
  if (typeof model === "string" && model.startsWith(`${CHATGPT_WEB_PROVIDER}/`)) {
    return model;
  }
  if (model === CHATGPT_WEB_MODEL_ID) {
    return `${CHATGPT_WEB_PROVIDER}/${CHATGPT_WEB_MODEL_ID}`;
  }
  return null;
}

function stableId(prefix: string, parts: unknown[]): string {
  const hash = createHash("sha256").update(JSON.stringify(parts)).digest("hex");
  return `${prefix}_${hash.slice(0, 32)}`;
}

// Pi sends the bare registered id on the wire, but the bridge routes on the
// qualified slug: a bare id falls into native Codex passthrough and fails
// against the dummy loopback key. Normalize to the slug first so identical
// retries still map to the same bridge turn.
const THREAD_ID = randomUUID().replace(/-/g, "");

interface TurnInputItem {
  type?: string;
  role?: string;
  id?: string;
  content?: unknown;
}

function stampTurnMetadata(body: Record<string, unknown>): Record<string, unknown> {
  const slug = bridgeModelSlug(body["model"]);
  if (slug === null) {
    return body;
  }
  body["model"] = slug;
  const turnId = stableId("turn", [body["model"], body["input"], body["instructions"]]);
  const clientMetadata =
    body["client_metadata"] && typeof body["client_metadata"] === "object"
      ? { ...(body["client_metadata"] as Record<string, unknown>) }
      : {};
  clientMetadata["x-codex-turn-metadata"] = JSON.stringify({
    thread_id: THREAD_ID,
    turn_id: turnId,
    cwd: process.cwd(),
    workspace_roots: [process.cwd()],
    sandbox: "dangerFullAccess",
  });
  body["client_metadata"] = clientMetadata;
  if (Array.isArray(body["input"])) {
    body["input"] = (body["input"] as TurnInputItem[]).map((item, index) => {
      if (!item || typeof item !== "object") {
        return item;
      }
      let next = item;
      if (next.type === undefined && typeof next.role === "string") {
        next = { ...next, type: "message" };
      }
      if (next.type === "message" && typeof (next as { id?: unknown }).id !== "string") {
        next = { ...next, id: stableId("msg", [index, next.role, next.content]) };
      }
      return next;
    });
  }
  return body;
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider(CHATGPT_WEB_PROVIDER, {
    baseUrl: bridgeBaseUrl(),
    apiKey: "local-bridge-loopback",
    api: "openai-responses",
    models: [
      {
        id: CHATGPT_WEB_MODEL_ID,
        name: "GPT-5.6 Luna (ChatGPT Web)",
        input: ["text", "image"],
        reasoning: false,
        contextWindow: 1050000,
        maxTokens: 100000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });
  pi.on("before_provider_request", event => {
    const payload = event.payload;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return payload;
    }
    return stampTurnMetadata(payload as Record<string, unknown>);
  });
}
