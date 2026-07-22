<p align="center">
  <img src="SupportingFiles/AppIcon-1024.png" width="128" alt="IPALens app icon">
</p>

# IPALens

**Native App Package Explorer for macOS**

IPALens is a fast, read-only browser for iOS `.ipa` packages. Its data-only plugin system can add platform layouts without loading third-party executable code. The first official plugin adds inspection of macOS `.app`, `.zip`, `.dmg`, and `.pkg` sources.

## v1.0.0

IPALens v1.0.0 is the first stable release of the package explorer.

- Finder-style package browsing with filename and optional content search
- Structured previews for property lists, images, text, audio, video, Mach-O binaries, and provisioning profiles
- App metadata, permissions, URL schemes, privacy manifests, frameworks, extensions, and dynamic libraries
- Code-signing, certificate, provisioning-profile, and entitlement inspection
- Markdown and versioned JSON reports
- Hash-verified export of individual package files
- Native Universal 2 support for Intel and Apple Silicon Macs
- Signed, data-only plugins with official, third-party, and local source controls
- Optional macOS App Support for app bundles, ZIP archives, disk images, and installer packages

## Privacy and safety

IPALens treats every package and plugin as untrusted input.

- Performs inspections locally with no accounts, uploads, telemetry, or AI services
- Connects only to approved plugin catalogs when the Plugins screen opens, you check manually, or you approve a required-plugin offer
- Installed plugins work offline and contain data only—no binaries or scripts
- Opens source packages read-only and never executes package contents or installer scripts
- Blocks unsafe archive paths, duplicate normalized paths, and oversized archives
- Never follows or materializes symbolic links
- Reports observable evidence without making malware or safety claims

## Plugins

iOS App Support is built in and cannot be removed. Official macOS App Support is distributed from the separate [IPALens-Plugins repository](https://github.com/eripum9/IPALens-Plugins) and is verified with an Ed25519 signature plus SHA-256 before atomic installation.

Third-party catalogs require an HTTPS URL and explicit key-fingerprint approval. Local unsigned plugins require a separate warning and confirmation. Neither is controlled or reviewed by the IPALens project.

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

IPALens does not require a paid Apple Developer Program membership. Project builds are ad-hoc signed. A downloaded build may require the user to approve its first launch in System Settings → Privacy & Security because it is not notarized by Apple.

## Architecture

- `IPALensCore` contains archive validation, inspection, previews, search, reports, and reusable data models.
- `IPALensPluginKit` contains signed catalog verification, plugin-package validation, trust management, and isolated installation.
- `IPALensContainerService` is a bundled, narrowly scoped XPC helper used only to mount and detach disk images. The host remains sandboxed; the helper never executes inspected content.
- `IPALens` is the native SwiftUI macOS interface.
- ZIP handling uses [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation).

## Roadmap

Trust Diff is planned for a future release. It will compare original and modified package snapshots using file hashes and semantic metadata while preserving IPALens’s evidence-only approach.

Editing, injection, re-signing, IPA downloading, installation, decompilation, dynamic analysis, and malware verdicts remain outside the core explorer’s scope.

## License

IPALens is available under the [MIT License](LICENSE).
