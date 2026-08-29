import XCTest
import SkylightDaemonCore

final class WireTests: XCTestCase {
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
