/**
 * pi-fleet · Fleet Calm — operational user-row layout adapter (gh-9)
 *
 * Ported from Firstmate's `.pi/extensions/lib/fm-calm-operational-user-layout.ts`
 * (MIT, Kun Chen — see the NOTICE in extensions/lib/fleet-calm.ts).
 *
 * Renders pi-fleet's OWN user-role operational rows (FLEET WATCHER WAKE: and
 * T-019 health watchdog envelopes, classified by
 * ./fleet-calm-visibility.ts isFleetOperationalUserText) at ZERO height while
 * Calm is active, while preserving Pi's ordinary user row assignment (ordering,
 * history, session data, model context) exactly. The classifier is pi-fleet's
 * own prefix taxonomy — Firstmate's synthetic U+2063 envelopes are NOT imported.
 *
 * API probing: the adapter patches the exact exported
 * `InteractiveMode.prototype.addMessageToChat` seam and throws when the seam is
 * missing; fleet-calm.ts catches that and skips ONLY this adapter with a
 * diagnostic (pi version independent).
 */

import type { UserMessageComponent as PiUserMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides, isFleetOperationalUserText } from "./fleet-calm-visibility.js";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process (same technique as Firstmate).
const FLEET_CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "pi-fleet:fleet-calm-operational-user-layout:pi-0.81.1",
);

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => isFleetOperationalUserText(text);
  const installed = registry[FLEET_CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Fleet Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Fleet Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Fleet Calm requires Pi UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      hasLeadingSpacer: boolean,
    ) {
      super(text, markdownTheme, outputPad);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new CalmOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.chatContainer.children.length > 0,
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  registry[FLEET_CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}