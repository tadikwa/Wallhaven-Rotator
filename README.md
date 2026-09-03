# Wallhaven Rotator

Wallhaven Rotator is a small Windows wallpaper rotator using the public **SFW**
Wallhaven API. The public version history starts at **1.0.0**.

> This project is not affiliated with or endorsed by Wallhaven.

## Features

- Trending / Popular / New / Random selections
- General / Anime / People / All categories
- Resolution-aware searches
- Configurable rotation interval
- Manual wallpaper change and pause/resume
- System tray UI
- Persistent history of the last 1,000 wallpaper IDs
- Multi-page selection to reduce repeats
- Cache limited to **50 files and 500 MiB**
- Rotating logs
- User-level autostart
- No Windows service and no UAC prompt
- One-file native Windows x64 setup with install/update/uninstall detection

The application only requests SFW results (`purity=100`).

## Download

Use the latest file named:

`WallhavenRotator-Setup-vX.Y.Z.exe`

from the [GitHub Releases](../../releases/latest) page.

The first public 1.0.0 release is published unsigned so that the project exists
in the exact executable form required for the SignPath Foundation application.
After approval, the signed installer is added to the release.

## Requirements

- Windows 10 or Windows 11 x64
- Windows PowerShell 5.1 or newer
- Internet access to Wallhaven

## Build

The setup is compiled with the official Go toolchain. It is not packed,
obfuscated, or produced by converting the PowerShell runtime into an executable.

```powershell
./scripts/Build.ps1
```

The GitHub Actions release pipeline builds the downloadable installer directly
from the public repository.

## Privacy

Wallhaven Rotator contacts Wallhaven only for its wallpaper functionality.
There is no project telemetry, analytics account, or tracking endpoint.

See [PRIVACY.md](PRIVACY.md).

## Security

See [SECURITY.md](SECURITY.md).

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate
by [SignPath Foundation](https://signpath.org/) after project approval.

See [CODE_SIGNING.md](CODE_SIGNING.md).

## License

MIT. See [LICENSE](LICENSE).
