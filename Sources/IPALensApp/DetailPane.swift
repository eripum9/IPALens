import AppKit
import IPALensCore
import SwiftUI

struct DetailPane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Group {
            switch model.selectedSection {
            case .files:
                FileDetail(model: model)
            case .overview:
                OverviewDetail(model: model)
            case .signing:
                SigningDetail(model: model)
            case .entitlements:
                EntitlementsDetail(model: model)
            case .privacy:
                PrivacyDetail(model: model)
            case .frameworks:
                EvidenceExplanation(
                    title: "Embedded Code",
                    symbol: "shippingbox",
                    message: "IPALens lists frameworks and standalone dynamic libraries exactly as they appear in the package. Their presence alone does not establish intent or safety."
                )
            case .extensions:
                EvidenceExplanation(
                    title: "App Extensions",
                    symbol: "puzzlepiece.extension",
                    message: "App extensions are independent bundles stored under PlugIns. Select an extension to browse its files."
                )
            case .binary:
                BinaryDetail(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileDetail: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if let entry = model.selectedEntry {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.headline)
                        Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(action: model.copySelectedPath) { Image(systemName: "doc.on.doc") }
                        .help("Copy Package Path")
                    Button(action: model.exportSelectedEntry) { Image(systemName: "square.and.arrow.up") }
                        .disabled(entry.kind != .file)
                        .help("Export Selected File")
                }
                .padding(12)
                .background(.bar)
                Divider()
                PreviewView(
                    payload: model.preview,
                    isLoading: model.isPreviewLoading,
                    loadingMessage: model.previewLoadingMessage,
                    canLoadMoreText: model.canLoadMoreTextPreview,
                    hasReachedTextLimit: model.hasReachedExpandedTextPreviewLimit,
                    onLoadMoreText: model.loadMoreTextPreview
                )
                Divider()
                HStack(spacing: 16) {
                    Label(ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file), systemImage: "internaldrive")
                    if let hash = entry.sha256 {
                        Text("SHA-256 \(hash)").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
        } else {
            EmptyStateView(
                title: "Select a File or Folder",
                symbol: "doc.text.magnifyingglass",
                description: "Choose an item in the file browser to view its metadata and preview."
            )
        }
    }
}

