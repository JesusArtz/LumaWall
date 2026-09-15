import AppKit
import MetalKit
import simd

struct WavePass {
    var direction: Float
    var speed: Float
    var scale: Float
    var strength: Float
    var perspective: Float
    var maskPath: String?
}

final class SceneResources: @unchecked Sendable {
    private static let maximumJSONBytes = 8 * 1_024 * 1_024
    private static let maximumCombinedTextureBytes = 512 * 1_024 * 1_024
    let device: MTLDevice
    let baseTexture: MTLTexture
    let maskTextures: [MTLTexture]
    let waves: [WavePass]
    let sourceSize: SIMD2<Float>
    let hasFog: Bool
    let hasEmbers: Bool

    init(packageURL: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ImportError.unsupportedProject("Metal-incompatible") }
        let package = try ScenePackage(url: packageURL)
        let sceneData = try package.data(for: "scene.json", maximumBytes: Self.maximumJSONBytes)
        guard let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
              let objects = scene["objects"] as? [[String: Any]] else { throw ScenePackageError.missingEntry("scene.json") }

        let imageObject = objects.first { $0["image"] != nil }
        guard let modelPath = imageObject?["image"] as? String,
              let model = try Self.json(package, modelPath),
              let materialPath = model["material"] as? String,
              let material = try Self.json(package, materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let textureName = (passes.first?["textures"] as? [String])?.first else {
            throw ImportError.unsupportedProject("scene without a base image")
        }
        let basePath = "materials/\(textureName).tex"
        let base = try WETexture(data: package.data(for: basePath, maximumBytes: WETexture.maximumInputBytes))
        guard base.pixels.count <= Self.maximumCombinedTextureBytes else { throw WETextureError.resourceTooLarge }
        baseTexture = try Self.makeTexture(base, device: device)
        sourceSize = SIMD2(Float(base.width), Float(base.height))

        var waves: [WavePass] = []
        for effect in (imageObject?["effects"] as? [[String: Any]]) ?? [] {
            for pass in (effect["passes"] as? [[String: Any]]) ?? [] {
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let textures = pass["textures"] as? [Any]
                waves.append(WavePass(
                    direction: Float(constants["direction"] as? Double ?? 0),
                    speed: Float(constants["speed"] as? Double ?? 5),
                    scale: Float(constants["scale"] as? Double ?? 200),
                    strength: Float(constants["strength"] as? Double ?? 0.1),
                    perspective: Float(constants["perspective"] as? Double ?? 0),
                    maskPath: (textures?.dropFirst().first as? String).map { "materials/\($0).tex" }
                ))
            }
        }
        self.waves = Array(waves.prefix(3))
        var combinedTextureBytes = base.pixels.count
        maskTextures = try self.waves.map { wave in
            guard let path = wave.maskPath, package.contains(path) else { return try Self.whiteTexture(device) }
            let texture = try WETexture(data: package.data(for: path, maximumBytes: WETexture.maximumInputBytes))
            let (newTotal, overflow) = combinedTextureBytes.addingReportingOverflow(texture.pixels.count)
            guard !overflow, newTotal <= Self.maximumCombinedTextureBytes else { throw WETextureError.resourceTooLarge }
            combinedTextureBytes = newTotal
            return try Self.makeTexture(texture, device: device)
        }
        hasFog = objects.contains { ($0["particle"] as? String)?.contains("fog") == true }
        hasEmbers = objects.contains { ($0["particle"] as? String)?.contains("ember") == true }
        self.device = device
    }

    private static func json(_ package: ScenePackage, _ path: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: package.data(for: path, maximumBytes: maximumJSONBytes)) as? [String: Any]
    }

    private static func makeTexture(_ source: WETexture, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.format == 9 ? .r8Unorm : (source.format == 8 ? .rg8Unorm : .rgba8Unorm),
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw WETextureError.invalid }
        let channels = source.format == 9 ? 1 : (source.format == 8 ? 2 : 4)
        let (bytesPerRow, rowOverflow) = source.width.multipliedReportingOverflow(by: channels)
        let (requiredBytes, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: source.height)
        guard !rowOverflow, !sizeOverflow, requiredBytes <= source.pixels.count else {
            throw WETextureError.invalidPixelData
        }
        try source.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { throw WETextureError.invalidPixelData }
            texture.replace(
                region: MTLRegionMake2D(0, 0, source.width, source.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private static func whiteTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw WETextureError.invalid }
        var white: UInt8 = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        return texture
    }
}

private struct SceneUniforms {
    var time: Float
    var viewAspect: Float
    var sourceAspect: Float
    var fitMode: Float
    var waveCount: UInt32
    var hasFog: UInt32
    var hasEmbers: UInt32
    var padding: UInt32 = 0
    var wave0 = SIMD4<Float>(repeating: 0)
    var wave0b = SIMD2<Float>(repeating: 0)
    var wave1 = SIMD4<Float>(repeating: 0)
    var wave1b = SIMD2<Float>(repeating: 0)
    var wave2 = SIMD4<Float>(repeating: 0)
    var wave2b = SIMD2<Float>(repeating: 0)
}

