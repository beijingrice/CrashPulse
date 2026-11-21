# CrashPulse agent guide

CrashPulse is a macOS menu bar app (SwiftUI + AppKit, macOS 14+) that records sustained CPU activity, names the app most likely responsible, and shows live CPU and CPU power per app. Everything lives in `CrashPulseP0/`. Read `CrashPulseP0/README.md` for the measurement rules and `handoff.md` for the current state of work.

The owner usually writes in Chinese. Reply in Chinese. Keep code, comments, commit messages and in-app copy in English.

## Build, test and verify

Run from `CrashPulseP0/`:

```sh
# Unit tests (both schemes share one test bundle)
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode test

# Release app that the owner runs day to day
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build

# Render every panel state to PNG, light and dark (Debug builds only)
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build
cp -R ~/Library/Application\ Support/CrashPulse /tmp/crashpulse-history-copy
.build/xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff \
  --render-ui .build/ui-review /tmp/crashpulse-history-copy
```

- The test target compiles the model sources directly. It does not include `MonitorViews.swift`, `CrashPulseApp.swift`, `HistoryCommand.swift` or `main.swift`, so code in model files must not call into them.
- Pass `--render-ui` a copy of the history directory. Reading a history directory can repair and rewrite it.
- To relaunch the owner's app, quit it gracefully so the journal flushes, then open the new build:
  `osascript -e 'tell application id "org.crashpulse.p0.off" to quit'`, then `open .build/xcode/Build/Products/Release/CrashPulseOff.app`. Never `kill -9` it.
- Report only what you ran. Say "tests pass" only after running them, and "looks right" only after looking at rendered screenshots.

## Working rules

- One agent edits this repository at a time. Check `git status` before you start and commit finished work with a clear message. Uncommitted changes from someone else stay in place unless the owner says otherwise.
- The history file in `~/Library/Application Support/CrashPulse/` is the owner's real data. Use `--history-dir` with a scratch directory for experiments.
- Do not add the Overview tab back. The owner removed it on purpose.

## UI design guide

The panel should read as a native macOS utility: quiet, precise and calm. It must not look like a web dashboard. The owner rejected an earlier version for looking amateur. The main causes were every row in a grey card, three boxed mini charts, no clear hierarchy, and text-heavy explanations.

### Principles

1. **Hierarchy before decoration.** Every piece of content belongs to one tier below. Size and weight carry priority first. Color comes second.
2. **Color means severity.** Red and orange appear only where something needs attention: the severity label, the event's trace, the row dot. Never use color for decoration.
3. **One memorable element per screen.** On event detail it is the CPU trace. Everything around it stays plain.
4. **Plain words.** Say what happened and what to do, from the user's point of view. Write "Kept the CPU at up to 254% for 4m 10s while you were using other apps", not field names or internal terms.
5. **Cut before adding.** If a line does not help someone decide what to do, remove it. New sections need a clear reason. Ask the owner first if you are unsure.

### Tokens

Use the `Pulse` enum in `CrashPulse/MonitorViews.swift`. Do not hard-code new sizes or colors.

| Token | Value | Use |
| --- | --- | --- |
| `Pulse.title` | 24 pt semibold | App name on event detail, once per screen |
| `Pulse.figure` | 20 pt semibold, monospaced digits | Key numbers: duration, peak CPU, energy, live CPU |
| `Pulse.body` | 13 pt regular | Summary sentence, advice, list text |
| `Pulse.bodyStrong` | 13 pt semibold | Row titles, section headings |
| `Pulse.detail` | 12 pt regular | Secondary rows, buttons, process names |
| `Pulse.caption` / `captionStrong` | 11 pt | Labels under figures, timestamps, day headers |
| `Pulse.severe` | system red | Happening now, busy in the background |
| `Pulse.signal` | system orange | Worth a look, warnings |
| `Pulse.watching` | system green | Status dot while monitoring |
| `Color.accentColor` | system accent | Neutral traces and bars |
| `Pulse.width` / `gutter` | 360 / 16 pt | Panel width and side padding |

Use semantic colors (`.primary`, `.secondary`, `.tertiary`, system colors). Check every change in light and dark.

### Event detail tiers

| Tier | Content | Style |
| --- | --- | --- |
| 1 | Which app, how serious | Severity label (`captionStrong`, severity color) above the app name (`title`) |
| 2 | What happened | Summary sentence (`body`), then the `PulseTrace` chart |
| 3 | How much, what to do | Three figures (`figure` value, `caption` label), then "What you can do" (`bodyStrong` + `body`) with an action button only when it helps, such as Open Live |
| 4 | Supporting detail | Processes involved with share bars, start and end time, Ignore button (`detail`/`caption`, secondary) |

`EventSeverity` and `EventStory` own all wording and severity mapping. Change copy there, not inline in views.

### Components to reuse

- `PanelChrome`: header, tabs, content and footer. Every panel screen goes through it.
- `EventRow` and `Sparkline`: list rows. `Sparkline` is a plain `Shape` because Charts is too heavy for long lists.
- `PulseTrace`: one continuous before, during and after chart. The app is a 2 pt severity-colored line, all apps a 1 pt grey line, and the event span a 7% tint. Keep it as one chart.
- `ShareBar`: thin capsule bar for shares and rankings.
- `PanelMessage`: empty, paused and error states, with an optional single action.

### Never do these

- A rounded grey card behind every row or section. Use spacing and hover highlights instead.
- Splitting the timeline into separate Before, During and After boxes.
- Meta strings joined with middle dots (`A · B · C`). Write a short phrase instead.
- All-caps or tracked-out labels, and labels above content that only restate it.
- Multiple accent colors on one screen, gradients, or shadows.
- Explanatory paragraphs in the panel. Put detail in `.help` tooltips or the README.
- Durations like "4 min, 10 sec" next to other figures. Use `PulseFormat.duration` ("4m 10s").

### Review loop for any UI change

1. Before writing code, sketch the screen as an ASCII wireframe and a tier table. Get the owner's agreement when the change is large.
2. Build Debug and run `--render-ui`. Open the PNGs and look at them yourself, in light and dark.
3. Check: no collisions or truncation, nothing clipped at the bottom, tier 1 readable at a glance, color used only for severity, empty and error states still make sense.
4. Fix what you see and render again. Show the owner the screenshots with what changed.
5. If you add a new state or screen, add a scene for it in `UIPreviewRenderer` (bottom of `MonitorViews.swift`) with realistic sample data in `PreviewData`.
