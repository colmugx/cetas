// Type shim for the MoonBit-compiled ESM module. The actual module is emitted
// by `moon build --target js` to `../../_build/js/{debug,release}/build/colmugx/cetas-js/lib/lib.js`.
// We use a wildcard module declaration so TS doesn't try to read the .js file
// (which has no .d.ts sibling). The runtime types are loose because the
// boundary is JSON-string-based.
declare module "*/cetas-js/lib/lib.js" {
  export const CetasJsConfig: new (
    cwd: string,
    maxToolRounds: number,
    home: string,
    permissionMode: string,
    /** Session root; empty string falls back to `<home>/.cetas/sessions`. */
    sessionsDir: string,
  ) => unknown;
  export const CetasJsRuntime: new (config: unknown) => unknown;
  export function cetas_js_runtime_create_agent(
    runtime: unknown,
    observerCallback: (eventJson: string) => void,
    renderCallback: (eventJson: string) => void,
    requestCallback: (eventJson: string) => Promise<string>,
    cancelCheck: () => boolean,
  ): Promise<unknown>;
  export function cetas_js_runtime_describe_setup(runtime: unknown): Promise<string>;
  export function cetas_js_runtime_refresh_model_catalogs(
    runtime: unknown,
    providerIdsJson: string,
  ): Promise<string>;
  export function cetas_js_runtime_login_provider(
    runtime: unknown,
    provider: string,
    observerCallback: (eventJson: string) => void,
    requestCallback: (eventJson: string) => Promise<string>,
    cancelCheck: () => boolean,
    method: string,
  ): Promise<string>;
  export function cetas_js_run_turn(
    agent: unknown,
    prompt: string,
    imagesJson: string,
    sessionId: string,
    signal: AbortSignal,
  ): Promise<string>;
  export function cetas_js_abort_turn(agent: unknown): string;
  export function cetas_js_active_model_supports_images(agent: unknown): string;
  export function cetas_js_enqueue_follow_up(
    agent: unknown,
    prompt: string,
    imagesJson: string,
  ): string;
  export function cetas_js_shutdown(agent: unknown): Promise<void>;
  export function cetas_js_list_commands(agent: unknown): string;
  export function cetas_js_tool_catalog(agent: unknown): string;
  export function cetas_js_invoke_command(
    agent: unknown,
    id: string,
    argsJson: string,
  ): Promise<string>;
  export function cetas_js_list_workspace_files(config: unknown): Promise<string>;
}
