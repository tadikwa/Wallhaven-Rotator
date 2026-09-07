# Security

## Supported releases

Only the latest public release is supported.

## Design

Wallhaven Rotator:

- runs in the current user's session;
- requires no administrator privileges;
- installs no Windows service or driver;
- does not inject code into other processes;
- does not alter Windows security policy;
- stores files only in the user's local application-data directory;
- uses the public SFW Wallhaven API for its core function.

The setup is a native Windows x64 executable compiled with the official Go toolchain. It is not packed or obfuscated.

## Updates

Wallhaven Rotator checks public GitHub Releases only when update checks are enabled.

Silent installation is opt-in and is restricted to the exact release asset name:

`WallhavenRotator-Setup-vX.Y.Z.exe`

Before execution, the application requires a matching entry in the release's `SHA256SUMS.txt` and verifies the downloaded file with SHA-256.

If the asset/checksum is missing or the digest does not match, the installer is not executed automatically.

SHA-256 verifies download integrity. It is not a third-party code-signing trust chain; the update trust source is the project's GitHub repository and GitHub Releases.

## Reporting

Please use the repository's GitHub Issues for non-sensitive bugs.

For a security issue that should not be public immediately, contact the project maintainer through the contact information on the maintainer's GitHub profile.
