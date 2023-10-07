# Change Log
All notable changes to this project will be documented in this file.

## v0.1.1-alpha - yyyy-mm-dd

Elixir 1.13-1.15 support added.
Includes minor bugfixes, test fixes and documentation updates.

### Added
- Added GitHub Actions for automated testing.
- Made sure that `ProcessHub` is compatible with Elixir 1.13-1.15.

### Changed
- Updated `ProcessHub` documentation by adding a list of all available strategies.
- Removed unnecessary file .tool-version generated by asdf.

### Fixed
- README.md table of contents links fixed.
- Fixed `ProcessHub` await/1 function example code formatting.
- Fixed tests for elixir 1.15 & OTP 26
- Fixed test case which was failing in some cases due to async call being executed before.