# Contributing to LumaWall

Thanks for helping make live wallpapers better on macOS. Contributions of code,
documentation, compatibility research, and reproducible scene samples are welcome.

## Before you start

- Search existing issues before opening a new one.
- Use an issue to discuss large features or renderer changes first.
- Never commit copyrighted Wallpaper Engine Workshop assets. Create a minimal,
  redistributable fixture or provide reproduction instructions instead.

## Local development

LumaWall requires macOS 14 or newer and Apple Command Line Tools.

```sh
chmod +x Scripts/build_app.sh Scripts/run_tests.sh
Scripts/run_tests.sh
Scripts/build_app.sh
open build/LumaWall.app
```

The project deliberately avoids third-party runtime dependencies. Keep new
dependencies rare, justified, and compatible with a lightweight menu-bar app.

## Pull requests

1. Create a focused branch from `main`.
2. Add or update tests for parser and renderer behavior.
3. Run `Scripts/run_tests.sh` and `Scripts/build_app.sh`.
4. Explain user-visible behavior and performance impact in the pull request.

By contributing, you agree that your contribution is licensed under the MIT License.

