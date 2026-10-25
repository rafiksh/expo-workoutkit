import { NativeModule, requireNativeModule } from "expo";

import type {
  HealthAnchoredResult,
  HealthHeartRatePoint,
  HealthMetricId,
  HealthQuantitySample,
  HealthRoutePoint,
  HealthSleepSample,
  HealthWorkoutSample,
} from "./ExpoWorkoutkit.types";

declare class ExpoWorkoutkitModule extends NativeModule {
  // Health import: HealthKit on iOS, Health Connect on Android, one contract.
  /**
   * True on binaries whose anchored queries take a `from`/`to` window
   * (ISO strings, by start date: from inclusive, to exclusive). Undefined
   * on older ones, where passing the window throws.
   */
  readonly healthRangeQueries?: boolean;
  isHealthDataAvailable(): boolean;
  /** Presents the Health permission sheet for all read types the module uses. */
  requestHealthAuthorization(): Promise<boolean>;
  /** Android only: opens Health Connect's settings. Absent on iOS (use x-apple-health://). */
  openHealthSettings?(): boolean;
  queryWorkouts(
    anchor: string | null,
    limit: number,
    from?: string | null,
    to?: string | null,
  ): Promise<HealthAnchoredResult<HealthWorkoutSample>>;
  /** Recent-first page of workouts for browse UIs; pass the last item's startDate as `before` to page older. */
  listWorkouts(before: string | null, limit: number): Promise<HealthWorkoutSample[]>;
  /**
   * The GPS route of one imported workout, every fix, oldest first. Empty
   * for an indoor session or when the recording app kept its route. iOS
   * reads HealthKit's workout route series. Health Connect hands another
   * app's route over only with the athlete's consent for that session, a
   * system sheet: `allowConsent` lets this call show it (pass true from a
   * tap, never from a background sync); without it such a route reads as
   * empty. Ignored on iOS.
   */
  queryWorkoutRoute(uuid: string, allowConsent?: boolean): Promise<HealthRoutePoint[]>;
  /** Heart rate through one imported workout, oldest first; [] when none was recorded. */
  queryWorkoutHeartRate(uuid: string): Promise<HealthHeartRatePoint[]>;
  queryQuantitySamples(
    metric: HealthMetricId,
    anchor: string | null,
    limit: number,
    from?: string | null,
    to?: string | null,
  ): Promise<HealthAnchoredResult<HealthQuantitySample>>;
  querySleepSamples(
    anchor: string | null,
    limit: number,
    from?: string | null,
    to?: string | null,
  ): Promise<HealthAnchoredResult<HealthSleepSample>>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoWorkoutkitModule>("ExpoWorkoutkit");
