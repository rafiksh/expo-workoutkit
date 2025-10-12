import { requireNativeView } from 'expo';
import * as React from 'react';

import { ExpoWorkoutkitViewProps } from './ExpoWorkoutkit.types';

const NativeView: React.ComponentType<ExpoWorkoutkitViewProps> =
  requireNativeView('ExpoWorkoutkit');

export default function ExpoWorkoutkitView(props: ExpoWorkoutkitViewProps) {
  return <NativeView {...props} />;
}
