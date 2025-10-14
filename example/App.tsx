import { PreviewWorkoutButton } from "expo-workoutkit";
import { ScrollView, Text, View, Alert } from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";

export default function App() {
  const handleWorkoutPress = (workoutType: string, message: string) => {
    Alert.alert("Workout Started", `${workoutType}: ${message}`);
  };

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.title}>Expo WorkoutKit</Text>
          <Text style={styles.subtitle}>iOS WorkoutKit Integration</Text>
        </View>

        <ScrollView
          style={styles.scrollView}
          contentContainerStyle={styles.content}
        >
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Goal Workout</Text>
            <Text style={styles.sectionDescription}>
              30-minute running goal
            </Text>
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
              label="Start Goal Workout"
              buttonColor="#007AFF"
              textColor="#ffffff"
              cornerRadius={8}
              fontSize={16}
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Goal Workout", message)
              }
              style={styles.workoutButton}
            />
          </View>

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Pacer Workout</Text>
            <Text style={styles.sectionDescription}>5km in 30 minutes</Text>
            <PreviewWorkoutButton
              workoutPlan={{
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
              label="Start Pacer Workout"
              buttonColor="#34C759"
              textColor="#ffffff"
              cornerRadius={8}
              fontSize={16}
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Pacer Workout", message)
              }
              style={styles.workoutButton}
            />
          </View>

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Custom Workout</Text>
            <Text style={styles.sectionDescription}>
              Advanced interval training
            </Text>
            <PreviewWorkoutButton
              workoutPlan={{
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
              label="Start Custom Workout"
              buttonColor="#FF9500"
              textColor="#ffffff"
              cornerRadius={8}
              fontSize={16}
              onButtonPress={({ nativeEvent: { message } }) =>
                handleWorkoutPress("Custom Workout", message)
              }
              style={styles.workoutButton}
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
    backgroundColor: "#f5f5f7",
  },
  scrollView: {
    flex: 1,
  },
  content: {
    padding: 20,
  },
  header: {
    padding: 24,
    alignItems: "center" as const,
    backgroundColor: "#fff",
    borderBottomWidth: 1,
    borderBottomColor: "#e5e5e7",
  },
  title: {
    fontSize: 28,
    fontWeight: "600" as const,
    color: "#1d1d1f",
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 16,
    color: "#86868b",
  },
  section: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 20,
    marginBottom: 16,
    borderWidth: 1,
    borderColor: "#e5e5e7",
  },
  sectionTitle: {
    fontSize: 20,
    fontWeight: "600" as const,
    color: "#1d1d1f",
    marginBottom: 4,
  },
  sectionDescription: {
    fontSize: 15,
    color: "#86868b",
    marginBottom: 16,
  },
  workoutButton: {
    height: 48,
  },
};
