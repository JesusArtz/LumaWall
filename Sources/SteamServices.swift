import Foundation

enum SteamCMDConfigurationError: LocalizedError, Equatable, Sendable {
    case executableMissing
    case invalidUsername
    case invalidWorkshopID
    case invalidInput
    case processFailed
    case updateFailed
    case authenticationFailed
    case guardFailed
    case accessDenied
    case downloadFailed
    case downloadMissing

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "SteamCMD was not found. Install it or choose its executable in Settings."
        case .invalidUsername:
            return "Enter the Steam account name that owns Wallpaper Engine in Settings."
        case .invalidWorkshopID:
            return "The Workshop item has an invalid identifier."
        case .invalidInput:
            return "The Steam credential response contains unsupported characters."
        case .processFailed:
            return "SteamCMD stopped before the wallpaper was downloaded."
        case .updateFailed:
            return "SteamCMD could not update because the network blocked or redirected Valve’s download. Complete any network sign-in or switch networks, then retry."
        case .authenticationFailed:
            return "Steam rejected the account name or password. Try signing in again."
        case .guardFailed:
            return "Steam Guard did not accept the code. Retry the download with a current code."
        case .accessDenied:
            return "Steam could not download this item. Confirm that this account owns Wallpaper Engine and can access the Workshop item."
        case .downloadFailed:
            return "SteamCMD could not download this Workshop item. Check the network connection and confirm that the signed-in account owns Wallpaper Engine and can access the item."
        case .downloadMissing:
            return "SteamCMD reported success, but the downloaded Workshop project could not be found."
        }
    }
}

enum SteamChallengeKind: String, Identifiable, Sendable {
    case password
    case steamGuard
    var id: String { rawValue }
}

struct SteamAuthenticationChallenge: Identifiable, Sendable {
    let downloadID: UUID
    let kind: SteamChallengeKind
    var id: String { "\(downloadID.uuidString)-\(kind.rawValue)" }
}

struct SteamCommandPlan: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let initialCommands: String

    static func make(
        executableURL: URL,
        installDirectory: URL,
        username: String
    ) throws -> SteamCommandPlan {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, trimmedUsername.utf8.count <= 128,
              !trimmedUsername.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SteamCMDConfigurationError.invalidUsername
        }
        let directory = try quote(installDirectory.path)
        let account = try quote(trimmedUsername)
        return SteamCommandPlan(
            executableURL: executableURL,
            arguments: ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "0"],
            initialCommands: "force_install_dir \(directory)\nlogin \(account)\n"
        )
    }

    static func workshopCommands(for publishedFileID: String) throws -> String {
        guard publishedFileID.isSteamPublishedFileID else {
            throw SteamCMDConfigurationError.invalidWorkshopID
        }
        return "workshop_download_item \(ProductInfo.wallpaperEngineAppID) \(publishedFileID) validate\nquit\n"
    }

    private static func quote(_ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SteamCMDConfigurationError.invalidInput
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum SteamCMDLocator {
    static func locate(customPath: String?) -> URL? {
        if let customPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            let custom = URL(fileURLWithPath: customPath)
            if let resolved = preferredExecutable(for: custom) { return resolved }
        }

        let homeSteam = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Steam", isDirectory: true)
        var candidates = [
            homeSteam.appendingPathComponent("steamcmd.sh").path,
            homeSteam.appendingPathComponent("steamcmd").path,
            "/opt/homebrew/bin/steamcmd",
            "/usr/local/bin/steamcmd",
            "/opt/homebrew/opt/steamcmd/bin/steamcmd",
            "/usr/local/opt/steamcmd/bin/steamcmd"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/steamcmd" })
        }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if let resolved = preferredExecutable(for: URL(fileURLWithPath: candidate)) { return resolved }
        }
        return nil
    }

    private static func preferredExecutable(for candidate: URL) -> URL? {
        let fileManager = FileManager.default
        if candidate.lastPathComponent == "steamcmd" {
            let launcher = candidate.deletingLastPathComponent().appendingPathComponent("steamcmd.sh")
            if fileManager.isExecutableFile(atPath: launcher.path) { return launcher }
        }
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}

@MainActor
final class SteamCmdService: ObservableObject {
    @Published private(set) var downloads: [WallpaperDownload] = []
    @Published private(set) var challenge: SteamAuthenticationChallenge?
    @Published private(set) var detectedExecutableURL: URL?

    var importHandler: ((WallpaperItem) -> Void)?
    var failureHandler: ((WallpaperDownload) -> Void)?

