<p align="center">
  <img src="SupportingFiles/AppIcon-1024.png" width="128" alt="IPALens app icon">
</p>

# IPALens

**Native IPA Package Explorer for macOS**

IPALens is a fast, offline, read-only browser for iOS `.ipa` packages. Explore the complete package hierarchy, preview common file formats, inspect app and signing metadata, and export reproducible reports—without uploading or executing package contents.

## v1.0.0

IPALens v1.0.0 is the first stable release of the package explorer.

- Finder-style package browsing with filename and optional content search
- Structured previews for property lists, images, text, audio, video, Mach-O binaries, and provisioning profiles
- App metadata, permissions, URL schemes, privacy manifests, frameworks, extensions, and dynamic libraries
- Code-signing, certificate, provisioning-profile, and entitlement inspection
- Markdown and versioned JSON reports
- Hash-verified export of individual package files
- Native Universal 2 support for Intel and Apple Silicon Macs

## Privacy and safety

IPALens treats every IPA as untrusted input.

- Works entirely offline with no accounts, uploads, telemetry, or AI services
- Opens source IPAs read-only and never executes package contents
- Blocks unsafe archive paths, duplicate normalized paths, and oversized archives
- Never follows or materializes symbolic links
- Reports observable evidence without making malware or safety claims

## Requirements

- macOS 13 or later
- Xcode 16 or later for development
- Intel or Apple Silicon Mac

## Build from source

Clone the repository and run the test suite:

```sh
swift test
```

Build an ad-hoc-signed Universal 2 app bundle:

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
```

The app will be written to `dist/IPALens.app`. To install the local build:

```sh
ditto dist/IPALens.app /Applications/IPALens.app
```

## Architecture

- `IPALensCore` contains archive validation, inspection, previews, search, reports, and reusable data models.
- `IPALens` is the native SwiftUI macOS interface.
- ZIP handling uses [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation).

## Roadmap

Trust Diff is planned for a future release. It will compare original and modified IPA snapshots using file hashes and semantic metadata while preserving IPALens’s evidence-only approach.

Editing, injection, re-signing, IPA downloading, installation, decompilation, dynamic analysis, and malware verdicts remain outside the core explorer’s scope.

## License

IPALens is available under the [MIT License](LICENSE).
