# Audibly fork memory

Use this file for dense facts that save a future agent from rediscovery, not as
an activity log.

## Architecture

- `Audibly.App/App.xaml.cs` is the composition root. It owns shared
  `MainViewModel` and `PlayerViewModel` instances.
- `MainViewModel` coordinates the library; `PlayerViewModel` owns MediaPlayer
  and playback state. `FileImportService` is the format/metadata boundary.
- `Audibly.Repository` persists models to SQLite. Cover and app-local file I/O
  belongs in `AppDataService`.
- Full orientation is in `docs/ARCHITECTURE.md`.

## Fork invariants

- No Sentry, analytics, telemetry, crash upload, updater, or vendor backend.
  `LoggingService` is local only.
- Packages use identity `dual1208.AudiblyFork`, publisher `CN=dual1208`, and the
  workstation certificate named `Codex Local App Package Signing`.
- The supported delivery path is a signed MSIX. Do not replace it with raw-exe
  copying: packaged Windows App SDK storage/activation contracts differ.
- `eng/windows-dev.ps1` is the source of truth for verify, build, package,
  install, update, smoke, local CI, and uninstall.

## Dependency decisions

- AutoMapper was removed rather than upgraded; chapter mapping is explicit in
  `FileImportService`.
- The unpublished MarqueeText dependency was removed; the title uses native
  TextBlock trimming and tooltip behavior.
- Markdown rendering uses the published Labs package version pinned in the
  project file.

## Format invariant

- `.m4b`, `.m4a`, and `.mp3` must remain aligned across both pickers, watched
  folders, package associations, and UI copy.
