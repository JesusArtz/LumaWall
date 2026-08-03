import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumawall-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let direct = root.appendingPathComponent("aurora.mp4")
try Data([0, 1, 2]).write(to: direct)
let directItem = try WallpaperImporter.inspect(direct)
expect(directItem.name == "aurora", "direct video name")
expect(directItem.sourceURL == direct, "direct video URL")

let project = root.appendingPathComponent("project")
try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
let video = project.appendingPathComponent("wallpaper.mp4")
try Data([0, 1, 2]).write(to: video)
let json = #"{"title":"Blue Hour","type":"video","file":"wallpaper.mp4"}"#
try json.data(using: .utf8)!.write(to: project.appendingPathComponent("project.json"))
let projectItem = try WallpaperImporter.inspect(project)
expect(projectItem.name == "Blue Hour", "project title")
expect(projectItem.sourceURL == video, "project video")

func littleEndian(_ value: UInt32) -> Data {
    var value = value.littleEndian
    return Data(bytes: &value, count: 4)
}
func sized(_ value: String) -> Data {
    littleEndian(UInt32(value.utf8.count)) + Data(value.utf8)
}
let payload = Data(#"{"objects":[]}"#.utf8)
let pkgData = sized("PKGV0013") + littleEndian(1) + sized("scene.json") + littleEndian(0) + littleEndian(UInt32(payload.count)) + payload
let parsed = try ScenePackage(data: pkgData)
expect(parsed.version == "PKGV0013", "package version")
expect(parsed.entries == [ScenePackageEntry(path: "scene.json", offset: 0, length: payload.count)], "package directory")
let parsedPayload = try parsed.data(for: "scene.json")
expect(parsedPayload == payload, "package payload")

let package = root.appendingPathComponent("scene.pkg")
try pkgData.write(to: package)
let sceneItem = try WallpaperImporter.inspect(package)
expect(sceneItem.kind == .scenePackage, "scene package kind")
expect(sceneItem.sourceURL == package, "scene package URL")

let traversal = sized("PKGV0013") + littleEndian(1) + sized("../escape") + littleEndian(0) + littleEndian(0)
do { _ = try ScenePackage(data: traversal); expect(false, "path traversal rejection") }
catch ScenePackageError.unsafePath("../escape") { }

print("LumaWall tests passed")
