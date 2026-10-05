import XCTest
@testable import LottieDeveloperMac

/// Кадры посредника должны совпадать с relay/src/protocol.ts.
final class RelayFramesTests: XCTestCase {
    func testSmallRequestIsOneFrame() {
        var a = RelayFrames.Assembler()
        let body = Data("{\"jsonrpc\":\"2.0\"}".utf8).base64EncodedString()
        let r = a.add(#"{"t":"req","id":"1","method":"POST","path":"/mcp","query":"x=1","headers":{"authorization":"Bearer T"},"body":"\#(body)","more":false}"#)
        guard case .request(let req) = r else { return XCTFail("no request") }
        XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(req.headers["authorization"], "Bearer T")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "{\"jsonrpc\":\"2.0\"}")
    }

    func testChunkedRequestReassembles() {
        var a = RelayFrames.Assembler()
        let p1 = Data(repeating: 1, count: 10).base64EncodedString(), p2 = Data(repeating: 2, count: 5).base64EncodedString()
        XCTAssertEqual(a.add(#"{"t":"req","id":"z","method":"PUT","path":"/api/upload","query":"","headers":{},"body":"\#(p1)","more":true}"#), .none)
        guard case .request(let req) = a.add(#"{"t":"req-body","id":"z","body":"\#(p2)","more":false}"#) else { return XCTFail() }
        XCTAssertEqual(req.body, Data(repeating: 1, count: 10) + Data(repeating: 2, count: 5))
    }

    func testLargeResponseSplitsIntoChunks() throws {
        let body = Data((0..<(RelayFrames.chunk * 2 + 3)).map { UInt8($0 % 251) })
        let frames = RelayFrames.responseFrames(id: "r", status: 200, headers: ["Content-Type": "image/png"], body: body)
        XCTAssertEqual(frames.count, 3)
        let objs = try frames.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(objs.map { $0["t"] as! String }, ["res", "res-body", "res-body"])
        XCTAssertEqual(objs.map { $0["more"] as! Bool }, [true, true, false])
        XCTAssertEqual(objs[0]["status"] as? Int, 200)
        let joined = objs.reduce(Data()) { $0 + Data(base64Encoded: $1["body"] as! String)! }
        XCTAssertEqual(joined, body)
    }

    func testQueryDecoding() {
        XCTAssertEqual(RelayFrames.parseQuery("name=a%20b.zip&path=%2Fx&flag"), ["name": "a b.zip", "path": "/x", "flag": ""])
    }
}
