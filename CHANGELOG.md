# Changelog

## 1.0.0 — 2026-07-23

IPALens 1.0.0 is the first stable release of the native macOS package explorer.

### Explorer and previews

- Added progressive, read-only IPA indexing with a persistent Finder-style file tree, search, breadcrumbs, selection restoration, and hash-verified export.
- Added structured views for app metadata, signing, provisioning, entitlements, privacy manifests, permissions, frameworks, extensions, and Mach-O information.
- Added plist, image, audio—including M4A—video, paged hex, and syntax-colored source previews for common programming, web, markup, data, shell, and configuration formats.
- Added loading feedback and bounded previews for large packages and files.
- Added versioned JSON and Markdown reports.

### Plugins

- Added an App Store-style plugin manager with signed catalogs, immutable artifacts, README pages, generated permissions, progress rings, updates, removal, source trust, and atomic installation.
- Added the optional macOS App Support 1.0.0 platform plugin for direct `.app` bundles, ZIP archives, read-only DMGs, and inert PKG expansion.
- Added the optional Signing & Device Support 1.0.0 official extension for free Apple Personal Team provisioning, compatible-Xcode setup, signing, and USB installation of open iOS IPAs.
- Restricted executable plugins to the pinned official catalog and added artifact, component-path, architecture, SHA-256, and pre-launch verification.

### Safety and compatibility

- Added archive traversal, duplicate-path, symlink, entry-count, expanded-size, output-size, timeout, and temporary-session safeguards.
- Kept inspection evidence-based: IPALens does not execute inspected package contents or provide malware verdicts.
- Added Universal 2 host builds for macOS 13 and later, plus separate Apple Silicon and Intel installer packages.

### Distribution note

IPALens is ad-hoc signed and the installer packages are unsigned because this project does not use a paid Apple Developer ID. macOS may require explicit approval in System Settings > Privacy & Security on first launch.
