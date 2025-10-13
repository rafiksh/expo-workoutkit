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

// Props for the React Native view
export type WorkoutData = WorkoutPlan;

export type PreviewWorkoutButtonProps = {
  workoutData?: WorkoutData;
  label?: string;
  onButtonPress?: (event: { nativeEvent: OnButtonPressEventPayload }) => void;
  style?: StyleProp<ViewStyle>;
};
