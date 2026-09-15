import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func writeUTF8(_ value: String, to url: URL) throws {
    guard let data = value.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
    try data.write(to: url)
}

func littleEndian(_ value: UInt32) -> Data {
    var value = value.littleEndian
    return Data(bytes: &value, count: 4)
}

func sized(_ value: String) -> Data {
    littleEndian(UInt32(value.utf8.count)) + Data(value.utf8)
}

func packageData(entries: [(String, Data)]) -> Data {
    var directory = sized("PKGV0013") + littleEndian(UInt32(entries.count))
    var payload = Data()
    for (path, data) in entries {
        directory += sized(path) + littleEndian(UInt32(payload.count)) + littleEndian(UInt32(data.count))
        payload += data
    }
    return directory + payload
}

func textureData(width: UInt32, height: UInt32, format: UInt32 = 0, pixels: Data) -> Data {
    var data = Data("TEXV0005\0".utf8) + Data("TEXI0001\0".utf8)
    data += littleEndian(format)
    for value in [UInt32(0), width, height, width, height, 0] { data += littleEndian(value) }
    data += Data("TEXB0003\0".utf8)
    data += littleEndian(1)
    data += littleEndian(0)
    data += littleEndian(1)
    data += littleEndian(width) + littleEndian(height)
    data += littleEndian(0)
    data += littleEndian(UInt32(pixels.count)) + littleEndian(UInt32(pixels.count))
    data += pixels
    return data
}

func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumawall-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// Stable identity and backward-compatible metadata decoding.
let stableA = StableIdentifier.uuid(namespace: "test", value: "same")
let stableB = StableIdentifier.uuid(namespace: "test", value: "same")
let stableC = StableIdentifier.uuid(namespace: "test", value: "different")
expect(stableA == stableB, "stable identifier repeatability")
expect(stableA != stableC, "stable identifier separation")

let favoriteDefaultsName = "lumawall-tests-favorites-\(UUID().uuidString)"
if let favoriteDefaults = UserDefaults(suiteName: favoriteDefaultsName) {
    favoriteDefaults.removePersistentDomain(forName: favoriteDefaultsName)
    WorkshopFavoriteStore.save(["123", "456"], to: favoriteDefaults)
    expect(WorkshopFavoriteStore.load(from: favoriteDefaults) == ["123", "456"], "Workshop favorite persistence")
    favoriteDefaults.set(["123", "not-an-id"], forKey: "favorites.workshopIDs.v1")
    expect(WorkshopFavoriteStore.load(from: favoriteDefaults) == ["123"], "invalid persisted Workshop favorite filtering")
    favoriteDefaults.removePersistentDomain(forName: favoriteDefaultsName)
} else {
    expect(false, "isolated UserDefaults suite creation")
}

let legacyID = UUID()
let legacyJSON = """
[{"id":"\(legacyID.uuidString)","name":"Legacy","sourcePath":"/tmp/legacy.mp4","previewPath":null,"kind":"video"}]
"""
let legacyItems = try JSONDecoder().decode([WallpaperItem].self, from: Data(legacyJSON.utf8))
expect(legacyItems.first?.source.kind == .external, "legacy source migration")
expect(legacyItems.first?.compatibility == .full, "legacy compatibility migration")
expect(legacyItems.first?.isFavorite == false, "legacy favorite migration")

// Standalone and project.json inspection.
let direct = root.appendingPathComponent("aurora.mp4")
try Data([0, 1, 2]).write(to: direct)
let directItem = try WallpaperImporter.inspect(direct)
expect(directItem.name == "aurora", "direct video name")
expect(directItem.sourceURL == direct, "direct video URL")
expect(directItem.kind == .video, "direct video type")

