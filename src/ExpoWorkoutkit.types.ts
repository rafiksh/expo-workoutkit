import type { StyleProp, ViewStyle } from "react-native";

export type OnButtonPressEventPayload = {
  message: string;
};

// TypeScript types that match WorkoutKit exactly
// These types ensure JavaScript data can be directly converted to valid WorkoutPlan data

export type HKWorkoutActivityType =
  | "running"
  | "cycling"
  | "swimming"
  | "walking"
  | "golf"
  | "tennis"
  | "basketball"
  | "soccer"
  | "hockey"
  | "baseball"
  | "softball"
  | "volleyball"
  | "badminton"
  | "tableTennis"
  | "squash"
  | "racquetball"
  | "lacrosse"
  | "cricket"
  | "rugby"
  | "football"
  | "americanFootball"
  | "australianFootball"
  | "gymnastics"
  | "boxing"
  | "kickboxing"
  | "martialArts"
  | "pilates"
  | "yoga"
  | "dance"
  | "danceInspiredTraining"
  | "barre"
  | "coreTraining"
  | "flexibility"
  | "strengthTraining"
  | "traditionalStrengthTraining"
  | "functionalStrengthTraining"
  | "crossTraining"
  | "mixedCardio"
  | "handCycling"
  | "cardioDance"
  | "socialDance"
  | "cardioCooldown"
  | "cooldown"
  | "other";

export type HKWorkoutSessionLocationType = "indoor" | "outdoor" | "unknown";

export type HKWorkoutSwimmingLocationType = "pool" | "openWater" | "unknown";

// WorkoutGoal enum cases from WorkoutKit
export type WorkoutGoal =
  | { type: "open" }
  | { type: "time"; value: number; unit: "seconds" | "minutes" | "hours" }
  | {
      type: "distance";
      value: number;
      unit: "meters" | "kilometers" | "yards" | "miles" | "feet";
    }
  | {
      type: "energy";
      value: number;
      unit: "calories" | "kilocalories" | "joules" | "kilojoules";
    };

// WorkoutStep from WorkoutKit
export type WorkoutStep = {
  goal: WorkoutGoal;
  alert?: WorkoutAlert;
};

// WorkoutAlert from WorkoutKit: the target a step shows on the Watch and
// alerts against. min + max is a range; a single bound is a threshold
// (speed, power, cadence). Heart rate has no threshold alert, so an open
// end is closed at 40 or 220 bpm. Pace travels as speed: WorkoutKit has no
// pace alert, the Watch renders speed as pace for running. An alert the
// activity can't carry is dropped natively rather than failing the plan.
export type WorkoutAlert =
  | { type: "heartRate"; min?: number; max?: number }
  | { type: "heartRateZone"; zone: 1 | 2 | 3 | 4 | 5 }
  | {
      type: "speed";
      min?: number;
      max?: number;
      unit: "metersPerSecond" | "kilometersPerHour" | "milesPerHour";
      metric?: "current" | "average";
    }
  | { type: "power"; min?: number; max?: number }
  | { type: "powerZone"; zone: number }
  | { type: "cadence"; min?: number; max?: number };

// IntervalStep from WorkoutKit
export type IntervalStep = {
  purpose: "work" | "recovery";
  step: WorkoutStep;
};

// IntervalBlock from WorkoutKit
export type IntervalBlock = {
  steps: IntervalStep[];
  iterations: number;
};

// SingleGoalWorkout from WorkoutKit
export type SingleGoalWorkout = {
  activity: HKWorkoutActivityType;
  location: HKWorkoutSessionLocationType;
  swimmingLocation?: HKWorkoutSwimmingLocationType;
  goal: WorkoutGoal;
};

// PacerWorkout from WorkoutKit
export type PacerWorkout = {
  activity: HKWorkoutActivityType;
  location: HKWorkoutSessionLocationType;
  distance: {
    value: number;
    unit: "meters" | "kilometers" | "yards" | "miles" | "feet";
  };
  time: {
    value: number;
    unit: "seconds" | "minutes" | "hours";
  };
};

// CustomWorkout from WorkoutKit
export type CustomWorkout = {
  activity: HKWorkoutActivityType;
  location: HKWorkoutSessionLocationType;
  displayName?: string;
  warmup?: WorkoutStep;
  blocks: IntervalBlock[];
  cooldown?: WorkoutStep;
};

// WorkoutPlan enum from WorkoutKit
export type WorkoutPlan =
  | { type: "goal"; workout: SingleGoalWorkout }
  | { type: "pacer"; workout: PacerWorkout }
  | { type: "custom"; workout: CustomWorkout };

export type PreviewWorkoutButtonProps = {
  workoutPlan?: WorkoutPlan;
  label?: string;
  buttonColor?: string;
  textColor?: string;
  cornerRadius?: number;
  fontSize?: number;
  onButtonPress?: (event: { nativeEvent: OnButtonPressEventPayload }) => void;
  style?: StyleProp<ViewStyle>;
};

// --- HealthKit import (read side) ---

// A completed workout read from HealthKit. Values are pre-converted to
// canonical units (meters, seconds, kcal, bpm) on the native side.
export type HealthWorkoutSample = {
  uuid: string;
  /** Raw HKWorkoutActivityType value; map to your own sport taxonomy in JS. */
  activityTypeRaw: number;
  startDate: string;
  endDate: string;
  durationS: number;
  distanceM?: number;
  calories?: number;
  avgHr?: number;
  maxHr?: number;
  elevationGainM?: number;
  sourceName?: string;
  sourceBundleId?: string;
};

// One GPS fix of a workout's route as the recording app wrote it to Health:
// seconds since the workout started, position, altitude in metres when the
// fix had one, horizontal accuracy in metres.
export type HealthRoutePoint = {
  t: number;
  lat: number;
  lng: number;
  alt?: number;
  acc: number;
};

/** One heart-rate sample inside a workout: seconds since its start, beats per minute. */
export type HealthHeartRatePoint = {
  t: number;
  bpm: number;
};

/**
 * A lap, segment or activity the recording app marked inside a workout:
 * seconds since its start. "lap" and "segment" are HKWorkoutEvent .lap /
 * .segment (Health Connect laps / segments); "activity" is one of an iOS 16+
 * workout's activities (a step of a multi-activity or custom workout).
 * `distanceM` when the source kept one for it; `rest` when the source marked
 * the segment as rest or pause (Health Connect only).
 */
export type HealthWorkoutEvent = {
  kind: "lap" | "segment" | "activity";
  startS: number;
  endS: number;
  distanceM?: number;
  rest?: boolean;
};

// Wellness metric ids accepted by queryQuantitySamples, each returned in a
// fixed canonical unit: hrv → ms, resting_hr → bpm, weight → kg,
// vo2max → mL/(kg·min).
export type HealthMetricId = "hrv" | "resting_hr" | "weight" | "vo2max";

export type HealthQuantitySample = {
  uuid: string;
  value: number;
  measuredAt: string;
  sourceName?: string;
};

// HKCategoryValueSleepAnalysis raw values: 0 inBed, 1 asleepUnspecified,
// 2 awake, 3 asleepCore, 4 asleepDeep, 5 asleepREM.
export type HealthSleepSample = {
  uuid: string;
  value: number;
  startDate: string;
  endDate: string;
  sourceName?: string;
};

// One page of an incremental (anchored) query. Pass `anchor` back into the
// next call to only receive samples added since; a null input anchor reads
// from the beginning of history.
export type HealthAnchoredResult<T> = {
  anchor: string | null;
  samples: T[];
};
