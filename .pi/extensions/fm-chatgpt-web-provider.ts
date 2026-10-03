// Firstmate's explicitly-selected ChatGPT Web provider for Pi workers.
//
// Registers the `chatgpt-web` provider against the local codex-chatgpt-web
// bridge. The separately installed codex-bridge-turn-metadata extension
// supplies required native Codex turn identity. The bridge carries its own
// ChatGPT browser session; Pi keeps executing all local tools and ChatGPT Web
// supplies inference only.
//
// Selection is explicit and per launch: bin/fm-spawn.sh loads this file only
// when the task names `--model chatgpt-web/<id>`. The registered model id is
// the bare `gpt-5.6-luna`; the `chatgpt-web/` prefix names the provider.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const CHATGPT_WEB_PROVIDER = "chatgpt-web";
export const CHATGPT_WEB_MODEL_ID = "gpt-5.6-luna";
export const CHATGPT_WEB_DEFAULT_BASE_URL = "http://127.0.0.1:17841/v1";

function bridgeModelSlug(model: unknown): string | null {
  if (typeof model === "string" && model.startsWith(`${CHATGPT_WEB_PROVIDER}/`)) {
    return model;
  }
  if (model === CHATGPT_WEB_MODEL_ID) {
    return `${CHATGPT_WEB_PROVIDER}/${CHATGPT_WEB_MODEL_ID}`;
  }
  return null;
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider(CHATGPT_WEB_PROVIDER, {
    baseUrl: CHATGPT_WEB_DEFAULT_BASE_URL,
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
    const body = payload as Record<string, unknown>;
    const slug = bridgeModelSlug(body["model"]);
    if (slug !== null) body["model"] = slug;
    return body;
  });
}
