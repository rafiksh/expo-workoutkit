import * as React from 'react';

import { ExpoWorkoutkitViewProps } from './ExpoWorkoutkit.types';

export default function ExpoWorkoutkitView(props: ExpoWorkoutkitViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
