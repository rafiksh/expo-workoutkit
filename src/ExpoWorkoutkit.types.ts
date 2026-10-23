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

// WorkoutAlert from WorkoutKit
export type WorkoutAlert = {
  type: "speed" | "heartRate" | "power" | "cadence" | "pace";
  target: {
    min: number;
    max: number;
    unit: string;
  };
  metric: "current" | "average" | "maximum";
};

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
