import Foundation
#if canImport(Compression)
import Compression
#endif

public enum ZipError: Error, Equatable {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16)
    case missingEntry(String)
}

/// Minimal reader for small ZIP files such as GTFS feeds: stored and deflated entries, no ZIP64.
public struct ZipArchive: Sendable {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    public var entryNames: [String] { Array(entries.keys) }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes

        // The end-of-central-directory record sits in the last 22 + 65535 bytes.
        let minimum = 22
        guard bytes.count >= minimum else { throw ZipError.notAZip }
        let searchStart = max(0, bytes.count - minimum - 0xFFFF)
        guard let eocd = stride(from: bytes.count - minimum, through: searchStart, by: -1)
            .first(where: { Self.u32(bytes, $0) == 0x0605_4B50 }) else {
            throw ZipError.notAZip
        }

        let entryCount = Int(Self.u16(bytes, eocd + 10))
        var offset = Int(Self.u32(bytes, eocd + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, Self.u32(bytes, offset) == 0x0201_4B50 else {
                throw ZipError.corrupt("central directory")
            }
            let nameLength = Int(Self.u16(bytes, offset + 28))
            let extraLength = Int(Self.u16(bytes, offset + 30))
            let commentLength = Int(Self.u16(bytes, offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.corrupt("entry name") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(
                method: Self.u16(bytes, offset + 10),
                compressedSize: Int(Self.u32(bytes, offset + 20)),
                uncompressedSize: Int(Self.u32(bytes, offset + 24)),
                localHeaderOffset: Int(Self.u32(bytes, offset + 42))
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The entry's bytes. Names match with or without a leading directory.
    public func contents(of name: String) throws -> Data {
        guard let entry = entries[name] ?? entries.first(where: { $0.key.hasSuffix("/" + name) })?.value else {
            throw ZipError.missingEntry(name)
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else {
            throw ZipError.corrupt("local header for \(name)")
        }
        let start = header + 30 + Int(Self.u16(bytes, header + 26)) + Int(Self.u16(bytes, header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupt("data for \(name)") }
        let payload = bytes[start..<end]

        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try Self.inflate(payload, size: entry.uncompressedSize, name: name)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    private static func inflate(_ input: ArraySlice<UInt8>, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        #if canImport(Compression)
        var output = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
                compression_decode_buffer(destination.baseAddress!, size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("deflate stream for \(name)") }
        return Data(output)
        #else
        throw ZipError.unsupportedMethod(8)
        #endif
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
