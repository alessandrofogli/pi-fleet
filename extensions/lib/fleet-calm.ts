/**
 * pi-fleet · Fleet Calm — home-persistent quiet transcript presentation (gh-9)
 *
 * Ported from Firstmate's `.pi/extensions/fm-calm.ts` (MIT, Kun Chen;
 * https://github.com/kunchen/firstmate — read-only upstream, never modified in
 * this repo). This is a presentation-only port: nothing here strips content from
 * messages/context/session/export.
 *
 * While Calm is ON and an agent run is active it removes, from the LIVE
 * transcript only:
 *   - tool shells for the 7 built-ins it owns (bash, read, edit, write, grep,
 *     find, ls) — per-tool-name override slot, first-registration-wins, so a
 *     contested name is skipped with a prominent warning, never breaking the
 *     owning extension;
 *   - collapsed-thinking labels and mid-turn assistant working notes (the
 *     genuine final reply always stays visible);
 *   - pi-fleet's OWN operational user rows (FLEET WATCHER WAKE: and
 *     T-019 health watchdog envelopes, classified by fleet-calm-visibility.ts —
 *     pi-fleet's prefix taxonomy, NOT firstmate's synthetic kinds) and its
 *     fleet_notice custom messages;
 *   - Pi's stock "Working..." row, replaced by the quiet working presentation
 *     (see fleet-calm-working.ts).
 * Toggling Calm off restores ordinary rendering.
 *
 * FIRST-REGISTRATION-WINS (verified against installed Pi 0.84.3/0.84.4): Pi
 * keeps one ToolDefinition per tool name with no merge or unregister. Keep
 * Calm-off registration EMPTY; keep Calm-on LOAD-TIME registration synchronous
 * (restored rows capture the registry before session_start) and collision-check
 * only the later first-activation path, when getAllTools() is reliable.
 *
 * API seams: every presentation adapter probes the exact Pi API it patches and
 * degrades independently with a diagnostic (installCalmPresentationAdapter);
 * a seam Pi removes in the future disables only the affected adapter.
 */

import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
import type {
  ExtensionAPI,
  ExtensionUIContext,
  ToolDefinition,
  ToolInfo,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
} from "@earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";
import { installCalmAssistantLayout } from "./fleet-calm-assistant-layout.js";
import { installCalmCustomMessageLayout } from "./fleet-calm-custom-message-layout.js";
import { installCalmOperationalUserLayout } from "./fleet-calm-operational-user-layout.js";
import { applyFleetCalmWorkingPresentation } from "./fleet-calm-working.js";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FLEET_CALM_PRESENTATION_EVENT,
  loadCalmPreference,
  persistCalmPreference,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./fleet-calm-visibility.js";

type DefinitionFactory<TParams extends TSchema, TDetails, TState> = (
  cwd: string,
) => ToolDefinition<TParams, TDetails, TState>;

type RenderContext<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[2];

type RenderArgs<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[0];

type RenderTheme<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[1];

type RenderResult<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderResult"]>
>[0];

type StandardShellState = {
  shell?: unknown;
  call?: ComponentLike;
  result?: ComponentLike;
};

/** Structural Component contract (pi-tui exports it; kept minimal here). */
type ComponentLike = {
  render(width: number): string[];
  invalidate(): void;
  handleInput?(data: string): void;
  wantsKeyRelease?: boolean;
};

/**
 * pi bundles @earendil-works/pi-tui for extensions (peerDependencies "*" — see
 * the packages docs), but headless harnesses / older bundlings may not resolve
 * it. Resolve it LAZILY: tool-shell hiding uses structural empty components
 * (no pi-tui needed), and the self-rendered stock shell reconstruction (pi's
 * Box frame) applies only when pi-tui is available. When it is not, Fleet Calm
 * logs a diagnostic and keeps everything else working (thinking, operational
 * user rows, fleet_notice rows, quiet working presentation).
 */
