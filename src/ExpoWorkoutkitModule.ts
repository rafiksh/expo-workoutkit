import { NativeModule, requireNativeModule } from "expo";

declare class ExpoWorkoutkitModule extends NativeModule {
  // Module is primarily used for the view component
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoWorkoutkitModule>("ExpoWorkoutkit");
