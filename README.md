# Wallhaven Rotator

Wallhaven Rotator is a lightweight Windows wallpaper rotator using the public **SFW** Wallhaven API.
The public version history starts at **1.0.0**.

> This project is not affiliated with or endorsed by Wallhaven.

## Screenshot

![Wallhaven Rotator](assets/screenshots/wallhaven-rotator-ui.png)

## Features

- Trending / Popular / New / Random selections
- General / Anime / People / All categories
- Optional custom Wallhaven query
- Standard / Reduced / Strict metadata filtering (Content Filter Policy v5)
- Display-aware resolution and aspect-ratio filtering
  - automatic detection of the primary display
  - custom width / height
  - minimum (`atleast`) or exact (`resolutions`) matching
  - automatic or explicit ratios including 16:9, 16:10, 21:9, 32:9, 48:9, 4:3 and 5:4
- Configurable rotation interval
- Manual wallpaper change and pause/resume
- System tray UI
- Shared hard same-day anti-repeat with Wallhaven Screensaver
- Persistent rolling history of at least 5,000 Wallhaven IDs with display timestamps
- Multi-page selection to reduce repeats
- Cache limited to **50 files and 500 MiB**
- Rotating logs
- User-level autostart
- Update notifications from GitHub Releases
- Optional automatic OTA updates with mandatory SHA-256 verification
- No Windows service and no UAC prompt
- One-file native Windows x64 setup with install/update/uninstall detection

The application always requests SFW results (`purity=100`). Reduced and Strict add local decisions based on Wallhaven category/tag metadata. This is metadata filtering, not image recognition.

## Download

Use the latest file named:

`WallhavenRotator-Setup-vX.Y.Z.exe`

from the [GitHub Releases](../../releases/latest) page.

Each public release also contains `SHA256SUMS.txt`.

## Requirements

- Windows 10 or Windows 11 x64
- Windows PowerShell 5.1 or newer
- Internet access to Wallhaven

## Build

The setup is compiled with the official Go toolchain. It is not packed, obfuscated, or produced by converting the PowerShell runtime into an executable.

```powershell
./scripts/Build.ps1
```

The GitHub Actions pipeline builds the downloadable installer directly from the public repository and runs regression tests under Windows PowerShell 5.1.

## Updates

Wallhaven Rotator can check the repository's latest stable GitHub Release. Update checks do not add project telemetry.

Automatic installation is opt-in. Before executing an update, the application requires:

1. the canonical setup asset `WallhavenRotator-Setup-vX.Y.Z.exe`;
2. a `SHA256SUMS.txt` entry for that exact filename;
3. an exact SHA-256 match after download.

If the setup or checksum is missing, or the hash does not match, Wallhaven Rotator does not execute the installer and offers the GitHub Release page instead.

The SHA-256 check protects against corrupted or mismatched downloads. The trust source for updates remains the project's GitHub repository and Releases.

## Filtering and anti-repeat

See [FILTERING_AND_HISTORY.md](FILTERING_AND_HISTORY.md).

## Privacy

Wallhaven Rotator contacts Wallhaven for wallpaper functionality and GitHub Releases for optional update checks. Reduced/Strict also request Wallhaven wallpaper-detail metadata. There is no project telemetry, analytics account, advertising, or tracking endpoint.

See [PRIVACY.md](PRIVACY.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
