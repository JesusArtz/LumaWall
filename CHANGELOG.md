# Changelog

All notable changes to LumaWall will be documented here.

## [Unreleased]

### Added

- Native Discover, Library, Playlists, Displays, and Settings navigation.
- Steam Workshop querying, search/filter/sort, item details, and creator metadata.
- SteamCMD discovery, interactive authentication/Steam Guard, download queue, progress,
  cancellation, validation, and managed import.
- Managed wallpaper storage, ZIP and Web-project import, pre-download Workshop favorites,
  recent items, and playlists.
- Shared renderer lifecycle for AVFoundation video, WebKit web content, Metal scenes, and previews.
- Stable per-display assignments, reconnect handling, restoration, and power/session/full-screen pause.
- Keychain-backed Steam Web API key storage and structured OSLog categories.
- Expanded parser, importer, storage, Workshop mapping, playlist, and Steam command tests.

### Changed

- Video rendering now uses an `AVPlayerLooper` per display with mute, volume, speed, and scaling.
- Scene compatibility is reported explicitly and uses a preview fallback when native preparation fails.
- New local imports are copied into app-owned storage; existing path-based metadata is migrated in place.

### Fixed

- Corrected SwiftUI selection tags so the main sidebar and playlist list respond to clicks.
- Prefer Valve’s `steamcmd.sh` launcher for macOS installations, detect `~/Steam`, and report
  captive-portal or blocked SteamCMD updates with an actionable network error.
- Preserve the current SteamCMD command-completion state through process cleanup so successful
  Workshop downloads proceed to validation and managed import.

### Security

- Added package/texture allocation bounds, pixel-length checks, duplicate-path rejection,
  project-root confinement, archive preflight, preview-image bounds, serialized managed
  mutations, and managed-delete confinement.
- Steam credentials are excluded from command arguments, persistent settings, and logs.
- Workshop API traffic uses a nonpersistent session with response caching disabled.
