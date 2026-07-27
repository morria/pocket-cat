// Splits the transparent CAT byte stream into `;`-terminated frames with
// garbage resync (docs/implementation.md §5.4). Pure value type.

import Foundation

public struct ResponseDemux: Sendable {
    /// A frame longer than this without a terminator is garbage (longest
    /// legitimate CAT traffic is far shorter).
    public static let maxFrameLength = 256

    private var buffer: [UInt8] = []
    public private(set) var garbageFrames = 0

    public init() {}

    /// Ingest transport bytes; returns every complete, valid frame
    /// (including its `;`). Invalid frames are counted and dropped.
    public mutating func ingest(_ data: Data) -> [String] {
        var frames: [String] = []
        for byte in data {
            buffer.append(byte)
            if byte == UInt8(ascii: ";") {
                if let frame = validate(buffer) {
                    frames.append(frame)
                } else {
                    garbageFrames += 1
                }
                buffer.removeAll(keepingCapacity: true)
            } else if buffer.count > Self.maxFrameLength {
                // Runaway garbage with no delimiter: resync.
                buffer.removeAll(keepingCapacity: true)
                garbageFrames += 1
            }
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// A valid frame is printable ASCII ending in ';' with ≥ 1 content byte
    /// ("?;" is the shortest real reply).
    private func validate(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }
        for byte in bytes.dropLast() where byte < 0x20 || byte > 0x7E {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
