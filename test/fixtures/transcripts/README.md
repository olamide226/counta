# Fixture corpus (task 3)

Recorded from the **Counta Dev** build via the Streaming Spike Debug screen.

## Recording a fixture

1. Open Counta Dev → bug icon (dev builds only) → Streaming Spike Debug.
2. Enter the Deepgram API key and the target phrase.
3. Set **Fixture name** and **True count** before you start.
4. Start Streaming, chant exactly the true count, Stop Streaming.
5. Tap the download icon. The file is written to the app's Documents
   directory as `<fixture name>.json`, already containing `true_count`.
6. Pull it off the device and drop it in this folder.

## Getting the file off an iPhone

Xcode → Window → Devices and Simulators → select the phone → Counta Dev →
gear icon → Download Container. The JSON is inside `AppData/Documents/`.

## Required corpus (task 3.1)

| fixture             | reps | conditions                          |
| ------------------- | ---- | ----------------------------------- |
| `normal_100`        | 100  | quiet room, conversational pace      |
| `rapid_100`         | 100  | as fast as you can articulate        |
| `whispered_100`     | 100  | whispered, quiet room                |
| `tv_background_100` | 100  | TV or podcast audible in background  |
| `traffic_100`       | 100  | outdoors near traffic                |
| `mixed_speech_50`   | 50   | phrase interleaved with other speech |

## Running the gate

```bash
flutter test test/fixtures/corpus_test.dart
```

Prints a recall / false-positive table and enforces the task 3.4 gate
(recall >= 0.95 on `normal_*`). Skips cleanly when no fixtures exist.
