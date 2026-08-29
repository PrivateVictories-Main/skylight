import Foundation

/// The daemon protocol, framed: 1 byte type, 4 bytes big-endian payload
/// length, payload. Hot-path frames (input/output) are binary — a 16-byte
/// UUID prefix and raw bytes, never JSON.
public enum WireType: UInt8, Sendable {
    // client → daemon
    case hello = 0x01
    case spawn = 0x02
    case attach = 0x03
    case input = 0x04
    case resize = 0x05
    case kill = 0x06
    case list = 0x07
    // daemon → client
    case helloReply = 0x81
    case output = 0x82
    case exited = 0x83
    case listReply = 0x84
}

public struct WireFrame: Equatable, Sendable {
    public let type: WireType
    public let payload: Data

    public init(type: WireType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

public enum WireError: Error, Equatable {
    case unknownType(UInt8)
    case oversizedPayload(Int)
}

public enum Wire {
    /// Both ends refuse to speak across a version gap — the app and daemon
    /// ship together, so a mismatch means a stale daemon from an old build:
    /// the client asks it to exit and starts a fresh one.
    public static let protocolVersion = 1

    /// Larger than any legitimate frame (input chunks and replay slices are
    /// far smaller); a length beyond this is a corrupt stream, not data.
    public static let maxPayload = 4 << 20

    public static func encode(_ frame: WireFrame) -> Data {
        var data = Data(capacity: frame.payload.count + 5)
        data.append(frame.type.rawValue)
        var length = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    /// Decode every complete frame in `buffer`, consuming them; a trailing
    /// partial frame stays for the next read. Throws on a corrupt stream —
    /// the caller drops the connection, it does not guess.
    public static func decodeAvailable(_ buffer: inout Data) throws -> [WireFrame] {
        var frames: [WireFrame] = []
        while buffer.count >= 5 {
            let typeByte = buffer[buffer.startIndex]
            guard let type = WireType(rawValue: typeByte) else {
                throw WireError.unknownType(typeByte)
            }
            let lengthField = buffer.dropFirst().prefix(4)
            let length = lengthField.reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxPayload else { throw WireError.oversizedPayload(length) }
            guard buffer.count >= 5 + length else { break }
            let payload = Data(buffer.dropFirst(5).prefix(length))
            frames.append(WireFrame(type: type, payload: payload))
            buffer.removeFirst(5 + length)
        }
        return frames
    }
}

// MARK: - Payloads

public struct SpawnRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var argv: [String]
    public var cwd: String?
    public var env: [String: String]

    public init(id: UUID, argv: [String], cwd: String? = nil,
                env: [String: String] = [:]) {
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.env = env
    }
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var argv: [String]
    public var alive: Bool
    public var exitCode: Int32?

    public init(id: UUID, argv: [String], alive: Bool, exitCode: Int32? = nil) {
        self.id = id
        self.argv = argv
        self.alive = alive
        self.exitCode = exitCode
    }
}

public struct HelloReply: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var daemonPID: Int32
    public var sessions: [SessionInfo]
    /// One app at a time: a second concurrent client gets busy=true and no
    /// sessions — it falls back to the exec lane instead of fighting the
    /// first app's surfaces for ptys. Optional so both directions decode
    /// across the version that introduced it.
    public var busy: Bool?

    public init(protocolVersion: Int, daemonPID: Int32, sessions: [SessionInfo],
                busy: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.daemonPID = daemonPID
        self.sessions = sessions
        self.busy = busy
    }
}

public struct ResizePayload: Equatable, Sendable {
    public var id: UUID
    public var columns: UInt16
    public var rows: UInt16
    public var widthPixels: UInt16
    public var heightPixels: UInt16

    public init(id: UUID, columns: UInt16, rows: UInt16,
                widthPixels: UInt16 = 0, heightPixels: UInt16 = 0) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

/// Binary payload helpers. Every id-carrying frame leads with the UUID's 16
/// raw bytes.
public enum WirePayload {
    public static func uuidData(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    public static func uuid(from data: Data) -> UUID? {
        guard data.count >= 16 else { return nil }
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &bytes) { dest in
            data.prefix(16).copyBytes(to: dest)
        }
        return UUID(uuid: bytes)
    }

    public static func idPrefixed(_ id: UUID, _ bytes: Data) -> Data {
        var data = uuidData(id)
        data.append(bytes)
        return data
    }

    public static func parseIDPrefixed(_ data: Data) -> (id: UUID, bytes: Data)? {
        guard let id = uuid(from: data) else { return nil }
        return (id, Data(data.dropFirst(16)))
    }

    public static func encodeResize(_ resize: ResizePayload) -> Data {
        var data = uuidData(resize.id)
        for value in [resize.columns, resize.rows,
                      resize.widthPixels, resize.heightPixels] {
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0xFF))
        }
        return data
    }

    public static func parseResize(_ data: Data) -> ResizePayload? {
        guard let id = uuid(from: data) else { return nil }
        let body = Array(data.dropFirst(16))
        guard body.count >= 8 else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(body[offset]) << 8 | UInt16(body[offset + 1])
        }
        return ResizePayload(id: id, columns: u16(0), rows: u16(2),
                             widthPixels: u16(4), heightPixels: u16(6))
    }

    public static func encodeExited(_ id: UUID, code: Int32) -> Data {
        var data = uuidData(id)
        let bits = UInt32(bitPattern: code)
        for shift in [24, 16, 8, 0] {
            data.append(UInt8((bits >> UInt32(shift)) & 0xFF))
        }
        return data
    }

    public static func parseExited(_ data: Data) -> (id: UUID, code: Int32)? {
        guard let id = uuid(from: data) else { return nil }
        let body = Array(data.dropFirst(16))
        guard body.count >= 4 else { return nil }
        let bits = body[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (id, Int32(bitPattern: bits))
    }
}