type TuiShapes = {
  Box: new (
    paddingX?: number,
    paddingY?: number,
    bgFn?: (text: string) => string,
  ) => {
    children: ComponentLike[];
    addChild(component: ComponentLike): void;
    removeChild(component: ComponentLike): void;
    clear(): void;
    setBgFn(bgFn: (text: string) => string): void;
    invalidate(): void;
    render(width: number): string[];
  };
  Container: new () => ComponentLike;
};

let tuiState: {
  promise: Promise<boolean> | null;
  available: boolean;
  shapes: TuiShapes | null;
  raw: { getKeybindings?: () => { matches(input: string, keyId: string): boolean } } | null;
} = { promise: null, available: false, shapes: null, raw: null };

function bootTui(): Promise<boolean> {
  if (tuiState.promise) return tuiState.promise;
  tuiState.promise = new Promise((resolve) => {
    // Non-literal specifier: never statically resolved (type-safe against the
    // ambient shim; runtime resolution happens inside pi's bundled modules).
    import("@earendil-works/pi-tui" as unknown as string)
      .then((rawModule) => {
        const m = rawModule as unknown as {
          Box?: TuiShapes["Box"];
          Container?: TuiShapes["Container"];
        };
        if (typeof m?.Box === "function" && typeof m?.Container === "function") {
          tuiState.shapes = { Box: m.Box, Container: m.Container };
          tuiState.raw = rawModule as { getKeybindings?: () => { matches(input: string, keyId: string): boolean } };
          tuiState.available = true;
        } else {
          console.error("Fleet Calm: @earendil-works/pi-tui exports missing — tool-shell presentation degraded.");
        }
        resolve(tuiState.available);
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : String(error);
        console.error(
          `Fleet Calm: @earendil-works/pi-tui unavailable — tool-shell hiding and the stock-shell reconstruction are skipped (${reason}). The rest of Calm (thinking, operational rows, custom messages, quiet working presentation) keeps working.`,
        );
        tuiState.available = false;
        resolve(false);
      });
  });
  return tuiState.promise;
}

/** True once @earendil-works/pi-tui resolved (drivers await this for determinism). */
export async function fleetCalmTuiReady(): Promise<boolean> {
  return bootTui();
}

/** Structural empty component — hides a row without any pi-tui dependency. */
function emptyComponent(): ComponentLike {
  return { render: () => [], invalidate: () => {} };
}

const extensionFile = fileURLToPath(import.meta.url);

// Resolves symlinks before comparing tool-ownership identity: sourceInfo.path
// values come from independent path-resolution code paths (import.meta.url vs.
// Pi's extension loader). Falls back to the raw path for synthetic sourceInfo
// paths such as "<builtin:read>" (realpathSync rejects them).
const realpathOrSelf = (path: string): string => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};
const extensionRealFile = realpathOrSelf(extensionFile);

// Each presentation adapter probes the exact Pi API it patches; a missing seam
// degrades ONLY that adapter with a diagnostic, never Calm or pi.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Fleet Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

