const messages = {
  authentication: "Provider authentication failed. Check the configured credential. No retry was made.",
  quota: "Provider balance or quota is insufficient. No retry was made.",
  rate_limit: "Provider rate limit reached. No retry was made.",
  request: "Provider request was rejected. Check the model and input configuration. No retry was made.",
  timeout: "Provider request timed out; it may have been processed. No retry was made.",
  transport: "Provider connection failed; the request may have been processed. No retry was made.",
  response: "Provider returned an invalid or incomplete response. No retry was made.",
  unsupported: "The provider returned an unsupported response mode. No retry was made.",
} as const;

// Only fixed, safe diagnostics cross into runtime state. Raw HTTP bodies and
// transport errors can contain credentials, request data, or account identifiers.
export class ProviderFailure extends Error {
  readonly code: keyof typeof messages;
  constructor(code: keyof typeof messages) {
    super(messages[code]);
    this.name = "ProviderFailure";
    this.code = code;
  }
}
