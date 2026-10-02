# Fixture corpus (task 3)

Recorded from the **Counta Dev** build via the Streaming Spike Debug screen.

## Recording a fixture

1. Open Counta Dev → bug icon (dev builds only) → Streaming Spike Debug.
2. Enter the Deepgram API key and the target phrase. For a multi-phrase
   session put **one phrase per line** (up to five). All of them are sent to
   Deepgram, exactly as a real session sends them.
3. Set **Fixture name** and **True count** before you start. The true count is
   either one total (`100`) or one count per phrase in the order listed
   (`40, 38`). Per-phrase counts are what let the replay say *which* phrase is
   being missed.
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
| `multi_100`         | 100  | several phrases in one session       |

## Running the gate

```bash
flutter test test/fixtures/corpus_test.dart
```

Prints a recall / false-positive table and enforces the task 3.4 gate
(matcher recall >= 0.95 on `normal_*`). Skips cleanly when no fixtures exist.

A fixture is only held to the gate once it has **at least 100 transcribed
repetitions**; smaller ones show `info` in the gate column. A percentage over
a few dozen repetitions measures the recording, not the matcher — in
`normal_30` one garbled stretch of transcription is worth 7 points on its own.

A fixture recorded with several phrases gets one indented row per phrase
beneath its total. A phrase whose detections sit well below its `txed` is one
that is not being recognised.

Columns:

- `txed` — repetitions present in the final transcripts, estimated as the
  **median** count across the phrase's words (near-spellings included, so
  "anointing" counts for "annointing"). In a set, only the words no other
  phrase uses are counted. Sessions contain pauses, so this is usually below
  `true`. It is an estimate: a repetition garbled beyond recognition can still
  leave a word or two behind and be counted here.
- `recall` — detections / `true_count`. Informational only.
- `m.rec` — detections / `txed`. **This is the gated number**: it measures the
  matcher alone, not the recording.
- `txcov` — normalised final transcript tokens saved versus the tokens
  `true_count` implies. Well below 100% means pauses or upstream transcription
  loss, not a matcher problem.
