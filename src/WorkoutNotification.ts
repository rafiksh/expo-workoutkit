import { NativeModule, requireOptionalNativeModule } from "expo";

// Android only. The ongoing notification + foreground service a workout
// owns: it keeps the JS timers alive with the screen off and shows the
// current step with Back / Pause / Next, the Android twin of an iOS Live
// Activity. Content mirrors the Live Activity's; anything the notification
// can't draw is simply ignored.

export type WorkoutNotificationContent = {
  stepName: string;
  purposeColorHex?: string | null;
  stepIndex: number;
  stepCount: number;
  /** Frozen display value while paused. */
  remainingS?: number | null;
  /** Epoch ms: a native countdown for timed steps. */
  stepEndDateMs?: number | null;
  /** Epoch ms: a native count-up for open steps. */
  stepStartDateMs?: number | null;
  isPaused: boolean;
  targetText?: string | null;
  setText?: string | null;
  nextLabel?: string | null;
};

export type WorkoutNotificationAction = "back" | "next" | "pause" | "resume";

type WorkoutNotificationEvents = {
  onWorkoutAction: (event: { type: WorkoutNotificationAction }) => void;
};

export type WorkoutNotificationStart = {
  workoutName: string;
  sport: string;
  content: WorkoutNotificationContent;
};

// The native side takes JSON strings: Expo's Kotlin argument converter
// rejects the nested object with null fields the content carries.
declare class ExpoWorkoutNotificationModule extends NativeModule<WorkoutNotificationEvents> {
  isSupported(): boolean;
  requestActivityRecognitionPermission(): Promise<"granted" | "denied">;
  startWorkoutActivity(json: string): Promise<void>;
  updateWorkoutActivity(json: string): Promise<void>;
  endWorkoutActivity(): Promise<void>;
}

const native = requireOptionalNativeModule<ExpoWorkoutNotificationModule>("ExpoWorkoutNotification");

export type WorkoutNotificationApi = {
  isSupported(): boolean;
  /**
   * Android 14+ only lets the service run under the "health" type for an
   * app holding a fitness permission; ask right before a session. Resolves
   * "granted" where the permission doesn't exist.
   */
  requestActivityRecognitionPermission(): Promise<"granted" | "denied">;
  startWorkoutActivity(input: WorkoutNotificationStart): Promise<void>;
  updateWorkoutActivity(content: WorkoutNotificationContent): Promise<void>;
  endWorkoutActivity(): Promise<void>;
  addListener<K extends keyof WorkoutNotificationEvents>(
    name: K,
    listener: WorkoutNotificationEvents[K],
  ): { remove: () => void };
};

// Optional: null on iOS and on binaries built before it existed.
export const WorkoutNotification: WorkoutNotificationApi | null = native
  ? {
      isSupported: () => native.isSupported(),
      requestActivityRecognitionPermission: () => native.requestActivityRecognitionPermission(),
      startWorkoutActivity: (input) => native.startWorkoutActivity(JSON.stringify(input)),
      updateWorkoutActivity: (content) => native.updateWorkoutActivity(JSON.stringify(content)),
      endWorkoutActivity: () => native.endWorkoutActivity(),
      addListener: (name, listener) => native.addListener(name, listener),
    }
  : null;
