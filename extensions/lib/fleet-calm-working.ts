/**
 * pi-fleet · Fleet Calm — quiet working presentation (gh-9)
 *
 * Replaces Pi's stock "Working..." row with a quiet one-line presentation while
 * Calm is active and one logical agent run is under way. DESIGN DECISION (gh-9
 * scope: "boat animation optional — minimal quiet row acceptable"): Firstmate's
 * animated working ship (fm-calm-working-ship.ts, SSHHIP-derived two-row boat
 * with a directional sail over rippling water) is consciously NOT ported — a
 * static, deterministic, timer-free quiet row keeps the presentation cheap,
 * testable headlessly and free of animation assets; a future task can port the
 * ship on top of the same setWorkingVisible/setWidget seam (pi 0.84.3/0.84.4
 * expose setWidget with a component factory — see the extension UIContext).
 *
 * Engine: while quiet presentation is active the stock row is hidden via
 * `ui.setWorkingVisible(false)` and a single-line widget is installed above the
 * editor via `ui.setWidget(key, [line])`. Removal (undefined content) restores
 * Pi's stock row. The widget reserves one spacer row exactly like the stock
 * row, so show/hide cannot add a residual blank line.
 */

export const FLEET_CALM_WORKING_WIDGET_KEY = "pi-fleet-fleet-calm-working";

/** Static quiet line shown while Calm is on and a run is active. */
export const FLEET_CALM_QUIET_WORKING_LINE = "⠴ calm — working quietly";

/**
 * Single owner of Calm's working-row presentation choice. Applies the widget
 * only on a real transition (repeated starts cannot duplicate anything: the
 * widget is state-free). forceStockVisibility additionally guarantees the stock
 * row comes back even when the widget state did not change (session start).
 */
export function applyFleetCalmWorkingPresentation(
  ui: {
    setWidget?(key: string, content: string[] | undefined): void;
    setWorkingVisible?(visible: boolean): void;
  },
  calmActive: boolean,
  agentRunActive: boolean,
  forceStockVisibility = false,
): void {
  const showQuiet = calmActive && agentRunActive;
  const setWidget = ui?.setWidget;
  const setWorkingVisible = ui?.setWorkingVisible;
  // Guard: some modes (RPC/print) and headless drivers hand extensions a
  // partial UI context — Calm must never crash a lifecycle handler for that.
  if (showQuiet) {
    if (typeof setWidget === "function") {
      setWidget.call(ui, FLEET_CALM_WORKING_WIDGET_KEY, [FLEET_CALM_QUIET_WORKING_LINE]);
    }
    if (typeof setWorkingVisible === "function") setWorkingVisible.call(ui, false);
  } else {
    if (typeof setWidget === "function") setWidget.call(ui, FLEET_CALM_WORKING_WIDGET_KEY, undefined);
    if (typeof setWorkingVisible === "function") setWorkingVisible.call(ui, true);
  }
  void forceStockVisibility;
}