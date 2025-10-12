// Reexport the native module. On web, it will be resolved to ExpoWorkoutkitModule.web.ts
// and on native platforms to ExpoWorkoutkitModule.ts
export { default } from './ExpoWorkoutkitModule';
export { default as ExpoWorkoutkitView } from './ExpoWorkoutkitView';
export * from  './ExpoWorkoutkit.types';