let project = root.appendingPathComponent("project")
try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
let video = project.appendingPathComponent("wallpaper.mp4")
try Data([0, 1, 2]).write(to: video)
try writeUTF8(
    #"{"title":"Blue Hour","type":"video","file":"wallpaper.mp4","workshopid":"123456","tags":["Nature",{"tag":"Relaxing"}]}"#,
    to: project.appendingPathComponent("project.json")
)
let projectItem = try WallpaperImporter.inspect(project)
expect(projectItem.name == "Blue Hour", "project title")
expect(projectItem.sourceURL == video, "project video")
expect(projectItem.workshopID == "123456", "Workshop ID preservation")
expect(!projectItem.isManaged, "inspected external Workshop project is not managed")
expect(projectItem.tags == ["Nature", "Relaxing"], "project tag mapping")

let invalidWorkshopProject = root.appendingPathComponent("invalid-workshop-id")
try FileManager.default.createDirectory(at: invalidWorkshopProject, withIntermediateDirectories: true)
try Data([0]).write(to: invalidWorkshopProject.appendingPathComponent("video.mp4"))
try writeUTF8(
    #"{"type":"video","file":"video.mp4","workshopid":"123\nquit"}"#,
    to: invalidWorkshopProject.appendingPathComponent("project.json")
)
let invalidWorkshopItem = try WallpaperImporter.inspect(invalidWorkshopProject)
expect(invalidWorkshopItem.workshopID == nil, "invalid declared Workshop ID is not preserved")

