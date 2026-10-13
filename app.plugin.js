const {
  AndroidConfig,
  withAndroidManifest,
  withEntitlementsPlist,
  withInfoPlist,
  withXcodeProject,
} = require("@expo/config-plugins");

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

  // Android: the route map runs on Google Maps, which reads its key from
  // the app manifest. Permissions, the foreground service and the Health
  // Connect rationale activity ship in the module's own manifest and merge
  // on their own; only the key is app-specific. Without a key the map view
  // renders blank, nothing else is affected.
  if (options.googleMapsApiKey) {
    config = withAndroidManifest(config, (config) => {
      const app = AndroidConfig.Manifest.getMainApplicationOrThrow(config.modResults);
      AndroidConfig.Manifest.addMetaDataItemToMainApplication(
        app,
        "com.google.android.geo.API_KEY",
        options.googleMapsApiKey,
      );
      return config;
    });
  }

  return config;
};

module.exports = withExpoWorkoutkit;
