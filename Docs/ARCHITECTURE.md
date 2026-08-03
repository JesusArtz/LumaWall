# Architecture

LumaWall is a small native macOS application with no third-party runtime dependencies.

```text
SwiftUI library + menu bar
            |
         AppState
            |
     WallpaperImporter
       /           \
AVFoundation    ScenePackage parser
 video loop       + WETexture decoder
       \           /
        WallpaperPlayer
              |
 Desktop-level NSWindow per display
        (AVPlayerLayer or Metal)
```

## Components

- `AppState` owns the library, selection, import flow, and login-item preference.
- `WallpaperImporter` inspects local videos, project folders, and `scene.pkg` files.
- `ScenePackage` and `WETexture` parse supported Wallpaper Engine scene resources.
- `SceneRenderer` renders compatible image scenes and effects directly with Metal.
- `WallpaperPlayer` creates desktop-level windows and coordinates playback across displays.

Imported files remain in their original location. LumaWall stores only lightweight
library metadata in `UserDefaults`; it does not upload wallpaper content or analytics.

