import { NativeModule, requireNativeModule } from 'expo';

import { ExpoWorkoutkitModuleEvents } from './ExpoWorkoutkit.types';

declare class ExpoWorkoutkitModule extends NativeModule<ExpoWorkoutkitModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoWorkoutkitModule>('ExpoWorkoutkit');
