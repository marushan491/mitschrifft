# Commands and configuration

## Commands

| Command | Purpose |
| --- | --- |
| `mitschrift` | Open the menu bar app. |
| `mitschrift watch` | Run the background service without the menu bar. |
| `mitschrift run [seconds]` | Start now. Ctrl+C ends the session and writes the note. |
| `mitschrift probe [seconds]` | Run a short transcription probe with console output. |
| `mitschrift micusers` | List apps currently using the microphone. |
| `mitschrift shot <app>` | Test window capture and OCR for an app. |
| `mitschrift status` | Show permissions, service state, and configuration. |
| `mitschrift config` | Display or create the configuration file. |
| `mitschrift recover` | Convert interrupted sessions into notes. |
| `mitschrift ask <jsonl> [question]` | Ask Codex about a partial session file. |
| `mitschrift speakers <audio-file>` | Test speaker separation on an existing audio file. |
| `mitschrift icons <directory>` | Export app icon sizes and menu bar state previews. |
| `mitschrift install` | Register the login service. |
| `mitschrift uninstall` | Remove the login service. |

Partial session files live in `~/Library/Application Support/mitschrift/partial`. The speaker test reads a supplied file; normal transcription does not save audio files.

## Configuration

Mitschrift reads `~/.config/mitschrift/config.json`. Missing fields use defaults from [`Config.swift`](../Sources/mitschrift/Config.swift). Relaunch the app after editing.

| Field | Default | Purpose |
| --- | --- | --- |
| `locale` | `de-DE` | Speech recognition language. |
| `vaultPath` | `~/Documents/Second Brain` | Root directory for saved notes and media. Set an absolute path in JSON. |
| `notesFolder` | `50 Resources/Transkripte` | Notes folder relative to the vault. |
| `startAfterSeconds` | `6` | Delay before automatic recording starts. |
| `stopAfterSeconds` | `25` | Delay after the trigger clears before recording stops. |
| `minimumSessionSeconds` | `45` | Shorter sessions are discarded. |
| `ignoreApps` | See `Config.swift` | Apps ignored by automatic detection. |
| `onlyApps` | `[]` | Restrict automatic triggers to this list when populated. |
| `neverTriggerApps` | `[]` | Additional app exclusions. |
| `meetingApps` | See `Config.swift` | Meeting apps that can trigger through output audio as well as microphone use. |
| `speakerMe` / `speakerOthers` | `Ich` / `Andere` | Speaker labels before individual voice separation. |
| `photoHotKey` | `cmd+shift+2` | Meeting-window capture shortcut. |
| `keepScreenshots` | `true` | Keep meeting screenshots alongside their OCR text. |
| `imagesFolder` | `50 Resources/Transkripte/Bilder` | Saved meeting images, relative to the vault. |
| `recordVideo` | `true` | Enable video capture capability. Clips start through their own control. |
| `videosFolder` | `50 Resources/Transkripte/Videos` | Saved clips, relative to the vault. |
| `videoFramesPerSecond` | `4` | Video frame rate. |
| `videoMaxWidth` | `1280` | Maximum video width in pixels. |

## Optional remote processing

| Field | Default | Purpose |
| --- | --- | --- |
| `structureEnabled` | `true` | Send transcript text to Ollama for cleanup. Disable it for transcription without remote cleanup. |
| `structureHost` | `zotac` | SSH host alias used by both cleanup and the assistant. Replace it for your installation. |
| `structureModel` | `qwen3.5:9b` | Ollama model on that host. |
| `structureContext` | `16384` | Ollama context size. |
| `structureTimeoutSeconds` | `300` | Timeout for a cleanup attempt. |
| `structureMaxTries` | `8` | Maximum cleanup attempts. |

Assistant executable paths, the Codex account, model, vault pointer, and analysis workspace are source-level settings. The [integration guide](integration.md) identifies each one.

## Recovery, screenshots, and speakers

Completed transcript segments are written immediately to JSONL recovery files. After an interrupted session, recovery writes the note and preserves completed video clips. Multiple clips in one meeting have distinct filenames and links.

The meeting screenshot shortcut captures the largest visible window among the configured meeting apps and detected apps. Local OCR adds its text to the note. `keepScreenshots = false` discards the image after processing; the OCR text remains.

The echo filter compares microphone text with system audio within four seconds. A segment with at least 60% matching word pairs is removed from the microphone track. Other segments keep residual phrases of at least three words. Recovery files retain raw text; filtering applies to notes, the live view, and assistant context.

FluidAudio 0.17.7 uses the LS-EEND `dihard2` model for up to ten voices in the other-participants track. The first run downloads the model into `~/Library/Application Support/FluidAudio`. If separation fails, the note retains the generic label. Voice numbers follow first appearance; a number is not evidence of a person's name.

[Back to the README](../README.md)
