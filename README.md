# Ears

A glassy floating HUD for macOS that live-transcribes meetings. Your microphone
("You") and the meeting's audio ("Them", routed through BlackHole) stream to
Deepgram nova-3 and appear as a live transcript. Built to survive hours-long
meetings.

## Requirements

- macOS 13+, Swift toolchain (Command Line Tools are enough — no Xcode needed)
- [BlackHole 2ch](https://existential.audio/blackhole/) virtual audio driver
- A [Deepgram](https://deepgram.com) API key (gear icon in the app, or export
  `DEEPGRAM_API_KEY` before launching)

## Run

```sh
make run     # builds, bundles build/Ears.app, signs it, and launches
```

Press **Start** before your meeting. The app switches your output to a
multi-output device (your speakers + BlackHole) so you still hear everything
while it captures; **Stop** restores your original output and saves the
transcript to `Documents/Ears/`.

## How it stays alive through long meetings

| Failure | Defense |
|---|---|
| Silence idles out the Deepgram socket | KeepAlive frame every 5 s |
| Wi-Fi blip / socket drop | Auto-reconnect with backoff; ~2 min audio ring buffer flushed on reconnect |
| AirPods connect / device change | Engine restarts on configuration-change notifications |
| User switches output device mid-meeting | Watchdog rebuilds the multi-output on the new device |
| Capture silently stalls | Watchdog restarts any engine with no buffers for 5 s |
| App quits/crashes mid-session | Output routing restored on quit; stale devices cleaned at next launch |

Deliberately **not** used: ScreenCaptureKit and Apple speech recognition.

## Layout

| Piece | Path | Role |
|---|---|---|
| `SessionController` | `Sources/Ears/Core/SessionController.swift` | Orchestration: captures + streams + watchdog |
| `CaptureEngine` | `Sources/Ears/Audio/CaptureEngine.swift` | Mic / BlackHole PCM capture, self-healing |
| `OutputRouter` | `Sources/Ears/Audio/OutputRouter.swift` | Multi-output device create/switch/restore |
| `DeepgramStream` | `Sources/Ears/Transcription/DeepgramStream.swift` | nova-3 WebSocket, keepalive, reconnect, buffering |
| `TranscriptStore` | `Sources/Ears/Transcription/TranscriptStore.swift` | Interim/final result folding, markdown export |
| `HUDView` | `Sources/Ears/Views/HUDView.swift` | Glassy HUD UI |
| `Shims` | `Sources/Shims/` | ObjC exception catcher for AVAudioEngine races |

## Notes

- While listening, macOS volume keys are disabled (a multi-output device has no
  master volume) — set your volume before starting.
- Logs: `~/Library/Logs/Ears.log`.
- If capture is ever silent despite permission being granted:
  `tccutil reset Microphone com.pavansai.ears`, then relaunch.
