/**
 * Ambient module declaration for `@earendil-works/pi-tui` (gh-9 fleet-calm).
 *
 * pi bundles this package for extensions (peerDependencies with "*" — see the
 * packages docs), so the import RESOLVES at runtime inside a real pi process.
 * This repo does not install pi-tui into its own node_modules (it ships inside
 * the pi-coding-agent package), so tsc needs this minimal ambient shape for the
 * exact API surface fleet-calm uses. Keep it in lock-step with the usage — do
 * NOT grow it into a general-purpose pi-tui typing.
 */
declare module "@earendil-works/pi-tui" {
  export interface Component {
    render(width: number): string[];
    handleInput?(data: string): void;
    wantsKeyRelease?: boolean;
    invalidate(): void;
  }

  export class Container implements Component {
    children: Component[];
    addChild(component: Component): void;
    removeChild(component: Component): void;
    clear(): void;
    invalidate(): void;
    render(width: number): string[];
  }

  export class Box extends Container {
    constructor(
      paddingX?: number,
      paddingY?: number,
      bgFn?: (text: string) => string,
    );
    setBgFn(bgFn: (text: string) => string): void;
  }

  export interface KeybindingsManager {
    matches(input: string, keyId: string): boolean;
  }

  export function getKeybindings(): KeybindingsManager;
}