import { requireOptionalNativeModule, type EventSubscription } from "expo";

// The phone's side of the Paceo Apple Watch app. iOS only; null on Android
// and on binaries built before the watch app existed, so callers guard on
// `WatchLink` being non-null rather than on the platform.
//
// Payloads are JSON strings whose shape the app owns (a built strength
// session, its commands). This module only carries them.

export type WatchStatus = {
  supported: boolean;
  paired?: boolean;
  /** The Paceo watch app is installed on the paired watch. */
  installed?: boolean;
  reachable?: boolean;
  /** A watch-owned workout is mirrored to this phone right now. */
  mirroring?: boolean;
};

export type WatchFinished = { logKey: string; json: string };

type WatchLinkEvents = {
  onWatchSnapshot: (e: { json: string }) => void;
  onWatchMirror: (e: { active: boolean }) => void;
  onWatchFinished: () => void;
};

type WatchLinkNative = {
  getStatus(): WatchStatus;
  getMirroredSnapshot(): string | null;
  sendPlan(json: string): Promise<void>;
  /** A downsized exercise still, keyed by exercise (exerciseId ?? name). */
  sendPoster(fileUri: string, key: string): void;
  sendCommand(json: string): boolean;
  /** Launches the Paceo watch app and starts this built session there. True once the watch confirms. */
  startOnWatch(json: string): Promise<boolean>;
  getPendingFinished(): WatchFinished[];
  ackFinished(logKey: string): void;
  addListener<E extends keyof WatchLinkEvents>(event: E, listener: WatchLinkEvents[E]): EventSubscription;
};

export const WatchLink = requireOptionalNativeModule<WatchLinkNative>("ExpoWatchLink");
