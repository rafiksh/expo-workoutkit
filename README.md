# Expo WorkoutKit

A React Native module that provides seamless integration with iOS WorkoutKit, enabling powerful workout experiences in your Expo and React Native applications.

## Features

- 🏃‍♂️ **Goal Workouts** - Set time, distance, or energy-based workout goals
- ⚡ **Pacer Workouts** - Maintain consistent pace with distance and time targets
- 🔥 **Custom Workouts** - Create complex interval training with warmup, work blocks, and cooldown
- 📊 **Real-time Data** - Access live workout metrics and progress
- 🎯 **TypeScript Support** - Full type safety with comprehensive TypeScript definitions
- 📱 **iOS Native** - Direct integration with iOS WorkoutKit framework

## Installation

```bash
npm install expo-workoutkit
```

## Platform Support

- ✅ **iOS** - Full support with native WorkoutKit integration
- ❌ **Android** - Not supported (WorkoutKit is iOS-only)
- ❌ **Web** - Not supported

## Quick Start

### Basic Usage

```tsx
import { PreviewWorkoutButton } from 'expo-workoutkit';

export default function App() {
  return (
    <PreviewWorkoutButton
      workoutPlan={{
        type: "goal",
        workout: {
          activity: "running",
          location: "outdoor",
          goal: {
            type: "time",
            value: 30,
            unit: "minutes",
          },
        },
      }}
      onButtonPress={({ nativeEvent: { message } }) => {
        console.log('Workout button pressed:', message);
      }}
      style={{ height: 100 }}
    />
  );
}
```

## Workout Types

### 1. Goal Workout

Set a single goal for your workout:

```tsx
const goalWorkout = {
  type: "goal",
  workout: {
    activity: "running",
    location: "outdoor",
    goal: {
      type: "time",
      value: 30,
      unit: "minutes",
    },
  },
};
```

### 2. Pacer Workout

Maintain a consistent pace over distance and time:

```tsx
const pacerWorkout = {
  type: "pacer",
  workout: {
    activity: "running",
    location: "outdoor",
    distance: {
      value: 5,
      unit: "kilometers",
    },
    time: {
      value: 30,
      unit: "minutes",
    },
  },
};
```

### 3. Custom Workout

Create complex interval training with multiple phases:

```tsx
const customWorkout = {
  type: "custom",
  workout: {
    activity: "running",
    location: "outdoor",
    displayName: "Interval Training",
    warmup: {
      goal: {
        type: "time",
        value: 10,
        unit: "minutes",
      },
    },
    blocks: [
      {
        steps: [
          {
            purpose: "work",
            step: {
              goal: {
                type: "distance",
                value: 1,
                unit: "kilometers",
              },
            },
          },
          {
            purpose: "recovery",
            step: {
              goal: {
                type: "time",
                value: 2,
                unit: "minutes",
              },
            },
          },
        ],
        iterations: 5,
      },
    ],
    cooldown: {
      goal: {
        type: "time",
        value: 10,
        unit: "minutes",
      },
    },
  },
};
```

## Supported Activities

The module supports all HealthKit workout activity types:

- **Cardio**: `running`, `cycling`, `swimming`, `walking`
- **Sports**: `tennis`, `basketball`, `soccer`, `golf`, `hockey`
- **Fitness**: `yoga`, `pilates`, `strengthTraining`, `crossTraining`
- **Martial Arts**: `boxing`, `kickboxing`, `martialArts`
- **Dance**: `dance`, `cardioDance`, `socialDance`
- And many more...

## Goal Types

### Time Goals

```tsx
goal: {
  type: "time",
  value: 30,
  unit: "minutes", // "seconds" | "minutes" | "hours"
}
```

### Distance Goals

```tsx
goal: {
  type: "distance",
  value: 5,
  unit: "kilometers", // "meters" | "kilometers" | "yards" | "miles" | "feet"
}
```

### Energy Goals

```tsx
goal: {
  type: "energy",
  value: 500,
  unit: "calories", // "calories" | "kilocalories" | "joules" | "kilojoules"
}
```

### Open Goals

```tsx
goal: {
  type: "open"
}
```

## Props

### PreviewWorkoutButtonProps

| Prop | Type | Description |
|------|------|-------------|
| `workoutPlan` | `WorkoutPlan` | The workout configuration |
| `label` | `string` | Custom button text |
| `onButtonPress` | `(event: { nativeEvent: OnButtonPressEventPayload }) => void` | Callback when workout button is pressed |
| `style` | `StyleProp<ViewStyle>` | Custom styles for the view |

## TypeScript Support

The module provides comprehensive TypeScript definitions:

```tsx
import type { 
  WorkoutPlan, 
  HKWorkoutActivityType, 
  WorkoutGoal,
  PreviewWorkoutButtonProps 
} from 'expo-workoutkit';
```

## Example App

Check out the example app in the `example/` directory to see the module in action:

```bash
cd example
npm install
npx expo start
```

## Requirements

- iOS 17.0+ (WorkoutKit framework requirement)
- React Native 0.60+
- Expo SDK 50+

## Permissions

No additional permissions are required! The WorkoutKit framework handles all HealthKit permissions internally when users interact with the workout preview.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT

## Author

[Rafik](https://github.com/rafiksh) - [rafikshmoury@gmail.com](mailto:rafikshmoury@gmail.com)

## Repository

[GitHub Repository](https://github.com/rafiksh/expo-workoutkit)
