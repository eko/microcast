import XCTest
@testable import MicroCast

final class HTTPTests: XCTestCase {
	func testParsesRequestLineQueryAndHeaders() throws {
		let head = Data("GET /hls/128/stream.m3u8?_HLS_msn=5&_HLS_part=2 HTTP/1.1\r\nHost: mac.local\r\nConnection: close\r\nAuthorization:  Basic eDpwdw==\r\n".utf8)
		let request = try XCTUnwrap(HTTPServer.parse(head))
		XCTAssertEqual(request.method, "GET")
		XCTAssertEqual(request.path, "/hls/128/stream.m3u8")
		XCTAssertEqual(request.query, ["_HLS_msn": "5", "_HLS_part": "2"])
		XCTAssertEqual(request.headers["connection"], "close")
		XCTAssertEqual(request.headers["authorization"], "Basic eDpwdw==")
	}

	func testRejectsMalformedRequestLine() {
		XCTAssertNil(HTTPServer.parse(Data("nonsense\r\n".utf8)))
	}

	func testBasicAuthAcceptsAnyUserWithTheRightPassword() {
		func request(_ header: String?) -> HTTPRequest {
			HTTPRequest(method: "GET", path: "/", query: [:], headers: header.map { ["authorization": $0] } ?? [:])
		}
		let good = Data("anyone:secret".utf8).base64EncodedString()
		let bad = Data("anyone:nope".utf8).base64EncodedString()
		XCTAssertTrue(Router.authorized(request("Basic \(good)"), password: "secret"))
		XCTAssertTrue(Router.authorized(request("basic \(good)"), password: "secret"))
		XCTAssertFalse(Router.authorized(request("Basic \(bad)"), password: "secret"))
		XCTAssertFalse(Router.authorized(request("Bearer x"), password: "secret"))
		XCTAssertFalse(Router.authorized(request(nil), password: "secret"))
	}
}
