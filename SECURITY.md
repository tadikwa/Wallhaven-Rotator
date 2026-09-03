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

The setup is a native Windows x64 executable compiled with the official Go
toolchain. It is not packed or obfuscated.

## Reporting

Please use the repository's GitHub Issues for non-sensitive bugs.

For a security issue that should not be public immediately, contact the project
maintainer through the contact information on the maintainer's GitHub profile.