final class SceneMetalView: MTKView, MTKViewDelegate {
    private let resources: SceneResources?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let started = CACurrentMediaTime()
    var scaling: VideoScaling = .fill

    init(frame: CGRect, resources: SceneResources, scaling: VideoScaling) throws {
        self.resources = resources
        self.scaling = scaling
        guard let queue = resources.device.makeCommandQueue() else { throw WETextureError.invalid }
        self.queue = queue
        let library = try resources.device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try resources.device.makeRenderPipelineState(descriptor: descriptor)
        super.init(frame: frame, device: resources.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
    }

    required init(coder: NSCoder) {
        resources = nil
        queue = nil
        pipeline = nil
        super.init(coder: coder)
        isPaused = true
        delegate = self
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let resources, let queue, let pipeline,
              let drawable = currentDrawable, let renderPassDescriptor = currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        let size = drawableSize
        var uniforms = SceneUniforms(
            time: Float(CACurrentMediaTime() - started),
            viewAspect: Float(size.width / max(1, size.height)),
            sourceAspect: resources.sourceSize.x / resources.sourceSize.y,
            fitMode: scaling == .fit ? 1 : 0,
            waveCount: UInt32(resources.waves.count),
            hasFog: resources.hasFog ? 1 : 0,
            hasEmbers: resources.hasEmbers ? 1 : 0
        )
        let values = resources.waves.map { SIMD4($0.direction, $0.speed, $0.scale, $0.strength) }
        let extras = resources.waves.map { SIMD2($0.perspective, 0) }
        if values.indices.contains(0) { uniforms.wave0 = values[0]; uniforms.wave0b = extras[0] }
        if values.indices.contains(1) { uniforms.wave1 = values[1]; uniforms.wave1b = extras[1] }
        if values.indices.contains(2) { uniforms.wave2 = values[2]; uniforms.wave2b = extras[2] }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(resources.baseTexture, index: 0)
        for (index, texture) in resources.maskTextures.enumerated() { encoder.setFragmentTexture(texture, index: index + 1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float2 uv; };
    struct Uniforms {
        float time, viewAspect, sourceAspect, fitMode;
        uint waveCount, hasFog, hasEmbers, padding;
        float4 wave0; float2 wave0b;
        float4 wave1; float2 wave1b;
        float4 wave2; float2 wave2b;
    };
    vertex Out sceneVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return { float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y) };
    }
    float hash21(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453); }
    float2 waveOffset(float2 uv, float4 wave, float perspective, float mask, float time) {
        float2 dir = float2(-sin(wave.x), cos(wave.x));
        float pos = abs(dot(uv - 0.5, dir));
        float distance = time * wave.y + dot(uv, dir) * (wave.z + perspective * pos);
        float2 normal = float2(dir.y, -dir.x);
        return sin(distance) * normal * (wave.w * wave.w + perspective * pos) * mask;
    }
    fragment float4 sceneFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]],
        texture2d<float> base [[texture(0)]], texture2d<float> mask0 [[texture(1)]],
        texture2d<float> mask1 [[texture(2)]], texture2d<float> mask2 [[texture(3)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        if (u.viewAspect > u.sourceAspect) uv.y = (uv.y - .5) * (u.sourceAspect / u.viewAspect) + .5;
        else uv.x = (uv.x - .5) * (u.viewAspect / u.sourceAspect) + .5;
        if (u.fitMode > .5) {
            uv = in.uv;
            if (u.viewAspect > u.sourceAspect) uv.x = (uv.x - .5) * (u.viewAspect / u.sourceAspect) + .5;
            else uv.y = (uv.y - .5) * (u.sourceAspect / u.viewAspect) + .5;
            if (any(uv < 0.0) || any(uv > 1.0)) return float4(0,0,0,1);
        }
        float2 warped = uv;
        if (u.waveCount > 0) warped += waveOffset(warped, u.wave0, u.wave0b.x, mask0.sample(s, uv).r, u.time);
        if (u.waveCount > 1) warped += waveOffset(warped, u.wave1, u.wave1b.x, mask1.sample(s, uv).r, u.time);
        if (u.waveCount > 2) warped += waveOffset(warped, u.wave2, u.wave2b.x, mask2.sample(s, uv).r, u.time);
        float4 color = base.sample(s, warped);
        if (u.hasFog != 0) {
            float fog = sin(uv.x * 8.0 + u.time * .15) * sin(uv.y * 5.0 - u.time * .1);
            color.rgb += smoothstep(.65, 1.0, fog) * .035;
        }
        if (u.hasEmbers != 0) {
            float2 grid = float2(18, 10); float2 cell = floor(uv * grid);
            float seed = hash21(cell); float y = fract(uv.y * grid.y + u.time * (.12 + seed * .25) + seed);
            float x = fract(uv.x * grid.x + seed) - .5;
            float ember = smoothstep(.065, 0.0, length(float2(x, y - .5))) * step(.72, seed);
            color.rgb += ember * float3(1.0, .35, .08);
        }
        return float4(color.rgb, 1);
    }
    """#
}
