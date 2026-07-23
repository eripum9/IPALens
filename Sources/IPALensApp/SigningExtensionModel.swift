import AppKit
import Combine
import Foundation
import IPALensCore
import IPALensPluginKit
import UniformTypeIdentifiers

struct SigningExtensionXcodeRecommendation: Codable, Sendable, Hashable {
    let version: String
    let minimumMacOS: String
    let maximumMacOS: String
    let maximumDeviceOS: String
    let expectedDownloadBytes: Int64
    let expectedWorkingBytes: Int64
}

struct SigningExtensionXcode: Codable, Sendable, Hashable {
    let version: String
    let applicationPath: String
    let developerDirectory: String
    let firstLaunchComplete: Bool
    let maximumDeviceOS: String?
}

struct SigningExtensionIdentity: Codable, Sendable, Hashable, Identifiable {
    var id: String { hash }
    let hash: String
    let name: String
    let teamID: String?
}

struct SigningExtensionDevice: Codable, Sendable, Hashable, Identifiable {
    var id: String { identifier }
    let identifier: String
    let udid: String
    let name: String
    let model: String
    let operatingSystemVersion: String
    let developerModeEnabled: Bool
    let paired: Bool
    let transport: String
    let supportedByXcode: Bool
}

struct SigningExtensionEnvironment: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let macOSVersion: String
    let architecture: String
    let availableDiskBytes: Int64
    let xcode: SigningExtensionXcode?
    let recommendedXcode: SigningExtensionXcodeRecommendation?
    let identities: [SigningExtensionIdentity]
    let devices: [SigningExtensionDevice]
    let warnings: [String]
}

@MainActor
final class SigningExtensionModel: ObservableObject {
    @Published private(set) var isEligible = false
    @Published private(set) var installation: PluginInstallation?
    @Published private(set) var environment: SigningExtensionEnvironment?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstallingExtension = false
    @Published private(set) var extensionDownloadProgress: Double?
    @Published private(set) var isRunning = false
    @Published private(set) var operationTitle = ""
    @Published private(set) var console = ""
    @Published var selectedIdentityHash = ""
    @Published var selectedDeviceIDs: Set<String> = []
    @Published var installAfterSigning = true
    @Published var interactiveResponse = ""
    @Published var appleID = ""
    @Published var applePassword = ""
    @Published var showsXcodeInitialConfirmation = false
    @Published var xcodeInstallProposal: SigningExtensionXcodeRecommendation?
    @Published var showsXcodeCredentials = false
    @Published var errorMessage: String?

    private let manager = PluginManager.shared
    private var sourceURL: URL?
    private var activeSession: PluginComponentSession?
    private var pinnedPluginID: String?
    private var operationTask: Task<Void, Never>?
    private var configurationGeneration = UUID()

    deinit {
        operationTask?.cancel()
    }

    var selectedIdentity: SigningExtensionIdentity? {
        environment?.identities.first { $0.hash == selectedIdentityHash }
    }

    var canSign: Bool {
        isEligible && installation != nil && environment?.xcode != nil &&
            selectedIdentity?.teamID != nil && !selectedDeviceIDs.isEmpty && !isRunning
    }

    func configure(snapshot: PackageSnapshot?, sourceURL: URL?) {
        configurationGeneration = UUID()
        operationTask?.cancel()
        let eligible = snapshot?.platform == .iOS && snapshot?.sourceKind == .ipaArchive
        isEligible = eligible
        self.sourceURL = eligible ? sourceURL : nil
        guard eligible else {
            releasePinnedInstallation()
            installation = nil
            environment = nil
            return
        }
        reloadInstallationAndStatus()
    }

