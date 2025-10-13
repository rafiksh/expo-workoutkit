import { requireNativeView } from "expo";
import * as React from "react";

import { PreviewWorkoutButtonProps } from "./ExpoWorkoutkit.types";

const NativeView: React.ComponentType<PreviewWorkoutButtonProps> =
  requireNativeView("ExpoWorkoutkit");

export default function PreviewWorkoutButton(props: PreviewWorkoutButtonProps) {
  return <NativeView {...props} />;
}
