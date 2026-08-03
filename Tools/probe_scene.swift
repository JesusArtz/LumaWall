import Foundation

@main
struct ProbeScene {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        do {
            let package = try ScenePackage(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            for entry in package.entries where entry.path.hasSuffix(".tex") {
                do {
                    let texture = try WETexture(data: package.data(for: entry.path))
                    print("decoded \(entry.path) \(texture.width)x\(texture.height) format=\(texture.format) bytes=\(texture.pixels.count)")
                } catch { print("decode failed \(entry.path): \(error.localizedDescription)") }
            }
            let resources = try SceneResources(packageURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            _ = try SceneMetalView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), resources: resources, scaling: .fill)
            print("base=\(resources.baseTexture.width)x\(resources.baseTexture.height) masks=\(resources.maskTextures.count) waves=\(resources.waves.count) fog=\(resources.hasFog) embers=\(resources.hasEmbers)")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
