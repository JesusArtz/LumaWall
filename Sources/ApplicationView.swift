import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationRootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var steam: SteamCmdService
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $state.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle(ProductInfo.name)
            .safeAreaInset(edge: .bottom) {
                sidebarStatus
            }
        } detail: {
            Group {
                switch state.selectedSection ?? .library {
                case .discover: DiscoverView()
                case .library: LibraryView()
                case .playlists: PlaylistsView()
                case .displays: DisplaysView()
                case .settings: ProductSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 650)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: importDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 36))
                            Text("Drop to import")
                                .font(.title2.weight(.semibold))
                        }
                    }
                    .padding(22)
            }
        }
        .alert(item: issueBinding) { issue in
            if let action = issue.recoveryAction {
                return Alert(
                    title: Text(issue.title),
                    message: Text(issue.message),
                    primaryButton: .default(Text(action.title)) { perform(action) },
                    secondaryButton: .cancel { state.dismissIssue() }
                )
            }
            return Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK")) { state.dismissIssue() }
            )
        }
        .sheet(item: challengeBinding) { challenge in
            SteamAuthenticationView(challenge: challenge)
                .environmentObject(steam)
        }
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if player.isPlaying {
                HStack(spacing: 8) {
                    Image(systemName: player.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                        .foregroundStyle(player.isPaused ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.isPaused ? "Wallpapers paused" : "Wallpapers active")
                            .font(.caption.weight(.medium))
                        Text(player.currentItem?.name ?? "Multiple displays")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        player.togglePause()
                    } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Label("No active wallpaper", systemImage: "display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var issueBinding: Binding<AppIssue?> {
        Binding(get: { state.issue }, set: { if $0 == nil { state.dismissIssue() } })
    }

    private var challengeBinding: Binding<SteamAuthenticationChallenge?> {
        Binding(
            get: { steam.challenge },
            set: { value in
                if value == nil, let active = steam.challenge { steam.cancel(active.downloadID) }
            }
        )
    }

    private func perform(_ action: RecoveryAction) {
        if action == .retry {
            state.retryLastIssue()
            return
        }
        if action == .showFile {
            state.showRecoveryFile()
            state.dismissIssue()
            return
        }
        state.dismissIssue()
        switch action {
        case .locateSteamCMD: state.chooseSteamCMD()
        case .openSettings: state.selectedSection = .settings
        case .retry: break
        case .showFile: break
        case .openLibrary: state.selectedSection = .library
        }
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url = (value as? URL)
                    ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in state.importWallpaper(url, playImmediately: false) } }
            }
        }
        return accepted
    }
}

private struct SteamAuthenticationView: View {
    @EnvironmentObject private var steam: SteamCmdService
    @Environment(\.dismiss) private var dismiss
    let challenge: SteamAuthenticationChallenge
    @State private var response = ""
    @State private var errorMessage: String?
    @FocusState private var responseIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: challenge.kind == .password ? "lock.shield" : "checkmark.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(challenge.kind == .password ? "Sign in to Steam" : "Steam Guard")
                        .font(.title2.weight(.semibold))
                    Text(challenge.kind == .password
                         ? "SteamCMD requested your password for this sign-in."
                         : "Enter the current code requested by SteamCMD.")
                        .foregroundStyle(.secondary)
                }
            }

            if challenge.kind == .password {
                SecureField("Steam password", text: $response)
                    .textContentType(.password)
                    .focused($responseIsFocused)
                    .onSubmit(submit)
            } else {
                TextField("Steam Guard code", text: $response)
                    .focused($responseIsFocused)
                    .onSubmit(submit)
            }

            Text("The app sends this response directly to the running SteamCMD process. It is not saved or logged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    steam.cancel(challenge.downloadID)
                    dismiss()
                }
                Button("Continue", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(response.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { responseIsFocused = true }
    }

    private func submit() {
        do {
            if challenge.kind == .password { try steam.submitPassword(response) }
            else { try steam.submitSteamGuardCode(response) }
            response = ""
            dismiss()
        } catch {
            response = ""
            errorMessage = error.localizedDescription
        }
    }
}
