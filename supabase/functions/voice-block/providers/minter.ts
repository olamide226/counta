import { MintedToken, ProviderUnavailableError, TokenMinter } from "../types.ts";

export interface DeepgramMinterOptions {
  /** Master API key. Read from Deno.env by the entrypoint; never logged. */
  apiKey: string;
  baseUrl?: string;
  fetch?: typeof fetch;
}

/**
 * POST https://api.deepgram.com/v1/auth/grant
 * Body { ttl_seconds } -> { access_token, expires_in }
 * (https://developers.deepgram.com/reference/auth/tokens/grant)
 */
export class DeepgramTokenMinter implements TokenMinter {
  private readonly baseUrl: string;
  private readonly fetchFn: typeof fetch;

  constructor(private readonly opts: DeepgramMinterOptions) {
    this.baseUrl = opts.baseUrl ?? "https://api.deepgram.com";
    this.fetchFn = opts.fetch ?? fetch;
  }

  async mint(ttlSeconds: number): Promise<MintedToken> {
    let response: Response;
    try {
      response = await this.fetchFn(`${this.baseUrl}/v1/auth/grant`, {
        method: "POST",
        headers: {
          Authorization: `Token ${this.opts.apiKey}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({ ttl_seconds: ttlSeconds }),
      });
    } catch (error) {
      throw new ProviderUnavailableError(`deepgram: ${String(error)}`);
    }

    if (!response.ok) {
      throw new ProviderUnavailableError(
        `deepgram: /v1/auth/grant -> ${response.status}`,
      );
    }

    const body = (await response.json()) as {
      access_token?: string;
      expires_in?: number;
    };
    if (!body.access_token) {
      throw new ProviderUnavailableError("deepgram: grant returned no token");
    }
    return {
      token: body.access_token,
      expiresInSeconds: body.expires_in ?? ttlSeconds,
    };
  }
}
