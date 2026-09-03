# Privacy policy

Wallhaven Rotator does not operate its own telemetry, analytics, advertising,
account, or tracking service.

The application connects to external services only for user-facing functionality:

- `wallhaven.cc` for the public wallpaper search API;
- Wallhaven image hosts returned by that API for wallpaper downloads;
- `api.github.com` / GitHub Releases to check whether a newer Wallhaven Rotator version exists when update checks are enabled;
- GitHub release asset hosts when the user requests an update or enables automatic signed updates.

The application stores settings, a wallpaper-ID history, cached images, and
logs locally under the current user's `%LOCALAPPDATA%` profile.

No local history, cache contents, settings, or logs are uploaded by the
Wallhaven Rotator project. Update checks send only a normal HTTPS request for the
public latest-release metadata; the project does not run its own update or analytics server.

Wallhaven is a third-party service and its own terms/privacy policy apply to
requests made to its service.
