import { NativeModule, requireNativeModule, requireNativeView } from "expo";
import * as React from "react";
import type { StyleProp, ViewStyle } from "react-native";

// iOS 17+ only. Records a cardio session on the iPhone: GPS distance, pace,
// route, and (with write access) an Apple Health workout. Coordinates never
// cross into JS while recording; the map below draws them natively.

export type RunPermission = "granted" | "denied" | "undetermined";
export type RunActivity = "running" | "walking" | "cycling" | "hiking";
export type RunState = "idle" | "running" | "paused" | "ended";
// "off" = indoor, no GPS. "none" = outdoor but no fresh fix.
export type GpsSignal = "off" | "none" | "weak" | "fair" | "good";

export type RunMetrics = {
  state: RunState;
  distanceM: number;
  gps: GpsSignal;
  /** True when this run is being recorded into Apple Health. */
  health: boolean;
  /** Moving time from the Health builder (excludes pauses); absent without Health. */
  elapsedS?: number;
  /** Rolling ~20 s pace; absent while standing or without GPS. */
  paceSecPerKm?: number;
};

export type RunSummary = RunMetrics & {
  healthWorkoutId: string | null;
  /** Simplified route, one Google-encoded polyline (precision 5) per segment between pauses. */
  route: string[];
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
  /** One Health sheet: write workout + route + distance + energy, plus the import read set. */
  requestHealthWritePermission(): Promise<boolean>;
  start(activity: RunActivity, outdoor: boolean): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  finish(): Promise<RunSummary>;
  discard(): Promise<void>;
  snapshot(): Promise<RunMetrics>;
}

export const RunRecorder = requireNativeModule<ExpoRunRecorderModule>("ExpoRunRecorder");

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

const NativeRunMapView: React.ComponentType<RunMapViewProps> =
  requireNativeView("ExpoRunRecorder");

export function RunMapView(props: RunMapViewProps) {
  return React.createElement(NativeRunMapView, props);
}
