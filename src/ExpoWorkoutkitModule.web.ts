import { registerWebModule, NativeModule } from 'expo';

import { ExpoWorkoutkitModuleEvents } from './ExpoWorkoutkit.types';

class ExpoWorkoutkitModule extends NativeModule<ExpoWorkoutkitModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ExpoWorkoutkitModule, 'ExpoWorkoutkitModule');
