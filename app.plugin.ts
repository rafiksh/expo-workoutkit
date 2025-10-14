import {
  ConfigPlugin,
  withInfoPlist,
  withXcodeProject,
} from "@expo/config-plugins";

interface ExpoWorkoutkitPluginOptions {
  forceIOS17?: boolean;
}

const withExpoWorkoutkit: ConfigPlugin<ExpoWorkoutkitPluginOptions> = (
  config,
  options = {}
) => {
  // Optional: Allow apps to force iOS 17.0+ if they want full WorkoutKit support
  // If not specified, the module will use runtime guards for iOS 15+ compatibility
  if (options.forceIOS17) {
    config = withXcodeProject(config, (config) => {
      const xcodeProject = config.modResults;
      xcodeProject.addBuildProperty("IPHONEOS_DEPLOYMENT_TARGET", "17.0");
      return config;
    });
  }

  // Add any required Info.plist entries if needed
  config = withInfoPlist(config, (config) => {
    // WorkoutKit doesn't require specific Info.plist entries
    // The module handles iOS version checking at runtime
    return config;
  });

  return config;
};

export default withExpoWorkoutkit;