    func reloadInstallationAndStatus() {
        let generation = configurationGeneration
        isChecking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await manager.installedPlugin(id: PluginManager.signingPluginID)
                guard generation == configurationGeneration else { return }
                await replacePinnedInstallation(with: found)
                installation = found
                if found != nil { await refreshEnvironment() }
            } catch {
                guard generation == configurationGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == configurationGeneration { isChecking = false }
        }
    }

    func installExtension() {
        guard !isInstallingExtension else { return }
        isInstallingExtension = true
        extensionDownloadProgress = 0
        Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await manager.officialSource()
                let catalog = try await manager.fetchCatalog(from: source)
                guard let entry = catalog.payload.plugins.first(where: { $0.id == PluginManager.signingPluginID }) else {
                    throw PluginError.pluginNotFound
                }
                let installed = try await manager.install(
                    entry: entry,
                    from: source,
                    progress: { [weak self] progress in
                        Task { @MainActor in self?.extensionDownloadProgress = progress }
                    }
                )
                await replacePinnedInstallation(with: installed)
                installation = installed
                await refreshEnvironment()
            } catch is CancellationError {
                // The atomic installer leaves no partial extension active.
            } catch {
                errorMessage = error.localizedDescription
            }
            isInstallingExtension = false
            extensionDownloadProgress = nil
        }
    }

    func refreshEnvironment() async {
        guard let installation,
              let component = installation.manifest.resolvedComponents.first(where: { $0.role == .signingService }) else {
            return
        }
        isChecking = true
        do {
            let output = try await executeAndCollect(
                installation: installation,
                component: component,
                arguments: ["status"],
                title: "Checking signing environment",
                showConsole: false
            )
            let data = Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            let decoded = try JSONDecoder().decode(SigningExtensionEnvironment.self, from: data)
            environment = decoded
            reconcileSelections(with: decoded)
        } catch is CancellationError {
            // Closing the package cancels the check.
        } catch {
            errorMessage = error.localizedDescription
        }
        isChecking = false
    }

    func requestXcodeInstallation() {
        showsXcodeInitialConfirmation = true
    }

    func evaluateXcodeInstallation() {
        showsXcodeInitialConfirmation = false
        Task { [weak self] in
            guard let self else { return }
            await refreshEnvironment()
            guard environment?.xcode == nil else { return }
            guard let recommendation = environment?.recommendedXcode else {
                errorMessage = "Apple does not list a compatible Xcode version for this Mac."
                return
            }
            guard environment?.availableDiskBytes ?? 0 >= recommendation.expectedWorkingBytes else {
                errorMessage = "Xcode \(recommendation.version) needs approximately \(formatBytes(recommendation.expectedWorkingBytes)) of working space."
                return
            }
            xcodeInstallProposal = recommendation
        }
    }

    func approveXcodeDownload() {
        xcodeInstallProposal = nil
        showsXcodeCredentials = true
    }

    func installXcode() {
        guard let installation,
              let component = installation.manifest.resolvedComponents.first(where: { $0.role == .signingService }),
              let recommendation = environment?.recommendedXcode,
              !appleID.isEmpty, !applePassword.isEmpty else { return }
        let credentials = ["IPALENS_APPLE_ID": appleID, "IPALENS_APPLE_PASSWORD": applePassword]
        applePassword = ""
        showsXcodeCredentials = false
        startInteractiveOperation(
            installation: installation,
            component: component,
            arguments: ["install-xcode", "--version", recommendation.version],
            environment: credentials,
            title: "Installing Xcode \(recommendation.version)",
            refreshAfterCompletion: true
        )
    }

    func openXcode() {
        guard let path = environment?.xcode?.applicationPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func signPackage() {
        guard canSign, let sourceURL, let identity = selectedIdentity, let teamID = identity.teamID,
              let installation,
              let component = installation.manifest.resolvedComponents.first(where: { $0.role == .signingService }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.ipaPackage]
        panel.canCreateDirectories = true
        panel.message = "IPALens writes a new Personal Team-signed IPA and never modifies the source package."
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-personal-team.ipa"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        startInteractiveOperation(
            installation: installation,
            component: component,
            arguments: [
                "sign", "--input", sourceURL.path, "--output", outputURL.path,
                "--team", teamID, "--identity", identity.hash,
                "--devices", selectedDeviceIDs.sorted().joined(separator: ","),
                "--install", installAfterSigning ? "true" : "false"
            ],
            title: installAfterSigning ? "Signing and installing the IPA" : "Signing the IPA",
            refreshAfterCompletion: false
        )
    }

    func sendInteractiveResponse() {
        guard let session = activeSession, !interactiveResponse.isEmpty else { return }
        let response = interactiveResponse
        interactiveResponse = ""
        Task {
            do { try await session.write(response) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        if let activeSession {
            Task { await activeSession.cancel() }
        }
        activeSession = nil
        isRunning = false
    }

    func close() {
        configurationGeneration = UUID()
        cancelOperation()
        sourceURL = nil
        environment = nil
        installation = nil
        isEligible = false
        applePassword = ""
        releasePinnedInstallation()
    }

    private func startInteractiveOperation(
        installation: PluginInstallation,
        component: PluginComponentV1,
        arguments: [String],
        environment: [String: String] = [:],
        title: String,
        refreshAfterCompletion: Bool
    ) {
        operationTask?.cancel()
        console = ""
        operationTitle = title
        isRunning = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await executeAndCollect(
                    installation: installation,
                    component: component,
                    arguments: arguments,
                    environment: environment,
                    title: title,
                    showConsole: true
                )
                if refreshAfterCompletion { await refreshEnvironment() }
            } catch is CancellationError {
                // User cancellation is reflected by returning to the idle state.
            } catch {
                errorMessage = error.localizedDescription
            }
            activeSession = nil
            isRunning = false
        }
    }

    private func executeAndCollect(
        installation: PluginInstallation,
        component: PluginComponentV1,
        arguments: [String],
        environment: [String: String] = [:],
        title: String,
        showConsole: Bool
    ) async throws -> String {
        let session = try await PluginComponentSession.start(
            installation: installation,
            component: component,
            arguments: arguments,
            environment: environment
        )
        activeSession = session
        var result = ""
        while true {
            try Task.checkCancellation()
            let poll = try await session.poll()
            if !poll.data.isEmpty {
                let text = String(decoding: poll.data, as: UTF8.self)
                result += text
                if showConsole { console += text }
            }
            if poll.finished {
                if let errorMessage = poll.errorMessage {
                    throw NSError(domain: "IPALensSigningExtension", code: Int(poll.status), userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }
                guard poll.status == 0 else {
                    let detail = result.split(separator: "\n").last.map(String.init) ?? "The extension exited with status \(poll.status)."
                    throw NSError(domain: "IPALensSigningExtension", code: Int(poll.status), userInfo: [NSLocalizedDescriptionKey: detail])
                }
                return result
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func reconcileSelections(with status: SigningExtensionEnvironment) {
        if !status.identities.contains(where: { $0.hash == selectedIdentityHash }) {
            selectedIdentityHash = status.identities.first(where: { $0.teamID != nil })?.hash ?? ""
        }
        let available = Set(status.devices.filter { $0.paired && $0.developerModeEnabled && $0.supportedByXcode }.map(\.identifier))
        selectedDeviceIDs.formIntersection(available)
        if selectedDeviceIDs.isEmpty, let first = available.sorted().first { selectedDeviceIDs = [first] }
    }

    private func replacePinnedInstallation(with installation: PluginInstallation?) async {
        let newID = installation?.id
        guard newID != pinnedPluginID else { return }
        if let pinnedPluginID { await manager.endUsing(pluginID: pinnedPluginID) }
        if let newID { await manager.beginUsing(pluginID: newID) }
        pinnedPluginID = newID
    }

    private func releasePinnedInstallation() {
        guard let pluginID = pinnedPluginID else { return }
        pinnedPluginID = nil
        Task { await manager.endUsing(pluginID: pluginID) }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