private struct PreviewView: View {
    let payload: PreviewPayload?
    let isLoading: Bool
    let loadingMessage: String
    let canLoadMoreText: Bool
    let hasReachedTextLimit: Bool
    let onLoadMoreText: () -> Void

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView(message: loadingMessage, detail: "Previews load in the background. Select another item to cancel this preview.")
            } else {
                previewContent
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch payload {
            case nil:
                EmptyStateView(title: "Preview Unavailable", symbol: "eye.slash")
            case .directory(let directory):
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 60)).foregroundStyle(.secondary)
                    Text(directory.path).font(.title3)
                    Text("\(directory.childCount.formatted()) \(directory.childCount == 1 ? "item" : "items") · \(ByteCountFormatter.string(fromByteCount: directory.totalUncompressedSize, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
            case .plist(let value):
                ScrollView {
                    PlistValueView(name: "Root", value: value)
                        .padding()
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    if let nsImage = NSImage(data: image.data) {
                        Image(nsImage: nsImage).resizable().scaledToFit().padding()
                    } else {
                        EmptyStateView(
                            title: "Image Preview Unavailable",
                            symbol: "photo.badge.exclamationmark",
                            description: "macOS could not decode this image format."
                        )
                    }
                }
            case .audio(let audio):
                AudioPreviewView(preview: audio)
            case .video(let video):
                VideoPreviewView(preview: video)
            case .text(let text):
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Label(text.syntax, systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption.weight(.medium))
                        Spacer()
                        if text.isTruncated {
                            Label(
                                "Showing \(ByteCountFormatter.string(fromByteCount: text.displayedByteCount, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: text.totalByteCount, countStyle: .file))",
                                systemImage: "scissors"
                            )
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
                    Divider()
                    SourceCodePreviewView(text: text.text, syntax: text.syntax)
                    if text.isTruncated {
                        Divider()
                        if canLoadMoreText {
                            Button(action: onLoadMoreText) {
                                Label("View More", systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 9)
                            .background(.bar)
                        } else if hasReachedTextLimit {
                            Label(
                                "Interactive preview limit reached. Export the file to view the remainder.",
                                systemImage: "externaldrive"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(.bar)
                        }
                    }
                }
            case .machO(let summary):
                MachOPreview(summary: summary)
            case .provisioning(let profile):
                ProvisioningPreview(profile: profile)
            case .hex(let hex):
                ScrollView {
                    Text(formatHex(hex))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .unavailable(let reason):
                EmptyStateView(title: "Preview Unavailable", symbol: "eye.slash", description: reason)
        }
    }

    private func formatHex(_ preview: HexPreview) -> String {
        let bytes = [UInt8](preview.data)
        return stride(from: 0, to: bytes.count, by: 16).map { row in
            let rowBytes = Array(bytes[row..<min(row + 16, bytes.count)])
            let hex = rowBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = rowBytes.map { byte in
                byte >= 32 && byte < 127 ? String(UnicodeScalar(byte)) : "."
            }.joined()
            return String(format: "%08llx  %@  |%@|", preview.offset + Int64(row), hex, ascii)
        }.joined(separator: "\n")
    }
}

private struct PlistValueView: View {
    let name: String
    let value: PlistValue

    var body: some View {
        switch value {
        case .dictionary(let dictionary):
            DisclosureGroup("\(name) — Dictionary (\(dictionary.count))") {
                ForEach(dictionary.keys.sorted(), id: \.self) { key in
                    PlistValueView(name: key, value: dictionary[key]!).padding(.leading, 10)
                }
            }
        case .array(let array):
            DisclosureGroup("\(name) — Array (\(array.count))") {
                ForEach(Array(array.enumerated()), id: \.offset) { index, item in
                    PlistValueView(name: "Item \(index + 1)", value: item).padding(.leading, 10)
                }
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                Text(name).fontWeight(.medium)
                Spacer()
                Text(value.displayValue).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct MachOPreview: View {
    let summary: MachOSummary
    var body: some View {
        List {
            ForEach(summary.slices) { slice in
                Section(slice.architecture) {
                    LabeledContent("File type", value: slice.fileType)
                    LabeledContent("64-bit", value: slice.is64Bit ? "Yes" : "No")
                    LabeledContent("Encrypted", value: slice.isEncrypted.map { $0 ? "Yes" : "No" } ?? "Not declared")
                    LabeledContent("Code signature", value: slice.hasCodeSignature ? "Present" : "Absent")
                    DisclosureGroup("Linked libraries (\(slice.linkedLibraries.count))") {
                        ForEach(slice.linkedLibraries, id: \.self) { Text($0).font(.body.monospaced()).textSelection(.enabled) }
                    }
                    DisclosureGroup("Load commands (\(slice.loadCommands.count))") {
                        ForEach(Array(slice.loadCommands.enumerated()), id: \.offset) { _, value in Text(value).font(.body.monospaced()) }
                    }
                }
            }
        }
    }
}

private struct ProvisioningPreview: View {
    let profile: ProvisioningSummary
    var body: some View {
        Form {
            LabeledContent("Name", value: profile.name ?? "Unknown")
            LabeledContent("UUID", value: profile.uuid ?? "Unknown")
            LabeledContent("Distribution", value: profile.distributionKind)
            LabeledContent("Team identifiers", value: profile.teamIdentifiers.isEmpty ? "None declared" : profile.teamIdentifiers.joined(separator: ", "))
            LabeledContent("Application identifier", value: profile.applicationIdentifier ?? "Unknown")
            LabeledContent("Provisioned devices", value: String(profile.provisionedDeviceCount))
            LabeledContent("Created", value: profile.creationDate?.formatted() ?? "Unknown")
            LabeledContent("Expires", value: profile.expirationDate?.formatted() ?? "Unknown")
        }
        .formStyle(.grouped)
    }
}

private struct OverviewDetail: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let bundle = model.selectedBundle, let snapshot = model.snapshot {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: bundle.displayName)
                    LabeledContent("Bundle ID", value: bundle.bundleIdentifier ?? "Unknown")
                    LabeledContent("Version", value: bundle.version ?? "Unknown")
                    LabeledContent("Build", value: bundle.build ?? "Unknown")
                    LabeledContent(
                        snapshot.platform == .macOS ? "Minimum macOS" : "Minimum iOS",
                        value: bundle.minimumOSVersion ?? "Unknown"
                    )
                    LabeledContent("Executable", value: bundle.executableName ?? "Unknown")
                }
                Section("Package") {
                    LabeledContent("File", value: snapshot.sourceFileName)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: snapshot.sourceFileSize, countStyle: .file))
                    LabeledContent("Entries", value: snapshot.entries.count.formatted())
                    LabeledContent("SHA-256", value: snapshot.packageSHA256 ?? "Calculating…")
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyStateView(
                title: "No App Bundle Found",
                symbol: "app.dashed",
                description: "IPALens did not find a top-level app bundle, but the package files remain available to browse."
            )
        }
    }
}

private struct SigningDetail: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        SigningExtensionView(model: model.signingExtension)
    }
}

private struct EntitlementsDetail: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let values = model.selectedSigning?.entitlements.values, !values.isEmpty {
            ScrollView { PlistValueView(name: "Entitlements", value: .dictionary(values)).padding() }
        } else {
            EmptyStateView(
                title: "No Entitlements Found",
                symbol: "key.horizontal",
                description: "The selected app bundle does not expose readable code-signing entitlements."
            )
        }
    }
}

private struct PrivacyDetail: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let bundle = model.selectedBundle {
            Form {
                Section("App Transport Security") {
                    LabeledContent("Allows arbitrary network loads", value: bundle.appTransportSecurity.allowsArbitraryLoads ? "Yes" : "No")
                    LabeledContent("Allows arbitrary web-content loads", value: bundle.appTransportSecurity.allowsArbitraryLoadsInWebContent ? "Yes" : "No")
                    LabeledContent("Exception domains", value: bundle.appTransportSecurity.exceptionDomains.count.formatted())
                }
                Section("Declared privacy metadata") {
                    LabeledContent("Usage descriptions", value: bundle.permissions.count.formatted())
                    LabeledContent("Privacy manifests", value: bundle.privacyManifestPaths.count.formatted())
                    LabeledContent("URL schemes", value: bundle.urlSchemes.count.formatted())
                }
            }.formStyle(.grouped)
        } else {
            EmptyStateView(
                title: "No Privacy Information",
                symbol: "hand.raised",
                description: "Select an app bundle to review its declared permissions and privacy metadata."
            )
        }
    }
}

private struct BinaryDetail: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let summary = model.selectedBundle?.machO {
            MachOPreview(summary: summary)
        } else {
            EmptyStateView(
                title: "No Binary Information",
                symbol: "cpu",
                description: "IPALens could not locate or parse the selected app bundle’s executable."
            )
        }
    }
}

private struct EvidenceExplanation: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        EmptyStateView(title: title, symbol: symbol, description: message)
    }
}
