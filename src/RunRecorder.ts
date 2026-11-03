import { NativeModule, requireNativeView, requireOptionalNativeModule } from "expo";
import * as React from "react";
import type { StyleProp, ViewStyle } from "react-native";

// Records a cardio session on the phone: GPS distance, pace, route, and
// (with write access) a workout in Apple Health (iOS 17+) or Health Connect
// (Android). Coordinates never cross into JS while recording; the map below
// draws them natively (MapKit / Google Maps).

export type RunPermission = "granted" | "denied" | "undetermined";
export type RunActivity = "running" | "walking" | "cycling" | "hiking";
export type RunState = "idle" | "running" | "paused" | "ended";
// "off" = indoor, or GPS not running. "none" = outdoor but no fresh fix.
export type GpsSignal = "off" | "none" | "weak" | "fair" | "good";

export type RunMetrics = {
  state: RunState;
  distanceM: number;
  gps: GpsSignal;
  /** True when this run is being recorded into Apple Health / Health Connect. */
  health: boolean;
  /** Moving time (excludes pauses). iOS: from the Health builder, absent without Health. Android: always. */
  elapsedS?: number;
  /** Rolling ~20 s pace; absent while standing or without GPS. */
  paceSecPerKm?: number;
  /**
   * Live heart rate while recording, absent when nothing fresh is heard.
   * Sources: a paired Bluetooth strap (both platforms, ~1 Hz), else on iOS
   * heart-rate samples reaching HealthKit during the run (an Apple Watch
   * running a workout; they land in batches, so up to ~45 s old).
   */
  heartRateBpm?: number;
  heartRateSource?: "strap" | "health";
};

export type RunSummary = RunMetrics & {
  healthWorkoutId: string | null;
  /** Simplified route, one Google-encoded polyline (precision 5) per segment between pauses. */
  route: string[];
  /** Time on the move, pauses excluded. */
  movingS: number;
  /**
   * The light series for charts and splits, one sample per ~5 s of moving
   * time: t = moving seconds, d = meters, alt = meters or null when GPS
   * altitude wasn't trustworthy. Same length arrays. hr = bpm at each
   * sample (null where none was fresh), present only when a heart rate was
   * heard at all.
   */
  samples: { t: number[]; d: number[]; alt: (number | null)[]; hr?: (number | null)[] };
  /** Over the moving time; absent without any heart-rate reading. */
  avgHeartRateBpm?: number;
  maxHeartRateBpm?: number;
};

export type HeartRateMonitorInfo = {
  /** False on a device without Bluetooth LE, or an iOS app without the plugin's usage string. */
  supported: boolean;
  /** "denied" is iOS only (Settings undoes it); Android asks again at the next scan. */
  permission: RunPermission;
  /** The paired strap, if any. id is opaque (a UUID on iOS, an address on Android). */
  monitor?: { id: string; name: string };
};

export type HeartRateMonitorState = {
  bluetooth: "on" | "off" | "unauthorized" | "unsupported" | "unknown";
  connection: "disconnected" | "connecting" | "connected";
  scanning: boolean;
  /** The paired strap's live reading, while the pairing screen holds it. */
  bpm?: number;
};

type RunRecorderEvents = {
  onRunUpdate: (metrics: RunMetrics) => void;
  onRunState: (event: { state: RunState }) => void;
  onHeartRateMonitors: (event: { monitors: { id: string; name: string }[] }) => void;
  onHeartRateMonitorState: (state: HeartRateMonitorState) => void;
};

declare class ExpoRunRecorderModule extends NativeModule<RunRecorderEvents> {
  getLocationPermission(): Promise<RunPermission>;
  /** Asks for When In Use only; background updates come from the location background mode. */
  requestLocationPermission(): Promise<RunPermission>;
  canWriteHealth(): boolean;
  /** iOS: "denied" means the athlete refused; only the Health app can undo it. Android never says denied: Health Connect's sheet can be shown again. */
  getHealthWritePermission(): RunPermission;
  /** One Health sheet: write workout + route + distance + energy, plus the import read set. */
  requestHealthWritePermission(): Promise<boolean>;
  /**
   * GPS on ahead of Start (no recording), like Strava's record screen:
   * onRunUpdate reports `gps` so the page can say when it's ready, and
   * start() seeds the route with the warm fix. Needs location already
   * granted (never prompts). Switches itself off after 5 minutes.
   * Absent on binaries built before it existed.
   */
  warmUp?(): Promise<void>;
  /** Leaving the page without starting. Never stops a recording. */
  coolDown?(): Promise<void>;
  start(activity: RunActivity, outdoor: boolean): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  /** GPS off, clock frozen, nothing saved yet. For the finish screen's Save/Discard. */
  stop(): Promise<void>;
  /** Saves to Health (stopping first if needed) and returns totals + route. Idempotent. */
  finish(): Promise<RunSummary>;
  discard(): Promise<void>;
  snapshot(): Promise<RunMetrics>;
  // Bluetooth heart-rate straps. Absent on binaries built before them.
  // Once paired, the recorder connects the strap itself from warm-up to
  // stop; nothing else is needed for heartRateBpm to flow.
  getHeartRateMonitor?(): HeartRateMonitorInfo;
  /** Lists nearby straps (onHeartRateMonitors) for ~20 s; asks for Bluetooth the first time. Also connects the paired one so the screen can show its bpm. */
  scanHeartRateMonitors?(): Promise<void>;
  /** The pairing screen closed: stop scanning and let the strap go unless a run holds it. */
  stopHeartRateMonitorScan?(): Promise<void>;
  /** Remembers a strap from the scan; false if it's no longer known. */
  pairHeartRateMonitor?(id: string): Promise<boolean>;
  forgetHeartRateMonitor?(): Promise<void>;
}

// Optional, never a throwing require: this file loads with the package
// index, and a binary built before the recorder existed must still boot
// (apps ship this JS over the air to older binaries). null = unavailable.
export const RunRecorder =
  requireOptionalNativeModule<ExpoRunRecorderModule>("ExpoRunRecorder");

export type RunMapViewProps = {
  /** Draw the recorder's live track (no coordinates passed from JS). */
  live?: boolean;
  /** Live only: camera follows the runner. A pan turns it off via onFollowChange. */
  followUser?: boolean;
  /** Static only: encoded polylines, e.g. RunSummary.route or a saved route. */
  route?: string[];
  /**
   * Live only: metres across the map's narrow side while following
   * (default 400, clamped 100 to 20000). Reapplied when following resumes.
   */
  spanMeters?: number;
  /** Hex, e.g. "#E5484D". */
  lineColor?: string;
  onFollowChange?: (event: { nativeEvent: { following: boolean } }) => void;
  style?: StyleProp<ViewStyle>;
};

// Resolved on first render, not at import, for the same reason as above.
// Only render it when RunRecorder is non-null.
let NativeRunMapView: React.ComponentType<RunMapViewProps> | null = null;

export function RunMapView(props: RunMapViewProps) {
  NativeRunMapView ??= requireNativeView<RunMapViewProps>("ExpoRunRecorder");
  return React.createElement(NativeRunMapView, props);
}
