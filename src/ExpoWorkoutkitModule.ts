import { NativeModule, requireNativeModule } from "expo";

import type {
  HealthAnchoredResult,
  HealthMetricId,
  HealthQuantitySample,
  HealthSleepSample,
  HealthWorkoutSample,
} from "./ExpoWorkoutkit.types";

declare class ExpoWorkoutkitModule extends NativeModule {
  // HealthKit import (iOS only — gate calls on Platform.OS === "ios").
  isHealthDataAvailable(): boolean;
  /** Presents the HealthKit permission sheet for all read types the module uses. */
  requestHealthAuthorization(): Promise<boolean>;
  queryWorkouts(
    anchor: string | null,
    limit: number,
  ): Promise<HealthAnchoredResult<HealthWorkoutSample>>;
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
