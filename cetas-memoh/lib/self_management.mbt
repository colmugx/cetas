///|
/// Built-in manuals owned by the standalone Memoh composition. Keep these
/// truthful to the capabilities actually composed here instead of importing
/// generic Cetas host documentation.
pub fn memoh_builtin_skills() -> Array[@skills.SkillDescriptor] {
  [
    @skills.SkillDescriptor::builtin(
      name="cetas-about",
      description="Cetas identity, capabilities, limits, and Memoh ownership; use for who/what/can-you-do questions.",
      body="You are Cetas running as a first-class Memoh ACP runtime on Posoco. " +
        "Memoh owns durable conversation continuity, workspace/platform operations, " +
        "memory, and host authorization. Posoco owns the agent/tool loop, and " +
        "RouterModelPort owns model execution. The local runtime intentionally " +
        "does not install parallel filesystem, shell, web, memory, or permission " +
        "surfaces: use Memoh Tools for host operations. Cetas-Memoh owns only its " +
        "provider configuration and credentials plus product-level self-management. " +
        "Memoh Tools are exposed through a lazy tool gateway so their full schemas " +
        "are loaded only when needed.",
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-usage",
      description="How to use Cetas inside Memoh: normal turns, model controls, questions, and lazy Memoh Tools.",
      body="Use Cetas normally from a Memoh conversation. Model and reasoning " +
        "choices are exposed through ACP session config options. When clarification " +
        "is required, the ask_question tool uses Memoh's ACP elicitation UI. " +
        "Workspace, platform, memory, and host-authorized actions must use Memoh " +
        "Tools. Those tools are deferred behind tool_list/tool_execute; discover a " +
        "relevant group when needed and reuse a schema already present in history. " +
        "For configuration questions, activate cetas-memoh-config before answering. " +
        "Do not assume generic Cetas ~/.cetas settings or local coding tools exist " +
        "in this composition.",
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-memoh-config",
      description="Use when configuring Cetas inside Memoh, providers, models, credentials, or explaining what Memoh owns.",
      body="Cetas-Memoh is independently configured from generic Cetas. " +
        "Its provider home is CETAS_MEMOH_HOME when set; otherwise " +
        "/data/.cetas-memoh when /data exists (Memoh's workspace mount); " +
        "otherwise $HOME/.cetas-memoh. The mount wins over HOME on purpose: " +
        "the ACP runtime runs with HOME=/data while a shell in the same " +
        "container usually has HOME=/root, so a setup run from the terminal " +
        "must not be allowed to write /root/.cetas-memoh. Non-secret provider " +
        "settings live in providers.json as a direct object keyed by provider " +
        "id. Credentials live under the credentials directory in the canonical " +
        "posoco-ext-credentials format. " +
        "Never ask the user to paste an API key or OAuth token into chat, never " +
        "read or display credential files through tools, and never copy secrets " +
        "into providers.json. Secret bootstrap belongs to the trusted host command " +
        "`cetas-memoh setup`, run from the Memoh terminal so /dev/tty exists. " +
        "After the first model is available, use Memoh Tools " +
        "for allowed workspace/platform operations and for non-secret configuration " +
        "changes. Provider catalogs are assembled at process startup, so restart " +
        "the Cetas-Memoh runtime after changing provider settings; Memoh keeps one " +
        "runtime process per agent, so that restart affects this Bot's live chats. " +
        "Memoh remains " +
        "the authority for conversation continuity, workspace/platform operations, " +
        "memory, and host authorization. A session opened without the Memoh Tools " +
        "gateway (for example a model-picker probe) has no platform tools; never " +
        "claim a host action succeeded in such a session.",
    ),
  ]
}
