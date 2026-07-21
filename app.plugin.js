const { withEntitlementsPlist, withInfoPlist, withXcodeProject } = require("@expo/config-plugins");

const DEFAULT_HEALTH_SHARE_USAGE =
  "This app reads your workouts and health metrics from Apple Health to show them alongside your training plan.";

const withExpoWorkoutkit = (config, options = {}) => {
  // Optional: Allow apps to force iOS 17.0+ if they want full WorkoutKit support
  // If not specified, the module will use runtime guards for iOS 15+ compatibility
  if (options.forceIOS17) {
    config = withXcodeProject(config, (config) => {
      const xcodeProject = config.modResults;
      xcodeProject.addBuildProperty("IPHONEOS_DEPLOYMENT_TARGET", "17.0");
      return config;
    });
  }

  // HealthKit read access, needed by the workout/wellness import functions.
  // Apps that only use the WorkoutKit export side can opt out with
  // `healthKit: false`.
  if (options.healthKit !== false) {
    config = withEntitlementsPlist(config, (config) => {
      config.modResults["com.apple.developer.healthkit"] = true;
      return config;
    });
    config = withInfoPlist(config, (config) => {
      config.modResults.NSHealthShareUsageDescription =
        options.healthShareUsageDescription ?? DEFAULT_HEALTH_SHARE_USAGE;
      return config;
    });
  }

  return config;
};

module.exports = withExpoWorkoutkit;