let webProject = root.appendingPathComponent("web-project")
try FileManager.default.createDirectory(at: webProject, withIntermediateDirectories: true)
try writeUTF8("<html></html>", to: webProject.appendingPathComponent("index.html"))
try writeUTF8(#"{"title":"Web","type":"web","file":"index.html"}"#, to: webProject.appendingPathComponent("project.json"))
let webItem = try WallpaperImporter.inspect(webProject)
expect(webItem.kind == .web, "web project type")
expect(webItem.projectRootURL == FileUtilities.canonicalURL(webProject), "web read-access root")

let missingPreviewProject = root.appendingPathComponent("missing-preview-project")
try FileManager.default.createDirectory(at: missingPreviewProject, withIntermediateDirectories: true)
try Data([3, 2, 1]).write(to: missingPreviewProject.appendingPathComponent("wallpaper.mp4"))
try writeUTF8(
    #"{"title":"No Preview","type":"video","file":"wallpaper.mp4","preview":"missing.jpg"}"#,
    to: missingPreviewProject.appendingPathComponent("project.json")
)
let missingPreviewItem = try WallpaperImporter.inspect(missingPreviewProject)
expect(missingPreviewItem.previewURL == nil, "missing optional preview does not reject a valid project")

let unsafePreviewProject = root.appendingPathComponent("unsafe-preview-project")
try FileManager.default.createDirectory(at: unsafePreviewProject, withIntermediateDirectories: true)
try Data([3, 2, 1]).write(to: unsafePreviewProject.appendingPathComponent("wallpaper.mp4"))
try writeUTF8(
    #"{"type":"video","file":"wallpaper.mp4","preview":"../preview.jpg"}"#,
    to: unsafePreviewProject.appendingPathComponent("project.json")
)
do {
    _ = try WallpaperImporter.inspect(unsafePreviewProject)
    expect(false, "optional preview traversal rejection")
} catch ImportError.unsafeProjectPath("../preview.jpg") {}

let workshopFolder = root
    .appendingPathComponent("steamapps/workshop/content/431960/777", isDirectory: true)
try FileManager.default.createDirectory(at: workshopFolder, withIntermediateDirectories: true)
try Data([1]).write(to: workshopFolder.appendingPathComponent("video.mp4"))
try writeUTF8(#"{"title":"Installed","type":"video","file":"video.mp4"}"#, to: workshopFolder.appendingPathComponent("project.json"))
let inferredWorkshopItem = try WallpaperImporter.inspect(workshopFolder)
expect(inferredWorkshopItem.workshopID == "777", "Steam Workshop folder ID inference")

let sameNameA = root.appendingPathComponent("same-a/same.mp4")
let sameNameB = root.appendingPathComponent("same-b/same.mp4")
try FileManager.default.createDirectory(at: sameNameA.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: sameNameB.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data([1]).write(to: sameNameA)
try Data([2]).write(to: sameNameB)
let sameItemA = try WallpaperImporter.inspect(sameNameA)
let sameItemB = try WallpaperImporter.inspect(sameNameB)
expect(sameItemA.name == sameItemB.name, "duplicate display-name fixture")
expect(sameItemA.id != sameItemB.id, "same display name does not collide")

let unsafeProject = root.appendingPathComponent("unsafe-project")
try FileManager.default.createDirectory(at: unsafeProject, withIntermediateDirectories: true)
try writeUTF8(#"{"type":"video","file":"../aurora.mp4"}"#, to: unsafeProject.appendingPathComponent("project.json"))
do {
    _ = try WallpaperImporter.inspect(unsafeProject)
    expect(false, "project traversal rejection")
} catch ImportError.unsafeProjectPath("../aurora.mp4") {}

let unsupportedProject = root.appendingPathComponent("application-project")
try FileManager.default.createDirectory(at: unsupportedProject, withIntermediateDirectories: true)
try writeUTF8(#"{"type":"application","file":"program.exe"}"#, to: unsupportedProject.appendingPathComponent("project.json"))
do {
    _ = try WallpaperImporter.inspect(unsupportedProject)
    expect(false, "application project rejection")
} catch ImportError.unsupportedProject("application") {}

// Bounds-checked PKGV parsing.
let sceneJSON = Data(#"{"objects":[]}"#.utf8)
let pkgData = packageData(entries: [("scene.json", sceneJSON)])
let parsed = try ScenePackage(data: pkgData)
expect(parsed.version == "PKGV0013", "package version")
expect(parsed.entries == [ScenePackageEntry(path: "scene.json", offset: 0, length: sceneJSON.count)], "package directory")
let parsedSceneJSON = try parsed.data(for: "scene.json")
expect(parsedSceneJSON == sceneJSON, "package payload")

let package = root.appendingPathComponent("scene.pkg")
try pkgData.write(to: package)
let sceneItem = try WallpaperImporter.inspect(package)
expect(sceneItem.kind == .scenePackage, "scene package kind")
expect(sceneItem.compatibility == .unsupported, "scene without image is explicit unsupported")
let fallbackPreview = root.appendingPathComponent("preview.jpg")
let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLqWQAAAABJRU5ErkJggg==") ?? Data()
expect(!onePixelPNG.isEmpty, "preview fixture decoding")
try onePixelPNG.write(to: fallbackPreview)
let fallbackReport = try SceneCompatibilityAnalyzer.inspect(packageURL: package, previewURL: fallbackPreview)
expect(fallbackReport.status == .fallback, "scene preview fallback status")
let invalidPreview = root.appendingPathComponent("invalid-preview.jpg")
try Data([1]).write(to: invalidPreview)
let invalidFallbackReport = try SceneCompatibilityAnalyzer.inspect(packageURL: package, previewURL: invalidPreview)
expect(invalidFallbackReport.status == .unsupported, "invalid scene preview is not advertised as fallback")

let validTexture = textureData(width: 1, height: 1, pixels: Data([10, 20, 30, 255]))
let compatibleScene = packageData(entries: [
    ("scene.json", Data(#"{"objects":[{"image":"models/base.json"}]}"#.utf8)),
    ("models/base.json", Data(#"{"material":"materials/base.json"}"#.utf8)),
    ("materials/base.json", Data(#"{"passes":[{"textures":["base"]}]}"#.utf8)),
    ("materials/base.tex", validTexture)
])
let compatiblePackage = root.appendingPathComponent("compatible.pkg")
try compatibleScene.write(to: compatiblePackage)
let compatibleReport = try SceneCompatibilityAnalyzer.inspect(packageURL: compatiblePackage, previewURL: nil)
expect(compatibleReport.status == .partial, "compatible scene remains explicitly partial")

let traversal = sized("PKGV0013") + littleEndian(1) + sized("../escape") + littleEndian(0) + littleEndian(0)
do {
    _ = try ScenePackage(data: traversal)
    expect(false, "package traversal rejection")
} catch ScenePackageError.unsafePath("../escape") {}

let duplicateEntries = packageData(entries: [("scene.json", Data()), ("scene.json", Data())])
do {
    _ = try ScenePackage(data: duplicateEntries)
    expect(false, "duplicate package path rejection")
} catch ScenePackageError.invalidDirectory {}

let extractionRoot = root.appendingPathComponent("package-extraction")
let extractionOutside = root.appendingPathComponent("package-extraction-outside")
try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: extractionOutside, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(
    at: extractionRoot.appendingPathComponent("linked"),
    withDestinationURL: extractionOutside
)
do {
    try ScenePackage(data: packageData(entries: [("linked/escape.txt", Data([1]))])).extract(to: extractionRoot)
    expect(false, "package extraction through a destination symlink rejection")
} catch ScenePackageError.unsafePath("linked/escape.txt") {}
expect(!FileManager.default.fileExists(atPath: extractionOutside.appendingPathComponent("escape.txt").path), "package extraction confinement")

// TEX dimensions cannot cause an undersized Metal upload.
do {
    _ = try WETexture(data: textureData(width: 2, height: 2, pixels: Data([0])))
    expect(false, "undersized texture rejection")
} catch WETextureError.invalidPixelData {}

do {
    _ = try WETexture(data: textureData(width: 20_000, height: 1, pixels: Data([0])))
    expect(false, "oversized texture rejection")
} catch WETextureError.resourceTooLarge {}
let decodedTexture = try WETexture(data: validTexture)
expect(decodedTexture.width == 1 && decodedTexture.height == 1, "valid raw texture decoding")
expect(decodedTexture.pixels == Data([10, 20, 30, 255]), "valid raw texture bytes")

// Managed storage, deterministic duplicates, and persistence.
let storage = WallpaperStorage(rootURL: root.appendingPathComponent("managed", isDirectory: true))
let managed = try storage.importLocal(from: direct)
expect(managed.isManaged, "local import is managed")
expect(FileManager.default.fileExists(atPath: managed.sourcePath), "managed asset copied")
expect(FileManager.default.fileExists(atPath: direct.path), "original asset retained")
expect(FileUtilities.isDescendant(managed.sourceURL, of: storage.wallpapersURL), "managed asset stays inside storage")
let managedAgain = try storage.importLocal(from: direct)
expect(managedAgain.id == managed.id, "repeat import has stable ID")
let managedWorkshopProject = try storage.importLocal(from: project)
expect(managedWorkshopProject.workshopID == "123456", "managed project preserves Workshop ID")

let linkedProject = root.appendingPathComponent("linked-project")
let nestedPackage = linkedProject.appendingPathComponent("Assets.bundle")
try FileManager.default.createDirectory(at: nestedPackage, withIntermediateDirectories: true)
try Data([1]).write(to: linkedProject.appendingPathComponent("video.mp4"))
try writeUTF8(#"{"type":"video","file":"video.mp4"}"#, to: linkedProject.appendingPathComponent("project.json"))
try FileManager.default.createSymbolicLink(
    at: nestedPackage.appendingPathComponent("outside.mp4"),
    withDestinationURL: direct
)
do {
    _ = try storage.importLocal(from: linkedProject)
    expect(false, "symlink nested inside a file package rejection")
} catch WallpaperStorage.StorageError.unsafeArchive {}

var favorite = managed
favorite.isFavorite = true
favorite.lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_000)
try storage.saveLibrary([favorite])
let loadedLibrary = try storage.loadLibrary()
expect(loadedLibrary.first?.isFavorite == true, "favorite persistence")
expect(loadedLibrary.first?.lastPlayedAt == favorite.lastPlayedAt, "recent persistence")

let playlist = WallpaperPlaylist(name: "Evening", wallpaperIDs: [managed.id], playbackMode: .shuffle, interval: 600)
try storage.savePlaylists([playlist])
let loadedPlaylists = try storage.loadPlaylists()
expect(loadedPlaylists == [playlist], "playlist persistence")

let displayConfiguration = DisplayConfiguration(
    displayID: "display-uuid",
    wallpaperID: managed.id,
    playback: PlaybackConfiguration(scaling: .fit, isMuted: false, volume: 0.4, playbackRate: 1.5)
)
let encodedDisplayConfiguration = try JSONEncoder().encode(displayConfiguration)
let decodedDisplayConfiguration = try JSONDecoder().decode(DisplayConfiguration.self, from: encodedDisplayConfiguration)
expect(decodedDisplayConfiguration == displayConfiguration, "display configuration persistence")

let external = WallpaperItem(name: "External", sourceURL: direct)
try storage.removeManagedContent(for: external)
expect(FileManager.default.fileExists(atPath: direct.path), "external content deletion protection")

// ZIP import uses a validated archive directory and rejects ambiguous bundles.
let zipSource = root.appendingPathComponent("zip-source")
try FileManager.default.createDirectory(at: zipSource, withIntermediateDirectories: true)
try Data([1, 2, 3]).write(to: zipSource.appendingPathComponent("zipped.mp4"))
let archive = root.appendingPathComponent("wallpaper.zip")
try run("/usr/bin/ditto", arguments: ["-c", "-k", zipSource.path, archive.path])
let archivedItem = try storage.importLocal(from: archive)
expect(archivedItem.kind == .video, "ZIP standalone import")
expect(archivedItem.source.originalPath == archive.path, "ZIP provenance")
let archivedAgain = try storage.importLocal(from: archive)
expect(archivedAgain.id == archivedItem.id, "repeat ZIP import has stable ID")

let ambiguous = root.appendingPathComponent("ambiguous")
for name in ["one", "two"] {
    let directory = ambiguous.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1]).write(to: directory.appendingPathComponent("video.mp4"))
    try writeUTF8(#"{"type":"video","file":"video.mp4"}"#, to: directory.appendingPathComponent("project.json"))
}
let ambiguousArchive = root.appendingPathComponent("ambiguous.zip")
try run("/usr/bin/ditto", arguments: ["-c", "-k", ambiguous.path, ambiguousArchive.path])
do {
    _ = try storage.importLocal(from: ambiguousArchive)
    expect(false, "ambiguous archive rejection")
} catch WallpaperStorage.StorageError.multipleWallpaperProjects {}

// Workshop response mapping and official query enum values.
let workshopJSON = #"{"response":{"total":1,"next_cursor":"abc","publishedfiledetails":[{"publishedfileid":"987","title":"Rain","creator":"765","short_description":"Calm","preview_url":"https://example.com/preview.jpg","file_size":"2048","time_updated":1700000000,"subscriptions":42,"content_descriptorids":[1],"tags":[{"tag":"Scene"},{"display_name":"Nature"}]}]}}"#
let workshopPage = try WorkshopAPIService.parsePage(Data(workshopJSON.utf8))
expect(workshopPage.items.first?.publishedFileID == "987", "Workshop ID mapping")
expect(workshopPage.items.first?.type == .scenePackage, "Workshop type mapping")
expect(workshopPage.items.first?.fileSize == 2_048, "Workshop size mapping")
expect(workshopPage.items.first?.contentDescriptorIDs == [1], "Workshop content descriptor mapping")
expect(workshopPage.nextCursor == "abc", "Workshop cursor mapping")
expect(WorkshopSort.trending.queryType == 3, "trending query mapping")
expect(WorkshopSort.mostPopular.queryType == 0, "popular query mapping")
expect(WorkshopSort.mostRecent.queryType == 1, "recent query mapping")
expect(WorkshopSort.mostSubscribed.queryType == 9, "subscription query mapping")
expect(DownloadState.downloading.canCancel, "active Steam download cancellation")
expect(!DownloadState.importing.canCancel, "managed installation cancellation boundary")

// SteamCMD commands use Process arguments and stdin commands without credential values.
let plan = try SteamCommandPlan.make(
    executableURL: URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
    installDirectory: root.appendingPathComponent("steam data"),
    username: "account-name"
)
expect(plan.arguments.contains("+@NoPromptForPassword"), "SteamCMD prompt configuration")
expect(!plan.arguments.contains(where: { $0.localizedCaseInsensitiveContains("password") && $0 != "+@NoPromptForPassword" }), "no password process argument")
expect(plan.initialCommands.contains("login \"account-name\""), "quoted Steam account")
let quotedPlan = try SteamCommandPlan.make(
    executableURL: plan.executableURL,
    installDirectory: root,
    username: "account\"name"
)
expect(quotedPlan.initialCommands.contains("account\\\"name"), "Steam account quote escaping")
let workshopCommands = try SteamCommandPlan.workshopCommands(for: "987654321")
expect(workshopCommands.contains("workshop_download_item 431960 987654321 validate"), "legitimate Workshop command")
do {
    _ = try SteamCommandPlan.make(
        executableURL: plan.executableURL,
        installDirectory: root,
        username: "account\nquit"
    )
    expect(false, "Steam command newline rejection")
} catch SteamCMDConfigurationError.invalidUsername {}
do {
    _ = try SteamCommandPlan.workshopCommands(for: "１２３")
    expect(false, "Steam Workshop ID accepts ASCII digits only")
} catch SteamCMDConfigurationError.invalidWorkshopID {}
let parsedProgress = SteamCmdService.parseProgress(from: "progress: 37.42 (10 / 20)")
expect(abs((parsedProgress ?? 0) - 0.3742) < 0.000_001, "Steam progress parsing")
expect(SteamCmdService.parseProgress(from: "unrelated output") == nil, "Steam progress absence")
expect(
    SteamCmdService.diagnosedFailure(
        from: "KeyValues Error: missing { (current key: '<!DOCTYPE') in file manifest"
    ) == .updateFailed,
    "Steam captive portal/update failure diagnosis"
)
expect(
    SteamCmdService.diagnosedFailure(from: "Fatal Error: Steamcmd needs to be online to update.") == .updateFailed,
    "Steam offline updater failure diagnosis"
)
expect(
    SteamCmdService.completedSuccessfully(exitStatus: 0, commandSubmitted: true, reportedSuccess: true),
    "Steam successful completion decision"
)
expect(
    !SteamCmdService.completedSuccessfully(exitStatus: 0, commandSubmitted: false, reportedSuccess: true),
    "Steam completion requires the current download command"
)
expect(
    !SteamCmdService.completedSuccessfully(exitStatus: 1, commandSubmitted: true, reportedSuccess: true),
    "Steam completion requires a successful process exit"
)

let fakeSteamDirectory = root.appendingPathComponent("fake SteamCMD", isDirectory: true)
try FileManager.default.createDirectory(at: fakeSteamDirectory, withIntermediateDirectories: true)
let fakeSteamBinary = fakeSteamDirectory.appendingPathComponent("steamcmd")
let fakeSteamLauncher = fakeSteamDirectory.appendingPathComponent("steamcmd.sh")
try Data().write(to: fakeSteamBinary)
try Data("#!/bin/sh\n".utf8).write(to: fakeSteamLauncher)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSteamBinary.path)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSteamLauncher.path)
expect(
    SteamCMDLocator.locate(customPath: fakeSteamBinary.path) == fakeSteamLauncher,
    "SteamCMD macOS launcher preference"
)

try storage.removeManagedContent(for: managedAgain)
expect(!FileManager.default.fileExists(atPath: managedAgain.projectRootURL?.path ?? ""), "managed content removal")

print("LumaWall tests passed (models, import, storage, Workshop, SteamCMD, PKG, TEX)")
