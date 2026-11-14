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

/** "restricted" arrives as "denied". */
export type WatchPermission = "granted" | "denied" | "notAsked";

/** What the Paceo watch app may do, as the watch last reported it. */
export type WatchPermissions = {
  /** Saving workouts to Health; also stands in for reading heart rate, which Apple hides. */
  health: WatchPermission;
  /** GPS for outdoor workouts. */
  location: WatchPermission;
  /** Fitness Tracking for the whole watch: "denied" means it's off. */
  motion: WatchPermission;
  /** Unix ms. */
  checkedAt: number;
};

export type WatchPlanWanted = { missingPosters?: string[]; current?: boolean };

type WatchLinkEvents = {
  onWatchSnapshot: (e: { json: string }) => void;
  /** `ended`: the watch ended the workout itself (not just out of reach). Absent on older binaries. */
  onWatchMirror: (e: { active: boolean; ended?: boolean }) => void;
  onWatchFinished: () => void;
  onWatchPermissions: (p: WatchPermissions) => void;
  /**
   * The watch asked for the plan (it does each time its app comes to the
   * front): send a fresh one if the week changed, and the photos it says
   * it's missing. `current`: it already holds the last plan this phone
   * sent, so an unchanged week needs no resend. Absent on older binaries,
   * where every ask is answered with a plan.
   */
  onWatchPlanWanted: (e: WatchPlanWanted) => void;
};

type WatchLinkNative = {
  getStatus(): WatchStatus;
  getMirroredSnapshot(): string | null;
  sendPlan(json: string): Promise<void>;
  /**
   * The watch's last ask for the plan if no plan has gone out since: it
   * can ask before JS is listening (it wakes the app in the background).
   * Taking it clears it. Absent on older binaries.
   */
  takePlanWanted?(): WatchPlanWanted | null;
  /** A downsized exercise still, keyed by exercise (exerciseId ?? name). */
  sendPoster(fileUri: string, key: string): void;
  sendCommand(json: string): boolean;
  /** Launches the Paceo watch app and starts this built session there. True once the watch confirms. */
  startOnWatch(json: string): Promise<boolean>;
  getPendingFinished(): WatchFinished[];
  ackFinished(logKey: string): void;
  /** Asks the watch afresh when it's in reach, else its last report; null before it ever reported. */
  checkPermissions(): Promise<WatchPermissions | null>;
  /**
   * What the watch is running, asked directly: the workout's logKey, "" for
   * none, null when it can't be reached. Absent on binaries before it.
   */
  getWatchState?(): Promise<string | null>;
  addListener<E extends keyof WatchLinkEvents>(event: E, listener: WatchLinkEvents[E]): EventSubscription;
};

export const WatchLink = requireOptionalNativeModule<WatchLinkNative>("ExpoWatchLink");
