# Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate
by [SignPath Foundation](https://signpath.org/).

## Team roles

This is currently a single-maintainer project.

- **Committer and reviewer:** [@tadikwa](https://github.com/tadikwa)
- **Signing approver:** [@tadikwa](https://github.com/tadikwa)

Changes from other contributors are expected to go through pull requests and
review before merge.

## Source and build policy

- Signed binaries are built from this public source repository.
- Release builds are produced by GitHub Actions.
- Local developer binaries are never submitted as release signing inputs.
- SignPath receives the GitHub Actions artifact ID so it can verify build origin.
- Every SignPath signing request requires manual approval by the signing
  approver.
- The signed executable's product/file metadata is constrained through the
  SignPath artifact configuration.

## Privacy policy

See [PRIVACY.md](PRIVACY.md).

Wallhaven Rotator does not transfer user information to systems operated by
this project. Network requests to Wallhaven are the explicit core function of
the application and are documented in the privacy policy.
