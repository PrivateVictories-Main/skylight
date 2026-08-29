import Foundation

/// The daemon's per-session memory of everything the terminal said: a
/// bounded byte ring so a reattaching client can replay recent output.
/// 1 MiB matches the pre-attach buffer inside the terminal library — past
/// that, the oldest bytes fall off; a terminal replaying the tail still
/// converges on the current screen.
public struct OutputRing: Sendable {
    public let capacity: Int
    private var storage: Data

    public init(capacity: Int = 1 << 20) {
        self.capacity = max(1, capacity)
        storage = Data()
    }

    public mutating func append(_ data: Data) {
        guard data.count < capacity else {
            // One write larger than the whole ring: keep its tail.
            storage = Data(data.suffix(capacity))
            return
        }
        storage.append(data)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public var contents: Data { storage }
    public var count: Int { storage.count }
}