export function installFleetCalm(pi: ExtensionAPI): void {
  // Resolve pi-tui lazily (async); the wrapped tool defs probe it at render time.
  void bootTui().catch(() => {});
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("pi-fleet-custom-message-row", installCalmCustomMessageLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked agent_start → agent_settled (settle fires
  // from a finally block, so it also covers abort and failure).
  let agentRunActive = false;

  const publishPresentationState = (): void => {
    pi.events.emit(FLEET_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    } satisfies {
      active: boolean;
      stockExportRendering: boolean;
    });
  };

  // Every on-screen tool row Calm presents, keyed by the row-local state Pi
  // hands its render slots so Calm can repaint exactly those rows without
  // touching Pi's whole transcript (see the /export handler).
  const calmToolRowRepaints = new Map<object, () => void>();
  const rememberCalmToolRow = (state: object, invalidate: unknown): void => {
    if (exportRendering || typeof invalidate !== "function") return;
    calmToolRowRepaints.set(state, invalidate as () => void);
  };
  const repaintCalmToolRows = (): void => {
    for (const invalidate of calmToolRowRepaints.values()) invalidate();
  };

  function wrapBuiltIn<TParams extends TSchema, TDetails, TState>(
    factory: DefinitionFactory<TParams, TDetails, TState>,
  ): ToolDefinition<TParams, TDetails, TState> {
    const definitions = new Map<string, ToolDefinition<TParams, TDetails, TState>>();
    const definitionFor = (cwd: string): ToolDefinition<TParams, TDetails, TState> => {
      let definition = definitions.get(cwd);
      if (!definition) {
        definition = factory(cwd);
        definitions.set(cwd, definition);
      }
      return definition;
    };

    const original = definitionFor(process.cwd());
    const originalRenderCall = original.renderCall;
    const originalRenderResult = original.renderResult;
    const originalSelfShell = original.renderShell === "self";
    const standardShells = new WeakMap<object, StandardShellState>();

    if (!originalRenderCall || !originalRenderResult) {
      throw new Error(`Fleet calm mode requires both render slots for Pi built-in tool ${original.name}`);
    }

    const shellStateFor = (
      context: RenderContext<TParams, TDetails, TState>,
    ): StandardShellState => {
      const rowState = context.state as object;
      let shellState = standardShells.get(rowState);
      if (!shellState) {
        shellState = {};
        standardShells.set(rowState, shellState);
      }
      return shellState;
    };

    const refreshStandardShell = (
      state: StandardShellState,
      theme: RenderTheme<TParams, TDetails, TState>,
      context: RenderContext<TParams, TDetails, TState>,
    ): ComponentLike => {
      // Rebuild Pi's standard tool shell (same construction Pi's
      // ToolExecutionComponent uses: Box(1, 1, bgFn)) so a Calm-off run renders
      // the exact stock frame; only the render slot theme is consulted — never
      // pi's global theme proxy, so headless drivers that skip initTheme are
      // safe until they reach pi's own components.
      const background = context.isPartial
        ? (text: string) => theme.bg("toolPendingBg", text)
        : context.isError
          ? (text: string) => theme.bg("toolErrorBg", text)
          : (text: string) => theme.bg("toolSuccessBg", text);
      const Box = tuiState.shapes?.Box;
      if (!Box) {
        // pi-tui not available (headless harness): no box frame — see file
        // header for the degradation contract.
        const shell = { render: () => [], invalidate: () => {} };
        state.shell = shell;
        return shell as unknown as ReturnType<NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>>;
      }
      const shell = (state.shell as InstanceType<TuiShapes["Box"]> | undefined) ?? new Box(1, 1, background);
      state.shell = shell;
      shell.setBgFn(background);
      shell.clear();
      if (state.call) shell.addChild(state.call as ComponentLike);
      if (state.result) shell.addChild(state.result as ComponentLike);
      return shell;
    };

    return {
      ...original,
      renderShell: "self",

      async execute(toolCallId, params, signal, onUpdate, ctx) {
        return definitionFor(ctx.cwd).execute(toolCallId, params, signal, onUpdate, ctx);
      },

      renderCall(
        args: RenderArgs<TParams, TDetails, TState>,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call")) return emptyComponent();
        if (originalSelfShell || !tuiState.available) return originalRenderCall(args, theme, context);

        const state = shellStateFor(context);
        state.call = originalRenderCall(args, theme, {
          ...context,
          lastComponent: state.call,
        });
        return refreshStandardShell(state, theme, context);
      },

      renderResult(
        result: RenderResult<TParams, TDetails, TState>,
        options: ToolRenderResultOptions,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result")) return emptyComponent();
        if (originalSelfShell || !tuiState.available) return originalRenderResult(result, options, theme, context);

        const state = shellStateFor(context);
        state.result = originalRenderResult(result, options, theme, {
          ...context,
          lastComponent: state.result,
        });
        refreshStandardShell(state, theme, context);
        return emptyComponent();
      },
    };
  }

  const wrappedBuiltIns: ToolDefinition<any, any, any>[] = [
    wrapBuiltIn(createReadToolDefinition),
    wrapBuiltIn(createBashToolDefinition),
    wrapBuiltIn(createEditToolDefinition),
    wrapBuiltIn(createWriteToolDefinition),
    wrapBuiltIn(createGrepToolDefinition),
    wrapBuiltIn(createFindToolDefinition),
    wrapBuiltIn(createLsToolDefinition),
  ];


  // True once this extension has handled built-in registration for its lifetime:
  // either all seven synchronously at load, or only the uncontested subset
  // during first activation.
  let builtInsRegistered = false;

  // Gate on Calm already being on at load time. Synchronous and unconditional:
  // a Calm-off session registers nothing (no collision exposure); a Calm-on
  // session must claim before session_start for restored rows to capture the
  // right definitions.
  if (loadCalmPreference()) {
    for (const tool of wrappedBuiltIns) pi.registerTool(tool);
    builtInsRegistered = true;
  }

  // Which of the 7 built-ins are currently owned by a different, non-builtin
  // extension. Only safe after every extension finished loading (never during
  // the factory's own synchronous execution above).
  function contestedBuiltIns(): ToolDefinition<any, any, any>[] {
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Fleet Calm: built-in ownership check unavailable, claiming every built-in unconditionally. ${reason}`);
      return [];
    }
    return wrappedBuiltIns.filter((tool) => {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      return owner !== undefined && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile;
    });
  }

  // The first time Calm turns on in a session that started off, claim every
  // uncontested built-in; leave each contested tool and its owning extension
  // untouched and tell the user which built-in Calm could not take over.
  function activateBuiltInsIfNeeded(ui: ExtensionUIContext): void {
    if (builtInsRegistered) return;
    const contested = contestedBuiltIns();
    const contestedNames = new Set(contested.map((tool) => tool.name));
    for (const tool of wrappedBuiltIns) {
      if (!contestedNames.has(tool.name)) pi.registerTool(tool);
    }
    builtInsRegistered = true;
    if (contested.length === 0) return;
    const names = contested.map((tool) => `"${tool.name}"`).join(", ");
    const plural = contested.length > 1;
    if (typeof ui?.notify === "function") {
      ui.notify(
        `Fleet Calm: the ${names} built-in tool${plural ? "s are" : " is"} already provided by another extension, so Calm may not fully function for ${plural ? "them" : "it"} this session.`,
        "warning",
      );
    }
    for (const tool of contested) {
      console.error(`Fleet Calm: skipped claiming built-in "${tool.name}" because another extension already owns it.`);
    }
  }

  // Backstop for load-time claims: Calm registered unconditionally because it
  // was already on, so it can still silently lose a name to an earlier-loaded
  // extension. Runs on every session_start reason (a reload rebuilds every
  // extension's registrations from scratch).
  function reportBuiltInLosses(): void {
    if (!builtInsRegistered) return;
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Fleet Calm: built-in ownership check unavailable. ${reason}`);
      return;
    }
    for (const tool of wrappedBuiltIns) {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      if (owner && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile) {
        console.error(
          `Fleet Calm: another extension (${owner.path}) also claimed the built-in "${tool.name}" tool and won; Calm's presentation for it is unavailable this session.`,
        );
      }
    }
  }

  pi.on("session_start", (_event, ctx) => {
    reportBuiltInLosses();
    calmToolRowRepaints.clear();
    exportRendering = false;
    // A session start is the durable home check-point: re-read the persisted
    // choice (a sibling session may have toggled it) and reset export stock.
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    applyFleetCalmWorkingPresentation(ctx.ui, calmPresentationIsActive(), false, true);
    // Guard: some modes (RPC/print) hand extensions a partial UI context.
    if (typeof ctx.ui?.setHiddenThinkingLabel === "function") {
      ctx.ui.setHiddenThinkingLabel(calmPresentationIsActive() ? "" : undefined);
    }
    if (typeof ctx.ui?.setStatus === "function") {
      ctx.ui.setStatus("pi-fleet-fleet-calm", undefined);
    }
    removeTerminalInputHandler?.();
    try {
      if (typeof ctx.ui?.onTerminalInput !== "function") return;
      removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
        if (!tuiState.available || !data) return undefined;
        const matches = (() => {
          try {
            const getKeybindings = tuiState.raw?.getKeybindings;
            // without pi-tui there is no keybinding table → accept the submit
            return getKeybindings ? getKeybindings().matches(data, "tui.input.submit") : true;
          } catch {
            return false;
          }
        })();
        if (!matches) return undefined;

        const input = typeof ctx.ui?.getEditorText === "function" ? ctx.ui.getEditorText().trim() : "";
        if (
          input !== "/share" &&
          input !== "/export" &&
          !input.startsWith("/export ")
        ) {
          return undefined;
        }

        // While /export or /share renders the session, Calm must render the
        // stock content (exported artifacts keep every tool row). After the
        // macrotask, repaint only the rows Calm presents — never the whole
        // transcript — so no status line overwrites the export confirmation
        // (Pi 0.83.0+ emits a status line per expansion change; consecutive
        // status lines coalesce).
        exportRendering = true;
        setCalmStockExportRendering(true);
        publishPresentationState();
        setTimeout(() => {
          exportRendering = false;
          setCalmStockExportRendering(false);
          publishPresentationState();
          repaintCalmToolRows();
          if (typeof ctx.ui?.setStatus === "function") {
            ctx.ui.setStatus("pi-fleet-fleet-calm", undefined);
          }
        }, 0);
        return undefined;
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Fleet Calm: export stock-rendering hook unavailable, skipping. ${reason}`);
    }
  });

  pi.on("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyFleetCalmWorkingPresentation(ctx.ui, calmPresentationIsActive(), true);
  });

  // agent_settled fires from a finally block — also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    applyFleetCalmWorkingPresentation(ctx.ui, calmPresentationIsActive(), false);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyFleetCalmWorkingPresentation(ctx.ui, calmPresentationIsActive(), false);
  });

  // Command name: "fleet-calm" (not "calm") — pi-fleet convention (every fleet
  // command/tool is namespaced, cf. fleet-watch-arm-pi) and collision-proof:
  // pi renames duplicate command names to name:1/name:2 when another extension
  // registers a bare "calm", so the short name would be ambiguous.
  pi.registerCommand("fleet-calm", {
    description: "Toggle pi-fleet's Calm mode: quiet transcript presentation (hides tool shells, collapsed thinking, working notes and pi-fleet's operational rows; the preference survives restarts).",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      if (active) activateBuiltInsIfNeeded(ctx.ui);
      publishPresentationState();
      applyFleetCalmWorkingPresentation(ctx.ui, active, agentRunActive, true);
      // Guard (RPC/print modes hand extensions a partial UI context).
      if (typeof ctx.ui?.setHiddenThinkingLabel === "function") {
        ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      }
      if (typeof ctx.ui?.setStatus === "function") {
        ctx.ui.setStatus("pi-fleet-fleet-calm", undefined);
      }

      // Expansion round-trip forces ToolExecutionComponent to rebuild the rows
      // with the new renderShell/render content, then restores the exact
      // previous Ctrl+O state.
      if (
        typeof ctx.ui?.getToolsExpanded === "function" &&
        typeof ctx.ui?.setToolsExpanded === "function"
      ) {
        const expanded = ctx.ui.getToolsExpanded();
        ctx.ui.setToolsExpanded(!expanded);
        ctx.ui.setToolsExpanded(expanded);
      }
    },
  });
}

/** The 7 Pi built-in tool names Fleet Calm owns (per-tool-name override slot). */
export const FLEET_CALM_TOOL_NAMES: readonly string[] = [
  "read",
  "bash",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
];

/** Alias for callers that prefer the default-export style of the loader. */
export default installFleetCalm;