<p align="center">
  <img src="SupportingFiles/AppIcon-1024.png" width="128" alt="IPALens app icon">
</p>

# IPALens

**Native App Package Explorer for macOS**

IPALens is a fast, read-only browser for iOS `.ipa` packages. Its plugin system adds platform layouts and clearly disclosed optional capabilities. The first official platform plugin adds inspection of macOS `.app`, `.zip`, `.dmg`, and `.pkg` sources. The optional official Signing & Device Support extension adds free Apple Personal Team signing and USB installation only while an IPA is open.

## v1.0.0

IPALens v1.0.0 is the first stable release of the package explorer.

- Finder-style package browsing with filename and optional content search
- Structured previews for property lists, images, audio—including M4A—video, Mach-O binaries, and provisioning profiles
- Xcode-style, syntax-colored source previews across common programming, web, markup, data, shell, and configuration formats
- Progressive source expansion and a file tree that preserves its selection and expanded folders between inspection sections
- App metadata, permissions, URL schemes, privacy manifests, frameworks, extensions, and dynamic libraries
- Code-signing, certificate, provisioning-profile, and entitlement inspection
- Markdown and versioned JSON reports
- Hash-verified export of individual package files
- Native Universal 2 support for Intel and Apple Silicon Macs
- An App Store-style plugin manager with signed catalogs, README pages, generated permissions, updates, and removal
- Optional macOS App Support for app bundles, ZIP archives, disk images, and installer packages
- Optional Personal Team signing, compatible-Xcode setup, two-factor download prompts, and USB device installation for iOS IPAs

## Privacy and safety

IPALens treats every package and plugin as untrusted input.

- Performs package inspections locally with no uploads, telemetry, or AI services
- Connects only to approved plugin catalogs when the Plugins screen opens, you check manually, or you approve a required-plugin offer
- Data-only platform plugins work offline. Official executable extensions are separately allowlisted, signed, hash-verified, and launched only for an action the user starts
- Opens source packages read-only and never executes package contents or installer scripts
- Blocks unsafe archive paths, duplicate normalized paths, and oversized archives
- Never follows or materializes symbolic links
- Reports observable evidence without making malware or safety claims

## Plugins

iOS App Support is built in and cannot be removed. Official macOS App Support and Signing & Device Support are distributed from the separate [IPALens-Plugins repository](https://github.com/eripum9/IPALens-Plugins) and are verified with an Ed25519 signature plus SHA-256 before atomic installation.

Plugins appear in a dedicated App Store-style window with maker and provider details, a full README, and an IPALens-generated Permissions page. Plugin makers should follow [PLUGIN-AUTHORING.md](PLUGIN-AUTHORING.md), including the root `README.md` requirement. Older or local packages without a README display “No description was provided.”

Third-party catalogs require an HTTPS URL and explicit key-fingerprint approval. Local unsigned plugins require a separate warning and confirmation. Neither is controlled or reviewed by the IPALens project.

Third-party and local plugins remain data-only. Executable extension packages are accepted exclusively from the pinned, signed official catalog. Their executable paths, architectures, hashes, allowed system commands, and inferred permissions are validated before installation and checked again before launch.

Signing & Device Support requires full Xcode, an Apple Development identity created by Xcode, a free Personal Team, and a paired USB device with Developer Mode enabled. If Xcode is missing, the extension can evaluate compatibility and storage, disclose the expected download and working size, and—after two confirmations—download a compatible version from Apple. IPALens does not store the supplied download password. Apple account setup for provisioning remains in Xcode’s Apple Accounts settings.

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

To create the architecture-specific installer packages after building the app:

```sh
chmod +x scripts/build-installers.sh
scripts/build-installers.sh
```

The unsigned Apple Silicon and Intel packages are written to `dist/installers` and each installs its native IPALens build in `/Applications`.

IPALens does not require a paid Apple Developer Program membership. Project builds are ad-hoc signed. A downloaded build may require the user to approve its first launch in System Settings → Privacy & Security because it is not notarized by Apple.

## Architecture

- `IPALensCore` contains archive validation, inspection, previews, search, reports, and reusable data models.
- `IPALensPluginKit` contains signed catalog verification, plugin-package validation, trust management, and isolated installation.
- `IPALensContainerService` is a bundled, narrowly scoped XPC helper used for disk-image mounting and verified official extension processes. The host remains sandboxed; the helper never executes inspected package contents.
- `IPALens` is the native SwiftUI macOS interface.
- ZIP handling uses [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation).

## Roadmap

Trust Diff is planned for a future release. It will compare original and modified package snapshots using file hashes and semantic metadata while preserving IPALens’s evidence-only approach.

Editing, injection, IPA downloading, decompilation, dynamic analysis, and malware verdicts remain outside the core explorer’s scope. Re-signing and device installation are isolated in the optional official extension and are never enabled for macOS packages.

## License

IPALens is available under the [MIT License](LICENSE).
