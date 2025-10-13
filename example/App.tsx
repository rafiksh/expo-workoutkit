import { ExpoWorkoutkitView } from "expo-workoutkit";
import { ScrollView, Text, View, Alert } from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
export default function App() {
  const handleWorkoutPress = (workoutType: string, message: string) => {
    Alert.alert("Workout Selected! 🏃‍♂️", `${workoutType}: ${message}`);
  };

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.title}>🏃‍♂️ Expo WorkoutKit</Text>
          <Text style={styles.subtitle}>iOS WorkoutKit Integration Demo</Text>
        </View>
        <ScrollView style={styles.scrollView}>
          <View style={[styles.section, styles.goalSection]}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionIcon}>🎯</Text>
              <Text style={styles.sectionTitle}>Goal Workout</Text>
            </View>
            <Text style={styles.sectionDescription}>
              30-minute running goal
            </Text>
            <ExpoWorkoutkitView
              workoutData={{
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
              label="🎯 Start Goal Workout"
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Goal Workout", message)
              }
              style={styles.workoutView}
            />
          </View>

          <View style={[styles.section, styles.pacerSection]}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionIcon}>⚡</Text>
              <Text style={styles.sectionTitle}>Pacer Workout</Text>
            </View>
            <Text style={styles.sectionDescription}>5km in 30 minutes</Text>
            <ExpoWorkoutkitView
              workoutData={{
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
              }}
              label="⚡ Start Pacer Workout"
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Pacer Workout", message)
              }
              style={styles.workoutView}
            />
          </View>

          <View style={[styles.section, styles.customSection]}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionIcon}>🔥</Text>
              <Text style={styles.sectionTitle}>Custom Workout</Text>
            </View>
            <Text style={styles.sectionDescription}>
              Advanced interval training
            </Text>
            <ExpoWorkoutkitView
              workoutData={{
                type: "custom",
                workout: {
                  activity: "running",
                  location: "outdoor",
                  displayName: "Custom Running Workout",
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
                          purpose: "recovery",
                          step: {
                            goal: {
                              type: "distance",
                              value: 2,
                              unit: "kilometers",
                            },
                          },
                        },
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
                      ],
                      iterations: 3,
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
              }}
              label="🔥 Start Custom Workout"
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Custom Workout", message)
              }
              style={styles.workoutView}
            />
          </View>
        </ScrollView>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = {
  container: {
    flex: 1,
    backgroundColor: "#1f2937",
  },
  scrollView: {
    flex: 1,
    backgroundColor: "#fff",
  },
  header: {
    padding: 30,
    paddingTop: 20,
    alignItems: "center" as const,
  },
  title: {
    fontSize: 32,
    fontWeight: "bold" as const,
    color: "#fff",
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 16,
    color: "rgba(255, 255, 255, 0.9)",
    textAlign: "center" as const,
  },
  section: {
    margin: 20,
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 24,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.1,
    shadowRadius: 8,
    elevation: 4,
  },
  goalSection: {
    borderLeftWidth: 4,
    borderLeftColor: "#06b6d4",
    backgroundColor: "#f0f9ff",
  },
  pacerSection: {
    borderLeftWidth: 4,
    borderLeftColor: "#f97316",
    backgroundColor: "#fff7ed",
  },
  customSection: {
    borderLeftWidth: 4,
    borderLeftColor: "#ec4899",
    backgroundColor: "#fdf2f8",
  },
  sectionHeader: {
    flexDirection: "row" as const,
    alignItems: "center" as const,
    marginBottom: 8,
  },
  sectionIcon: {
    fontSize: 24,
    marginRight: 12,
  },
  sectionTitle: {
    fontSize: 22,
    fontWeight: "bold" as const,
    color: "#1f2937",
  },
  sectionDescription: {
    fontSize: 16,
    color: "#6b7280",
    marginBottom: 20,
    marginLeft: 36,
  },
  workoutView: {
    height: 50,
  },
};
