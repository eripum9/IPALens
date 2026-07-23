import SwiftUI

struct SigningExtensionView: View {
    @ObservedObject var model: SigningExtensionModel

    var body: some View {
        Group {
            if !model.isEligible {
                EmptyStateView(
                    title: "IPA Signing Only",
                    symbol: "iphone.and.arrow.forward",
                    description: "Personal Team signing is available only while an iOS IPA package is open. It is never enabled for macOS applications."
                )
            } else if model.installation == nil {
                missingExtension
            } else {
                installedExtension
            }
        }
        .alert("Install Full Xcode?", isPresented: $model.showsXcodeInitialConfirmation) {
            Button("Evaluate This Mac", action: model.evaluateXcodeInstallation)
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("The signing extension will inspect this Mac’s macOS version, architecture, available storage, and Apple’s compatibility rules before proposing an Xcode download.")
        }
        .alert("Download Compatible Xcode?", isPresented: Binding(
            get: { model.xcodeInstallProposal != nil },
            set: { if !$0 { model.xcodeInstallProposal = nil } }
        )) {
            Button("Continue", action: model.approveXcodeDownload)
            Button("Cancel", role: .cancel) { model.xcodeInstallProposal = nil }
        } message: {
            if let proposal = model.xcodeInstallProposal {
                Text("Xcode \(proposal.version) is the newest stable version supported by this Mac. Expected download: about \(formatSigningBytes(proposal.expectedDownloadBytes)). Temporary and installed working space: about \(formatSigningBytes(proposal.expectedWorkingBytes)). The download comes from Apple.")
            }
        }
        .sheet(isPresented: $model.showsXcodeCredentials) {
            XcodeDownloadCredentialsView(model: model)
        }
        .alert("Signing Extension Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "The signing extension could not complete the request.")
        }
    }

    private var missingExtension: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 58, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Personal Team Signing")
                .font(.title2.bold())
            Text("Install the official Signing & Device Support extension to re-sign this IPA with a free Apple Personal Team and optionally install it over USB.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if model.isInstallingExtension {
                ProgressView(value: model.extensionDownloadProgress ?? 0)
                    .frame(width: 260)
                Text("Downloading, verifying, and activating the extension")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Install Signing & Device Support", action: model.installExtension)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Label("This extension contains separately verified executable components and requests additional permissions.", systemImage: "exclamationmark.shield.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: 560)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installedExtension: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                xcodeSection
                accountSection
                deviceSection
                operationSection
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Personal Team Signing").font(.title2.bold())
                Text("Signing & Device Support \(model.installation?.manifest.version ?? "")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isChecking { ProgressView().controlSize(.small) }
            Button(action: { Task { await model.refreshEnvironment() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isChecking || model.isRunning)
        }
    }

    @ViewBuilder
    private var xcodeSection: some View {
        GroupBox("Xcode Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                if let xcode = model.environment?.xcode {
                    LabeledContent("Version", value: "Xcode \(xcode.version)")
                    LabeledContent("Location", value: xcode.applicationPath)
                    LabeledContent("Initial setup", value: xcode.firstLaunchComplete ? "Complete" : "Action required")
                    if !xcode.firstLaunchComplete || model.environment?.identities.isEmpty != false {
                        Label("Open Xcode once, finish first-launch setup, then sign in under Xcode > Settings > Apple Accounts.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Button("Open Xcode", action: model.openXcode)
                    }
                } else {
                    Label("Full Xcode is required for Personal Team provisioning and USB installation.", systemImage: "hammer")
                    if let recommendation = model.environment?.recommendedXcode {
                        Text("Newest compatible version: Xcode \(recommendation.version)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Install Xcode…", action: model.requestXcodeInstallation)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isChecking || model.isRunning)
                }
                if let environment = model.environment {
                    Text("macOS \(environment.macOSVersion) · \(environment.architecture) · \(formatSigningBytes(environment.availableDiskBytes)) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        GroupBox("Personal Team") {
            VStack(alignment: .leading, spacing: 10) {
                if model.environment?.identities.isEmpty != false {
                    Label("No Apple Development identities were found. Sign in and create one in Xcode.", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                } else {
                    Picker("Signing identity", selection: $model.selectedIdentityHash) {
                        ForEach(model.environment?.identities ?? []) { identity in
                            Text(identity.teamID.map { "\(identity.name) · \($0)" } ?? identity.name)
                                .tag(identity.hash)
                        }
                    }
                }
                Text("Xcode owns the Apple Account session and two-factor authentication. IPALens never asks for the account password during IPA signing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        GroupBox("USB Devices") {
            VStack(alignment: .leading, spacing: 10) {
                if model.environment?.devices.isEmpty != false {
                    Label("No paired iPhone or iPad is visible to Xcode.", systemImage: "cable.connector.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.environment?.devices ?? []) { device in
                        Toggle(isOn: Binding(
                            get: { model.selectedDeviceIDs.contains(device.identifier) },
                            set: { selected in
                                if selected { model.selectedDeviceIDs.insert(device.identifier) }
                                else { model.selectedDeviceIDs.remove(device.identifier) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.headline)
                                Text("\(device.model) · iOS \(device.operatingSystemVersion) · \(device.transport.capitalized)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !device.paired || !device.developerModeEnabled || !device.supportedByXcode {
                                    Text(deviceProblem(device))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!device.paired || !device.developerModeEnabled || !device.supportedByXcode)
                    }
                }
                Text("Free Personal Teams support up to three registered devices and profiles expire after seven days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var operationSection: some View {
        GroupBox("Sign and Install") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Install the signed app on selected devices", isOn: $model.installAfterSigning)
                Button(model.installAfterSigning ? "Sign & Install…" : "Sign IPA…", action: model.signPackage)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canSign)
                if model.isRunning || !model.console.isEmpty {
                    Divider()
                    HStack {
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Text(model.operationTitle).font(.headline)
                        Spacer()
                        if model.isRunning {
                            Button("Cancel", role: .cancel, action: model.cancelOperation)
                        }
                    }
                    ScrollView {
                        Text(model.console.isEmpty ? "Waiting for the extension…" : model.console)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                    .padding(8)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    if model.isRunning {
                        HStack {
                            SecureField("Apple verification code or installer response", text: $model.interactiveResponse)
                                .onSubmit(model.sendInteractiveResponse)
                            Button("Send", action: model.sendInteractiveResponse)
                                .disabled(model.interactiveResponse.isEmpty)
                        }
                        Text("This field is used only when the Apple Xcode downloader requests two-factor verification or another interactive response.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func deviceProblem(_ device: SigningExtensionDevice) -> String {
        if !device.paired { return "Pair and trust this device in Xcode Device Hub." }
        if !device.developerModeEnabled { return "Enable Developer Mode on this device." }
        if !device.supportedByXcode { return "This device OS is newer than the installed Xcode supports." }
        return "Device unavailable."
    }
}

private struct XcodeDownloadCredentialsView: View {
    @ObservedObject var model: SigningExtensionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple Developer Download").font(.title2.bold())
            Text("Apple requires an Apple Account to download compatible Xcode archives. The extension passes these credentials directly to its verified downloader, removes its temporary saved session afterward, and does not store them in IPALens settings.")
                .foregroundStyle(.secondary)
            TextField("Apple Account email", text: $model.appleID)
                .textContentType(.username)
            SecureField("Apple Account password", text: $model.applePassword)
                .textContentType(.password)
            Label("Two-factor prompts will continue securely in the Signing tab after the download starts.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.applePassword = ""; dismiss() }
                Button("Start Download", action: model.installXcode)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.appleID.isEmpty || model.applePassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private func formatSigningBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
