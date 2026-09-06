/**
 * pi-fleet · Fleet Calm — assistant layout adapter (collapsed thinking +
 * mid-turn working notes) (gh-9)
 *
 * Ported from Firstmate's `.pi/extensions/lib/fm-calm-assistant-layout.ts`
 * (MIT, Kun Chen — see the NOTICE in extensions/lib/fleet-calm.ts).
 *
 * Removes collapsed thinking and mid-turn assistant text blocks (classified
 * "assistant-working-note") from a SHALLOW presentation copy passed to Pi's
 * `AssistantMessageComponent.updateContent`. The message itself, model context,
 * session storage, and export rendering are never touched.
 *
 * API probing: the adapter patches the exact exported
 * `AssistantMessageComponent.prototype.updateContent` seam and throws when the
 * seam is missing; fleet-calm.ts catches that and skips ONLY this adapter with a
 * diagnostic (pi version independent — never crashes Calm or pi).
 */

import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fleet-calm-visibility.js";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
};

/**
 * A mid-turn assistant message is one the model did not end its response with:
 * Pi's agent loop runs its tool calls and then issues another assistant message.
 * stopReason is intrinsic to each message and already set while it streams.
 * It stays "pending" until the tool call materializes — so a working note is
 * briefly visible before its row collapses; suppressing pending text would also
 * stop a genuine reply from streaming.
 */
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process (same technique as Firstmate).
const FLEET_CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "pi-fleet:fleet-calm-assistant-layout:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[FLEET_CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  const patch: CalmAssistantLayoutPatch = { hidesThinking, hidesWorkingNote };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Fleet Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Fleet Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    const presentationMessage =
      hideThinking || hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(hideWorkingNote && block.type === "text"),
            ),
          }
        : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[FLEET_CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}