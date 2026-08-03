import Foundation

@main
struct InspectScene {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: inspect_scene <scene.pkg>\n", stderr)
            exit(2)
        }

        do {
            let package = try ScenePackage(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            if let index = CommandLine.arguments.firstIndex(of: "--extract"), CommandLine.arguments.indices.contains(index + 1) {
                try package.extract(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            }
            print("version=\(package.version) entries=\(package.entries.count)")
            for entry in package.entries { print("\(entry.length)\t\(entry.path)") }
            if CommandLine.arguments.contains("--tex-headers") {
                for entry in package.entries where entry.path.hasSuffix(".tex") {
                    let bytes = try package.data(for: entry.path).prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("TEX \(entry.path): \(bytes)")
                }
            }
            if CommandLine.arguments.contains("--all-json") {
                for entry in package.entries where entry.path.hasSuffix(".json") {
                    print("\n===== \(entry.path) =====")
                    if let value = String(data: try package.data(for: entry.path), encoding: .utf8) { print(value) }
                }
            }
            if CommandLine.arguments.contains("--shaders") {
                for entry in package.entries where entry.path.hasSuffix(".vert") || entry.path.hasSuffix(".frag") {
                    print("\n===== \(entry.path) =====")
                    if let value = String(data: try package.data(for: entry.path), encoding: .utf8) { print(value) }
                }
            }
            let sceneData = try package.data(for: "scene.json")
            if CommandLine.arguments.contains("--json"), let json = String(data: sceneData, encoding: .utf8) {
                print(json)
            }
            if let object = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] {
                print("scene.keys=\(object.keys.sorted().joined(separator: ","))")
                if let objects = object["objects"] as? [[String: Any]] {
                    let types = Dictionary(grouping: objects, by: { ($0["type"] as? String) ?? "unknown" }).mapValues(\.count)
                    print("scene.objects=\(objects.count) types=\(types)")
                }
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
