import XCTest
import SkylightDaemonCore

final class WireTests: XCTestCase {
    func testDecoderSurvivesFuzzedStreams() {
        // The daemon feeds every socket byte through this decoder; whatever
        // arrives, the only acceptable outcomes are frames, a clean throw
        // (the caller drops the connection), or waiting for more — never a
        // crash, never runaway memory.
        var seed: UInt64 = 0xF0221
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 16
        }
        for _ in 0..<300 {
            var buffer = Data((0..<(next() % 512)).map { _ in UInt8(truncatingIfNeeded: next()) })
            let before = buffer.count
            do {
                let frames = try Wire.decodeAvailable(&buffer)
                // Whatever was consumed must be accounted for by frames.
                let consumed = before - buffer.count
                let framed = frames.reduce(0) { $0 + 5 + $1.payload.count }
                XCTAssertEqual(consumed, framed)
            } catch {
                // A throw is a valid verdict on garbage; the stream is dead.
            }
        }
    }

    func testFrameRoundTrip() throws {
        let frame = WireFrame(type: .input,
                              payload: WirePayload.idPrefixed(UUID(), Data("ls\r".utf8)))
        var buffer = Wire.encode(frame)
        let decoded = try Wire.decodeAvailable(&buffer)
        XCTAssertEqual(decoded, [frame])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTornFramesDecodeAcrossReads() throws {
        let a = WireFrame(type: .attach, payload: WirePayload.uuidData(UUID()))
        let b = WireFrame(type: .list)
        let stream = Wire.encode(a) + Wire.encode(b)
        // Deliver byte by byte: every prefix decodes only what is complete.
        var buffer = Data()
        var decoded: [WireFrame] = []
        for byte in stream {
            buffer.append(byte)
            decoded += try Wire.decodeAvailable(&buffer)
        }
        XCTAssertEqual(decoded, [a, b])
    }

    func testUnknownTypeAndOversizeThrow() {
        var junk = Data([0x7F, 0, 0, 0, 0])
        XCTAssertThrowsError(try Wire.decodeAvailable(&junk))
        var huge = Data([WireType.input.rawValue, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try Wire.decodeAvailable(&huge))
    }

    func testResizeAndExitedCodecs() {
        let id = UUID()
        let resize = ResizePayload(id: id, columns: 213, rows: 58,
                                   widthPixels: 1704, heightPixels: 1160)
        XCTAssertEqual(WirePayload.parseResize(WirePayload.encodeResize(resize)), resize)
        let exited = WirePayload.parseExited(WirePayload.encodeExited(id, code: -13))
        XCTAssertEqual(exited?.id, id)
        XCTAssertEqual(exited?.code, -13)
    }

    func testIDPrefixedRejectsShortData() {
        XCTAssertNil(WirePayload.parseIDPrefixed(Data([1, 2, 3])))
        XCTAssertNil(WirePayload.parseResize(WirePayload.uuidData(UUID()) + Data([0])))
    }

    func testOutputRingMatchesNaiveModelThroughWraps() {
        // The circular implementation must be indistinguishable from the
        // obvious keep-the-last-N-bytes model, through many wraps, odd chunk
        // sizes, and an occasional oversized write.
        var ring = OutputRing(capacity: 257)   // prime: exercises misaligned wraps
        var model = Data()
        var seed: UInt64 = 0x5EED
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for i in 0..<500 {
            let size = i % 37 == 0 ? 300 + next() % 100 : 1 + next() % 90
            let byte = UInt8(truncatingIfNeeded: next())
            let chunk = Data(repeating: byte, count: size) + Data([UInt8(i & 0xFF)])
            ring.append(chunk)
            model.append(chunk)
            if model.count > 257 { model.removeFirst(model.count - 257) }
            XCTAssertEqual(ring.contents, model, "diverged at append \(i)")
            XCTAssertEqual(ring.count, model.count)
        }
    }

    func testOutputRingKeepsTheTail() {
        var ring = OutputRing(capacity: 10)
        ring.append(Data("abcdef".utf8))
        ring.append(Data("ghij".utf8))          // exactly full
        XCTAssertEqual(ring.contents, Data("abcdefghij".utf8))
        ring.append(Data("KL".utf8))            // oldest two fall off
        XCTAssertEqual(ring.contents, Data("cdefghijKL".utf8))
        ring.append(Data("0123456789ABCDEF".utf8))   // oversized single write
        XCTAssertEqual(ring.contents, Data("6789ABCDEF".utf8))
    }
}
