import Foundation
import CoreGraphics
import ImageIO

enum WETextureError: LocalizedError {
    case invalid
    case unsupportedFormat(UInt32)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalid: return "A texture inside the scene package is damaged."
        case .unsupportedFormat(let value): return "The scene uses unsupported texture format \(value)."
        case .decompressionFailed: return "A compressed scene texture could not be decoded."
        }
    }
}

struct WETexture {
    let format: UInt32
    let width: Int
    let height: Int
    let pixels: Data

    init(data: Data) throws {
        var reader = TextureReader(data)
        guard try reader.bytes(9) == Data("TEXV0005\0".utf8),
              try reader.bytes(9) == Data("TEXI0001\0".utf8) else { throw WETextureError.invalid }
        format = try reader.u32()
        guard [UInt32(0), 8, 9].contains(format) else { throw WETextureError.unsupportedFormat(format) }
        _ = try reader.u32() // flags
        _ = try reader.u32() // allocated width
        _ = try reader.u32() // allocated height
        _ = try reader.u32() // real width
        _ = try reader.u32() // real height
        _ = try reader.u32()
        let container = try reader.bytes(9)
        guard container == Data("TEXB0003\0".utf8) || container == Data("TEXB0002\0".utf8) else {
            throw WETextureError.invalid
        }
        let imageCount = try reader.u32()
        guard imageCount > 0 else { throw WETextureError.invalid }
        let freeImageFormat = container == Data("TEXB0003\0".utf8) ? try reader.u32() : 0
        let mipCount = try reader.u32()
        guard mipCount > 0 else { throw WETextureError.invalid }

        let mipWidth = Int(try reader.u32())
        let mipHeight = Int(try reader.u32())
        let compression = try reader.u32()
        var uncompressedSize = Int(try reader.i32())
        let storedSize = Int(try reader.i32())
        if compression == 0 { uncompressedSize = storedSize }
        guard mipWidth > 0, mipHeight > 0, uncompressedSize > 0, storedSize > 0 else { throw WETextureError.invalid }
        let stored = try reader.bytes(storedSize)
        let decoded: Data
        if compression == 1 {
            decoded = try LZ4Block.decode(stored, outputSize: uncompressedSize)
        } else if compression == 0 {
            decoded = stored
        } else {
            throw WETextureError.invalid
        }
        guard decoded.count == uncompressedSize else { throw WETextureError.decompressionFailed }
        if freeImageFormat != 0 && freeImageFormat != UInt32.max {
            guard let source = CGImageSourceCreateWithData(decoded as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WETextureError.invalid }
            let decodedWidth = image.width
            let decodedHeight = image.height
            var rgba = Data(count: decodedWidth * decodedHeight * 4)
            let rendered = rgba.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: decodedWidth,
                    height: decodedHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: decodedWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: decodedWidth, height: decodedHeight))
                return true
            }
            guard rendered else { throw WETextureError.invalid }
            width = decodedWidth
            height = decodedHeight
            pixels = rgba
        } else {
            width = mipWidth
            height = mipHeight
            pixels = decoded
        }
    }
}

private struct TextureReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw WETextureError.invalid }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func u32() throws -> UInt32 {
        let value = try bytes(4)
        return value.enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
}

private enum LZ4Block {
    static func decode(_ source: Data, outputSize: Int) throws -> Data {
        guard outputSize >= 0 else { throw WETextureError.decompressionFailed }
        var output = Data(count: outputSize)
        let written = source.withUnsafeBytes { srcRaw -> Int? in
            output.withUnsafeMutableBytes { dstRaw -> Int? in
                guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var sourceIndex = 0
                var destinationIndex = 0

                func extendedLength(_ initial: Int) -> Int? {
                    var length = initial
                    if initial == 15 {
                        while sourceIndex < source.count {
                            let value = Int(srcBase[sourceIndex]); sourceIndex += 1; length += value
                            if value != 255 { return length }
                        }
                        return nil
                    }
                    return length
                }

                while sourceIndex < source.count {
                    let token = Int(srcBase[sourceIndex]); sourceIndex += 1
                    guard let literalLength = extendedLength(token >> 4),
                          sourceIndex <= source.count - literalLength,
                          destinationIndex <= outputSize - literalLength else { return nil }
                    if literalLength > 0 {
                        dstBase.advanced(by: destinationIndex).update(from: srcBase.advanced(by: sourceIndex), count: literalLength)
                        sourceIndex += literalLength
                        destinationIndex += literalLength
                    }
                    if sourceIndex == source.count { break }
                    guard sourceIndex <= source.count - 2 else { return nil }
                    let matchOffset = Int(srcBase[sourceIndex]) | (Int(srcBase[sourceIndex + 1]) << 8)
                    sourceIndex += 2
                    guard matchOffset > 0, matchOffset <= destinationIndex,
                          let matchLengthBase = extendedLength(token & 0x0f) else { return nil }
                    let matchLength = matchLengthBase + 4
                    guard destinationIndex <= outputSize - matchLength else { return nil }
                    for index in 0..<matchLength {
                        dstBase[destinationIndex + index] = dstBase[destinationIndex - matchOffset + index]
                    }
                    destinationIndex += matchLength
                }
                return destinationIndex
            }
        }
        guard written == outputSize else { throw WETextureError.decompressionFailed }
        return output
    }
}
