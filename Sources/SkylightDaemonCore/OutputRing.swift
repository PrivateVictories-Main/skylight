import Foundation

/// The daemon's per-session memory of everything the terminal said: a
/// bounded byte ring so a reattaching client can replay recent output.
/// 1 MiB matches the pre-attach buffer inside the terminal library — past
/// that, the oldest bytes fall off; a terminal replaying the tail still
/// converges on the current screen.
///
/// A true circular buffer: appends are O(bytes appended), never O(capacity)
/// — the previous Data-backed version paid a full-buffer shift on every
/// append once the ring was full (~16× write amplification under 64 KiB
/// reads). Storage is allocated lazily on first output, so a quiet session
/// costs nothing.
public struct OutputRing: Sendable {
    public let capacity: Int
    private var storage: [UInt8] = []
    /// Index of the oldest byte.
    private var head = 0
    private var filled = 0

    public init(capacity: Int = 1 << 20) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if data.count >= capacity {
            // One write larger than the whole ring: keep its tail.
            storage = [UInt8](data.suffix(capacity))
            if storage.count < capacity {
                storage.append(contentsOf: [UInt8](repeating: 0, count: capacity - storage.count))
            }
            head = 0
            filled = capacity
            return
        }
        if storage.count < capacity {
            storage = [UInt8](repeating: 0, count: capacity)
        }
        var index = (head + filled) % capacity
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            var copied = 0
            while copied < source.count {
                let chunk = min(source.count - copied, capacity - index)
                storage.replaceSubrange(index..<index + chunk,
                                        with: source[copied..<copied + chunk])
                index = (index + chunk) % capacity
                copied += chunk
            }
        }
        let overflow = filled + data.count - capacity
        if overflow > 0 {
            head = (head + overflow) % capacity
            filled = capacity
        } else {
            filled += data.count
        }
    }

    public var contents: Data {
        guard filled > 0 else { return Data() }
        let end = head + filled
        if end <= capacity {
            return Data(storage[head..<end])
        }
        return Data(storage[head..<capacity]) + Data(storage[0..<end - capacity])
    }

    public var count: Int { filled }
}
