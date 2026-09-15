import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let restoreOnLaunch = "settings.restoreOnLaunch"
        static let pauseOnScreenSleep = "settings.pauseOnScreenSleep"
        static let pauseOnSessionLock = "settings.pauseOnSessionLock"
        static let pauseInLowPowerMode = "settings.pauseInLowPowerMode"
        static let pauseWhenFullscreen = "settings.pauseWhenFullscreen"
        static let globalMute = "settings.globalMute"
        static let globalVolume = "settings.globalVolume"
        static let playbackRate = "settings.playbackRate"
        static let defaultScaling = "player.scaling"
        static let steamCMDPath = "workshop.steamCMDPath"
        static let steamUsername = "workshop.steamUsername"
        static let apiKeyAccount = "steam.web-api-key"
    }

    @Published var restoreOnLaunch: Bool { didSet { defaults.set(restoreOnLaunch, forKey: Keys.restoreOnLaunch) } }
    @Published var pauseOnScreenSleep: Bool { didSet { defaults.set(pauseOnScreenSleep, forKey: Keys.pauseOnScreenSleep) } }
    @Published var pauseOnSessionLock: Bool { didSet { defaults.set(pauseOnSessionLock, forKey: Keys.pauseOnSessionLock) } }
    @Published var pauseInLowPowerMode: Bool { didSet { defaults.set(pauseInLowPowerMode, forKey: Keys.pauseInLowPowerMode) } }
    @Published var pauseWhenFullscreen: Bool { didSet { defaults.set(pauseWhenFullscreen, forKey: Keys.pauseWhenFullscreen) } }
    @Published var globalMute: Bool { didSet { defaults.set(globalMute, forKey: Keys.globalMute) } }
    @Published var globalVolume: Double { didSet { defaults.set(globalVolume, forKey: Keys.globalVolume) } }
    @Published var playbackRate: Double { didSet { defaults.set(playbackRate, forKey: Keys.playbackRate) } }
    @Published var defaultScaling: VideoScaling { didSet { defaults.set(defaultScaling.rawValue, forKey: Keys.defaultScaling) } }
    @Published var steamCMDPath: String { didSet { defaults.set(steamCMDPath, forKey: Keys.steamCMDPath) } }
    @Published var steamUsername: String { didSet { defaults.set(steamUsername, forKey: Keys.steamUsername) } }
    @Published private(set) var hasSteamAPIKey = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreOnLaunch = defaults.object(forKey: Keys.restoreOnLaunch) as? Bool ?? true
        pauseOnScreenSleep = defaults.object(forKey: Keys.pauseOnScreenSleep) as? Bool ?? true
        pauseOnSessionLock = defaults.object(forKey: Keys.pauseOnSessionLock) as? Bool ?? true
        pauseInLowPowerMode = defaults.object(forKey: Keys.pauseInLowPowerMode) as? Bool ?? false
        pauseWhenFullscreen = defaults.object(forKey: Keys.pauseWhenFullscreen) as? Bool ?? true
        globalMute = defaults.object(forKey: Keys.globalMute) as? Bool ?? true
        globalVolume = min(max(defaults.object(forKey: Keys.globalVolume) as? Double ?? 0.5, 0), 1)
        playbackRate = min(max(defaults.object(forKey: Keys.playbackRate) as? Double ?? 1, 0.25), 2)
        defaultScaling = VideoScaling(rawValue: defaults.string(forKey: Keys.defaultScaling) ?? "") ?? .fill
        steamCMDPath = defaults.string(forKey: Keys.steamCMDPath) ?? ""
        steamUsername = defaults.string(forKey: Keys.steamUsername) ?? ""
        hasSteamAPIKey = ((try? KeychainStore.value(for: Keys.apiKeyAccount)) ?? nil)?.isEmpty == false
    }

    func steamAPIKey() -> String? {
        (try? KeychainStore.value(for: Keys.apiKeyAccount)) ?? nil
    }

    func saveSteamAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.set(trimmed.nilIfEmpty, for: Keys.apiKeyAccount)
        hasSteamAPIKey = !trimmed.isEmpty
    }

    var globalPlayback: PlaybackConfiguration {
        PlaybackConfiguration(
            scaling: defaultScaling,
            isMuted: globalMute,
            volume: globalVolume,
            playbackRate: playbackRate
        )
    }

    var defaultDisplayPlayback: PlaybackConfiguration {
        PlaybackConfiguration(
            scaling: defaultScaling,
            isMuted: false,
            volume: globalVolume,
            playbackRate: playbackRate
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
