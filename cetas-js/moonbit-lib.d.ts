// Type shim for the MoonBit-compiled ESM module. The actual module is emitted
// by `moon build --target js` to `../../_build/js/{debug,release}/build/colmugx/cetas-js/lib/lib.js`.
// We use a wildcard module declaration so TS doesn't try to read the .js file
// (which has no .d.ts sibling). The runtime types are loose because the
// boundary is JSON-string-based.
declare module "*/cetas-js/lib/lib.js" {
  export const CetasJsConfig: new (
    apiKey: string,
    baseUrl: string,
    model: string,
    cwd: string,
    maxToolRounds: number,
  ) => unknown;
  export function cetas_js_create_agent(
    config: unknown,
    observerCallback: (eventJson: string) => void,
    renderCallback: (eventJson: string) => void,
    requestCallback: (eventJson: string) => Promise<string>,
  ): Promise<unknown>;
  export function cetas_js_run_turn(
    agent: unknown,
    prompt: string,
    sessionId: string,
  ): Promise<string>;
  export function cetas_js_shutdown(agent: unknown): Promise<void>;
}
