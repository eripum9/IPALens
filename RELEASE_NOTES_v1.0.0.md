# IPALens 1.0.0

The first stable IPALens release brings the complete native, read-only iOS package explorer to Intel and Apple Silicon Macs.

Highlights include the Finder-style package tree, persistent navigation state, fast metadata and filename results, content search, Xcode-style syntax-colored source previews, image/audio/video/M4A playback, structured signing and entitlement inspection, Mach-O summaries, Markdown/JSON reports, and hash-verified exports.

The new App Store-style plugin manager can install two official 1.0.0 plugins from the signed IPALens catalog:

- **macOS App Support** for `.app`, ZIP, DMG, and PKG inspection.
- **Signing & Device Support** for free Personal Team re-signing and optional USB installation of an open iOS IPA. It can evaluate this Mac and offer a compatible full Xcode download after showing the expected size. Xcode still owns Apple Account provisioning, certificates, and Personal Team setup.

Executable plugin components are accepted only from the pinned official catalog and are verified at the artifact and component levels. The signing extension is not bundled in either installer; install it from the Signing tab so the real catalog download and verification flow remains testable.

## Downloads

- `IPALens-1.0.0-Apple-Silicon.pkg` installs the native arm64 app in `/Applications`.
- `IPALens-1.0.0-Intel.pkg` installs the native x86_64 app in `/Applications`.

Choose the package matching the Mac. Both contain IPALens 1.0.0 build 5.

## Important installation note

The app is ad-hoc signed and the PKG installers are unsigned; this release is not notarized because the project does not use a paid Apple Developer ID. macOS may block the first open. If it does, approve IPALens under **System Settings > Privacy & Security** and open it again.

See [CHANGELOG.md](https://github.com/eripum9/IPALens/blob/v1.0.0/CHANGELOG.md) for the complete change list.
