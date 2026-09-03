# SignPath configuration

This folder contains the artifact configuration used by Wallhaven Rotator for
SignPath code signing.

The GitHub Actions signing workflow submits the unsigned setup artifact by its
GitHub Actions artifact ID so SignPath can verify the build origin.

After SignPath Foundation accepts the project, the repository owner configures
the required SignPath organization/project identifiers and API token in the
repository's GitHub Actions variables and secrets.

Signing requests remain subject to the approval policy configured for the
SignPath Foundation project.