    private let settings: AppSettings
    private let storage: WallpaperStorage
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var activeDownloadID: UUID?
    private var downloadCommandSubmitted = false
    private var downloadReportedSuccess = false
    private var reportedDownloadPath: URL?
    private var outputBuffer = ""
    private var pendingTerminationStatus: Int32?
    private var outputReachedEOF = false
    private var cancelledIDs = Set<UUID>()
    private var isShuttingDown = false

    init(settings: AppSettings, storage: WallpaperStorage) {
        self.settings = settings
        self.storage = storage
        refreshExecutableLocation()
    }

    var isConfigured: Bool {
        detectedExecutableURL != nil && !settings.steamUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshExecutableLocation() {
        detectedExecutableURL = SteamCMDLocator.locate(customPath: settings.steamCMDPath)
        if let detectedExecutableURL, settings.steamCMDPath != detectedExecutableURL.path {
            settings.steamCMDPath = detectedExecutableURL.path
        }
    }

    func shutdown() {
        isShuttingDown = true
        if let activeDownloadID, let index = index(of: activeDownloadID), !downloads[index].state.isTerminal {
            cancelledIDs.insert(activeDownloadID)
            downloads[index].state = .cancelled
            downloads[index].statusText = "Cancelled because the application is quitting"
        }
        challenge = nil
        process?.terminate()
    }

    @discardableResult
    func enqueue(_ item: WorkshopItem) -> UUID {
        if let existing = downloads.first(where: {
            $0.workshopItem.id == item.id && !$0.state.isTerminal
        }) {
            return existing.id
        }
        let download = WallpaperDownload(workshopItem: item)
        downloads.insert(download, at: 0)
        startNextIfPossible()
        return download.id
    }

    func retry(_ downloadID: UUID) {
        guard let old = downloads.first(where: { $0.id == downloadID }), old.state.isTerminal else { return }
        _ = enqueue(old.workshopItem)
    }

    func cancel(_ downloadID: UUID) {
        guard let index = index(of: downloadID), downloads[index].state.canCancel else { return }
        cancelledIDs.insert(downloadID)
        downloads[index].state = .cancelled
        downloads[index].statusText = "Cancelled"
        downloads[index].errorMessage = nil
        if activeDownloadID == downloadID {
            challenge = nil
            process?.terminate()
        }
        startNextIfPossible()
    }

    func submitPassword(_ password: String) throws {
        guard let challenge, challenge.kind == .password,
              let index = index(of: challenge.downloadID) else { return }
        try validateSecretLine(password)
        try writeSecret(password)
        downloads[index].state = .authenticating
        downloads[index].statusText = "Signing in to Steam…"
        self.challenge = nil
        outputBuffer = ""
    }

    func submitSteamGuardCode(_ code: String) throws {
        guard let challenge, challenge.kind == .steamGuard,
              let index = index(of: challenge.downloadID) else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...10).contains(trimmed.count), trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw SteamCMDConfigurationError.invalidInput
        }
        try writeSecret(trimmed)
        downloads[index].state = .authenticating
        downloads[index].statusText = "Verifying Steam Guard…"
        self.challenge = nil
        outputBuffer = ""
    }

    nonisolated static func parseProgress(from output: String) -> Double? {
        let pattern = #"progress:\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let percentage = Double(output[range]) else { return nil }
        return min(max(percentage / 100, 0), 1)
    }

    nonisolated static func diagnosedFailure(from output: String) -> SteamCMDConfigurationError? {
        let lower = output.lowercased()
        if lower.contains("steamcmd needs to be online to update")
            || (lower.contains("<!doctype") && lower.contains("manifest")) {
            return .updateFailed
        }
        return nil
    }

    nonisolated static func completedSuccessfully(
        exitStatus: Int32,
        commandSubmitted: Bool,
        reportedSuccess: Bool
    ) -> Bool {
        exitStatus == 0 && commandSubmitted && reportedSuccess
    }

    private func startNextIfPossible() {
        guard !isShuttingDown, activeDownloadID == nil,
              let next = downloads.last(where: { $0.state == .queued }),
              let index = index(of: next.id) else { return }
        refreshExecutableLocation()
        guard let executable = detectedExecutableURL else {
            fail(next.id, error: SteamCMDConfigurationError.executableMissing)
            startNextIfPossible()
            return
        }
        do {
            try storage.prepareDirectories()
            let plan = try SteamCommandPlan.make(
                executableURL: executable,
                installDirectory: storage.steamDataURL,
                username: settings.steamUsername
            )
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = plan.executableURL
            process.arguments = plan.arguments
            process.currentDirectoryURL = storage.steamDataURL
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            activeDownloadID = next.id
            downloadCommandSubmitted = false
            downloadReportedSuccess = false
            reportedDownloadPath = nil
            outputBuffer = ""
            pendingTerminationStatus = nil
            outputReachedEOF = false
            cancelledIDs.remove(next.id)
            self.process = process
            inputPipe = input
            outputPipe = output
            downloads[index].state = .authenticating
            downloads[index].statusText = "Starting SteamCMD…"
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor [weak self] in
                    if data.isEmpty {
                        self?.markOutputEOF(for: next.id)
                    } else if let text = String(data: data, encoding: .utf8) {
                        self?.consume(text, for: next.id)
                    }
                }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor [weak self] in
                    self?.recordProcessTermination(status: process.terminationStatus, for: next.id)
                }
            }
            try process.run()
            try write(plan.initialCommands)
        } catch {
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true { self.process?.terminate() }
            cleanupProcess()
            fail(next.id, error: error)
            startNextIfPossible()
        }
    }

    private func consume(_ text: String, for id: UUID) {
        guard activeDownloadID == id, let index = index(of: id), !cancelledIDs.contains(id) else { return }
        outputBuffer += text
        if outputBuffer.count > 64_000 {
            outputBuffer = String(outputBuffer.suffix(32_000))
        }
        let lower = outputBuffer.lowercased()

        if let progress = Self.parseProgress(from: text) ?? Self.parseProgress(from: outputBuffer) {
            downloads[index].progress = progress
            downloads[index].state = .downloading
            downloads[index].statusText = "Downloading… \(Int(progress * 100))%"
        }
        if let path = Self.downloadPath(from: outputBuffer) { reportedDownloadPath = path }
        if lower.contains("success. downloaded item") { downloadReportedSuccess = true }

        if lower.contains("steamcmd needs to be online to update") {
            finishWithError(SteamCMDConfigurationError.updateFailed)
            return
        }

        if lower.contains("invalid password") || lower.contains("login failure") {
            finishWithError(SteamCMDConfigurationError.authenticationFailed)
            return
        }
        if lower.contains("invalid authenticator code") || lower.contains("two-factor code mismatch") {
            finishWithError(SteamCMDConfigurationError.guardFailed)
            return
        }
        if lower.contains("no subscription") || lower.contains("access denied") {
            finishWithError(SteamCMDConfigurationError.accessDenied)
            return
        }
        if lower.contains("download item") && (lower.contains("failed") || lower.contains("(failure)")) {
            finishWithError(SteamCMDConfigurationError.downloadFailed)
            return
        }
        if !downloadCommandSubmitted,
           lower.contains("password:"),
           challenge == nil {
            downloads[index].state = .awaitingPassword
            downloads[index].statusText = "Steam password required"
            challenge = SteamAuthenticationChallenge(downloadID: id, kind: .password)
            return
        }
        if !downloadCommandSubmitted,
           (lower.contains("steam guard") || lower.contains("two-factor")),
           (lower.contains("code") || lower.contains("authenticator")),
           challenge == nil {
            downloads[index].state = .awaitingSteamGuard
            downloads[index].statusText = "Steam Guard code required"
            challenge = SteamAuthenticationChallenge(downloadID: id, kind: .steamGuard)
            return
        }
        if !downloadCommandSubmitted,
           ((lower.contains("waiting for user info") && lower.contains("ok")) || lower.contains("logged in ok")) {
            do {
                downloadCommandSubmitted = true
                downloads[index].state = .downloading
                downloads[index].statusText = "Downloading from Steam Workshop…"
                try write(SteamCommandPlan.workshopCommands(for: downloads[index].workshopItem.publishedFileID))
                outputBuffer = ""
            } catch {
                finishWithError(error)
            }
        }
    }

    private func markOutputEOF(for id: UUID) {
        guard activeDownloadID == id else { return }
        outputReachedEOF = true
        finishProcessIfReady(for: id)
    }

    private func recordProcessTermination(status: Int32, for id: UUID) {
        guard activeDownloadID == id else { return }
        pendingTerminationStatus = status
        finishProcessIfReady(for: id)
    }

    private func finishProcessIfReady(for id: UUID) {
        guard activeDownloadID == id, outputReachedEOF, let status = pendingTerminationStatus else { return }
        pendingTerminationStatus = nil
        processEnded(status: status, downloadID: id)
    }

    private func processEnded(status: Int32, downloadID id: UUID) {
        guard activeDownloadID == id else { return }
        let wasCancelled = cancelledIDs.contains(id)
        let hadFailed = downloads.first(where: { $0.id == id })?.state == .failed
        let commandSubmitted = downloadCommandSubmitted
        let reportedSuccess = downloadReportedSuccess
        let item = downloads.first(where: { $0.id == id })?.workshopItem
        let diagnosedFailure = Self.diagnosedFailure(from: outputBuffer)
        cleanupProcess()
        if wasCancelled || hadFailed {
            cancelledIDs.remove(id)
            startNextIfPossible()
            return
        }
        guard Self.completedSuccessfully(
            exitStatus: status,
            commandSubmitted: commandSubmitted,
            reportedSuccess: reportedSuccess
        ), let item else {
            AppLog.steam.error(
                "SteamCMD completion rejected: status=\(status), commandSubmitted=\(commandSubmitted), successMarker=\(reportedSuccess)"
            )
            fail(id, error: diagnosedFailure ?? SteamCMDConfigurationError.processFailed)
            startNextIfPossible()
            return
        }
        guard let source = locateDownloadedItem(item.publishedFileID) else {
            fail(id, error: SteamCMDConfigurationError.downloadMissing)
            startNextIfPossible()
            return
        }
        if let index = index(of: id) {
            downloads[index].state = .validating
            downloads[index].progress = 1
            downloads[index].statusText = "Validating project…"
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let storage = self.storage
                if let index = self.index(of: id) {
                    self.downloads[index].state = .importing
                    self.downloads[index].statusText = "Adding to Library…"
                }
                let installed = try await Task.detached(priority: .userInitiated) {
                    try storage.installWorkshopProject(from: source, metadata: item)
                }.value
                guard let index = self.index(of: id) else { return }
                self.downloads[index].state = .completed
                self.downloads[index].statusText = "Downloaded"
                self.downloads[index].errorMessage = nil
                self.importHandler?(installed)
            } catch {
                self.fail(id, error: error)
            }
            self.startNextIfPossible()
        }
    }

    private func locateDownloadedItem(_ publishedFileID: String) -> URL? {
        var candidates: [URL] = []
        if let reportedDownloadPath { candidates.append(reportedDownloadPath) }
        candidates.append(
            storage.steamDataURL
                .appendingPathComponent("steamapps/workshop/content", isDirectory: true)
                .appendingPathComponent(ProductInfo.wallpaperEngineAppID, isDirectory: true)
                .appendingPathComponent(publishedFileID, isDirectory: true)
        )
        if let executable = detectedExecutableURL {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("steamapps/workshop/content", isDirectory: true)
                    .appendingPathComponent(ProductInfo.wallpaperEngineAppID, isDirectory: true)
                    .appendingPathComponent(publishedFileID, isDirectory: true)
            )
        }
        let standardSteam = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content", isDirectory: true)
            .appendingPathComponent(ProductInfo.wallpaperEngineAppID, isDirectory: true)
            .appendingPathComponent(publishedFileID, isDirectory: true)
        candidates.append(standardSteam)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func write(_ value: String) throws {
        guard let data = value.data(using: .utf8), let inputPipe else {
            throw SteamCMDConfigurationError.processFailed
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func writeSecret(_ value: String) throws {
        try write(value + "\n")
    }

    private func validateSecretLine(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SteamCMDConfigurationError.invalidInput
        }
    }

    private func finishWithError(_ error: Error) {
        guard let id = activeDownloadID else { return }
        fail(id, error: error)
        process?.terminate()
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = index(of: id), downloads[index].state != .cancelled else { return }
        downloads[index].state = .failed
        downloads[index].statusText = "Download failed"
        downloads[index].errorMessage = error.localizedDescription
        challenge = nil
        AppLog.steam.error("Steam task failed: \(error.localizedDescription, privacy: .public)")
        failureHandler?(downloads[index])
    }

    private func cleanupProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        activeDownloadID = nil
        challenge = nil
        downloadCommandSubmitted = false
        downloadReportedSuccess = false
        reportedDownloadPath = nil
        outputBuffer = ""
        pendingTerminationStatus = nil
        outputReachedEOF = false
    }

    private func index(of id: UUID) -> Int? { downloads.firstIndex { $0.id == id } }

    private static func downloadPath(from output: String) -> URL? {
        let pattern = #"Downloaded item\s+[0-9]+\s+to\s+[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return URL(fileURLWithPath: String(output[range]))
    }
}
