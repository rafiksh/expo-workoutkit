import { NativeModule, requireNativeModule } from "expo";

import type {
  HealthAnchoredResult,
  HealthMetricId,
  HealthQuantitySample,
  HealthSleepSample,
  HealthWorkoutSample,
} from "./ExpoWorkoutkit.types";

declare class ExpoWorkoutkitModule extends NativeModule {
  // Health import: HealthKit on iOS, Health Connect on Android, one contract.
  isHealthDataAvailable(): boolean;
  /** Presents the Health permission sheet for all read types the module uses. */
  requestHealthAuthorization(): Promise<boolean>;
  /** Android only: opens Health Connect's settings. Absent on iOS (use x-apple-health://). */
  openHealthSettings?(): boolean;
  queryWorkouts(
    anchor: string | null,
    limit: number,
  ): Promise<HealthAnchoredResult<HealthWorkoutSample>>;
  /** Recent-first page of workouts for browse UIs; pass the last item's startDate as `before` to page older. */
  listWorkouts(before: string | null, limit: number): Promise<HealthWorkoutSample[]>;
  queryQuantitySamples(
    metric: HealthMetricId,
    anchor: string | null,
    limit: number,
  ): Promise<HealthAnchoredResult<HealthQuantitySample>>;
  querySleepSamples(
    anchor: string | null,
    limit: number,
  ): Promise<HealthAnchoredResult<HealthSleepSample>>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoWorkoutkitModule>("ExpoWorkoutkit");
