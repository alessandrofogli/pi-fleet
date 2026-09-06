/**
 * pi-fleet · Fleet Calm — pi-fleet custom-message layout adapter (gh-9)
 *
 * pi-fleet injects its watcher wakes as `customType: "fleet_notice"` custom
 * messages; the external watcher (fleet-watch-arm.ts sendWake) uses
 * `display: true`, so those operational rows normally render a
 * "[fleet_notice] FLEET WATCHER WAKE: ..." box in the transcript. While Calm is
 * active this adapter renders those OWN rows at zero height — presentation
 * only; the message, ordering, context and session data stay untouched.
 *
 * Only pi-fleet's own customType is affected (isFleetOperationalCustomType);
 * arbitrary third-party custom messages always render normally.
 *
 * API probing: it patches the exact exported
 * `CustomMessageComponent.prototype.render` seam and throws when the seam is
 * missing; fleet-calm.ts catches that and skips ONLY this adapter with a
 * diagnostic (pi version independent).
 */

import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides, isFleetOperationalCustomType } from "./fleet-calm-visibility.js";

type CustomMessageLike = {
  customType?: string;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const FLEET_CALM_CUSTOM_MESSAGE_LAYOUT_PATCH = Symbol.for(
  "pi-fleet:fleet-calm-custom-message-layout:pi-0.81.1",
);

type CalmCustomMessageLayoutPatch = {
  hidesOperationalCustom: () => boolean;
};

export function installCalmCustomMessageLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmCustomMessageLayoutPatch | undefined;
  };
  const hidesOperationalCustom = (): boolean =>
    calmPresentationHides("custom-message") ||
    calmPresentationHides("synthetic-user");
  const installed = registry[FLEET_CALM_CUSTOM_MESSAGE_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalCustom = hidesOperationalCustom;
    return;
  }

  const patch: CalmCustomMessageLayoutPatch = { hidesOperationalCustom };
  const CustomMessageComponent = PiCodingAgent.CustomMessageComponent;
  if (typeof CustomMessageComponent !== "function") {
    throw new Error("Fleet Calm requires Pi CustomMessageComponent");
  }
  const prototype = CustomMessageComponent.prototype as unknown as {
    render?: (width: number) => string[];
    message?: CustomMessageLike;
  };
  const originalRender = prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Fleet Calm requires Pi CustomMessageComponent.render");
  }

  CustomMessageComponent.prototype.render = function (width: number): string[] {
    const self = this as unknown as { message?: CustomMessageLike };
    if (
      patch.hidesOperationalCustom() &&
      isFleetOperationalCustomType(self.message?.customType)
    ) {
      return [];
    }
    return originalRender.call(this, width);
  };

  registry[FLEET_CALM_CUSTOM_MESSAGE_LAYOUT_PATCH] = patch;
}