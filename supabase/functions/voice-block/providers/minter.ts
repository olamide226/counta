import { ProviderError, TokenMinter } from "../types.ts";
import { providerFetch } from "./http.ts";

const BASE_URL = "https://api.deepgram.com";

export interface DeepgramMinterOptions {
  /** Master API key. Read from Deno.env by the entrypoint; never logged. */
  apiKey: string;
  fetch?: typeof fetch;
}

/**
 * POST https://api.deepgram.com/v1/auth/grant
 * Body { ttl_seconds } -> { access_token, expires_in }
 * (https://developers.deepgram.com/reference/auth/tokens/grant)
 */
export class DeepgramTokenMinter implements TokenMinter {
  private readonly fetchFn: typeof fetch;

  constructor(private readonly opts: DeepgramMinterOptions) {
    this.fetchFn = opts.fetch ?? fetch;
  }

  async mint(ttlSeconds: number): Promise<string> {
    const response = await providerFetch(
      "deepgram",
      this.fetchFn,
      `${BASE_URL}/v1/auth/grant`,
      {
        method: "POST",
        headers: {
          Authorization: `Token ${this.opts.apiKey}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({ ttl_seconds: ttlSeconds }),
      },
    );

    const body = (await response.json()) as { access_token?: string };
    if (!body.access_token) {
      throw new ProviderError(
        "unavailable",
        "deepgram: grant returned no token",
      );
    }
    return body.access_token;
  }
}
