# Security policy

## Supported versions

Security fixes are applied to the latest version on the `main` branch.

## Reporting a vulnerability

Please do not publish exploitable details in a public issue. Use GitHub's private
security advisory flow for this repository and include:

- the affected version or commit;
- a minimal proof of concept;
- expected and observed behavior; and
- any suggested mitigation.

LumaWall treats imported projects as untrusted data. It rejects Windows application
projects, bounds-checks scene packages and textures, and preflights ZIP paths and declared
sizes before extraction. Web wallpapers do execute local JavaScript inside WebKit. Their
file read access is restricted to the project directory and external navigation is
blocked, but web resource requests may still use the network.

SteamCMD is launched with `Process` arguments rather than through a shell. Passwords and
Steam Guard codes are sent only to the running process over standard input and are never
stored or logged. The Steam Web API key is stored in the user's Keychain. Reports involving
credential handling, archive extraction, WebKit isolation, or malformed PKG/TEX data are
especially useful.

Workshop API requests use a nonpersistent URL session with response caching disabled.
Local preview images are bounded by encoded size, dimensions, and pixel count before decode.
