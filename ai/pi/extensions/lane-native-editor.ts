type EditorComponent = unknown;

const POWERLINE_WIDGETS = [
  "powerline-status",
  "powerline-top",
  "powerline-secondary",
  "powerline-bash-transcript",
  "powerline-pending-send",
  "powerline-queue-preview",
  "powerline-last-prompt",
] as const;

type LaneEditorUi = {
  setEditorComponent(component: EditorComponent | undefined): void;
  getEditorText(): string;
  setFooter(component: unknown | undefined): void;
  setWidget(name: string, component: unknown | undefined, options?: unknown): void;
  onTerminalInput(listener: (data: string) => unknown): () => void;
};

type SessionStartContext = {
  hasUI: boolean;
  ui: LaneEditorUi;
  sessionManager?: {
    getSessionName?(): string | undefined;
  };
};

type ExtensionApi = {
  on(event: "session_start", listener: (event: unknown, ctx: SessionStartContext) => void): void;
};

export function isLaneSession(
  name: string | undefined,
  env: Readonly<Record<string, string | undefined>> = process.env,
): boolean {
  return env.HERDR_ENV === "1" &&
    Boolean(env.HERDR_PANE_ID) &&
    Boolean(env.HERDR_WORKSPACE_ID) &&
    typeof name === "string" &&
    /^[a-z0-9][a-z0-9-]*-\d+$/.test(name);
}

export default function installLaneNativeEditor(pi: ExtensionApi): void {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI || !isLaneSession(ctx.sessionManager?.getSessionName?.())) return;

    const setEditorComponent = ctx.ui.setEditorComponent.bind(ctx.ui);
    const setFooter = ctx.ui.setFooter.bind(ctx.ui);
    const setWidget = ctx.ui.setWidget.bind(ctx.ui);

    // Lane startup needs Pi's complete native input frame. Suppress Powerline
    // regardless of whether this extension's session_start listener runs before
    // or after Powerline's listener, without changing ordinary interactive Pi.
    ctx.ui.setEditorComponent = () => setEditorComponent(undefined);
    ctx.ui.setFooter = () => setFooter(undefined);
    ctx.ui.setWidget = (name, component, options) => {
      if (name.startsWith("powerline-")) {
        setWidget(name, undefined);
        return;
      }
      setWidget(name, component, options);
    };

    setEditorComponent(undefined);
    setFooter(undefined);
    for (const name of POWERLINE_WIDGETS) setWidget(name, undefined);

    // Powerline checks the editor text before opening its delayed welcome
    // overlay. Report a non-empty value to that startup check without writing a
    // visible draft, and restore the native empty result as soon as lane input
    // starts. Existing resumed drafts already block the welcome themselves.
    const getEditorText = ctx.ui.getEditorText.bind(ctx.ui);
    if (!getEditorText()) {
      const guardedGetEditorText = () => getEditorText() || " ";
      let unsubscribe: (() => void) | undefined;
      const restoreEditorText = () => {
        if (ctx.ui.getEditorText === guardedGetEditorText) {
          ctx.ui.getEditorText = getEditorText;
        }
        unsubscribe?.();
      };
      ctx.ui.getEditorText = guardedGetEditorText;
      unsubscribe = ctx.ui.onTerminalInput(restoreEditorText);
    }
  });
}
