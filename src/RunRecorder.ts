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
// "off" = indoor, no GPS. "none" = outdoor but no fresh fix.
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
   * altitude wasn't trustworthy. Same length arrays.
   */
  samples: { t: number[]; d: number[]; alt: (number | null)[] };
};

type RunRecorderEvents = {
  onRunUpdate: (metrics: RunMetrics) => void;
  onRunState: (event: { state: RunState }) => void;
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
  start(activity: RunActivity, outdoor: boolean): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  /** GPS off, clock frozen, nothing saved yet. For the finish screen's Save/Discard. */
  stop(): Promise<void>;
  /** Saves to Health (stopping first if needed) and returns totals + route. Idempotent. */
  finish(): Promise<RunSummary>;
  discard(): Promise<void>;
  snapshot(): Promise<RunMetrics>;
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
