import Security
import XCTest
@testable import MicroCast

final class HTTPServerTests: XCTestCase {
	private func handler(_ request: HTTPRequest) async -> HTTPResponse {
		guard request.method == "GET" || request.method == "HEAD" else { return .text(405, "method") }
		switch request.path {
		case "/hello":
			return .text(200, "hi \(request.query["n"] ?? "") from \(request.remoteAddress.isEmpty ? "?" : "known")")
		case "/stream":
			let (stream, continuation) = AsyncStream<Data>.makeStream()
			Task {
				continuation.yield(Data("ab".utf8))
				try? await Task.sleep(for: .milliseconds(50))
				continuation.yield(Data("cd".utf8))
				continuation.finish()
			}
			return .stream(stream, type: "text/plain", headers: ["icy-name": "T"])
		default:
			return .text(404, "no")
		}
	}

	private func freePort() -> UInt16 { UInt16.random(in: 20_000...45_000) }

	func testServesGetHeadPostAndStreamingBodies() async throws {
		let port = freePort()
		let server = try HTTPServer(port: port) { await self.handler($0) }
		try await server.start()
		defer { server.stop() }
		let session = URLSession(configuration: .ephemeral)
		let base = "http://127.0.0.1:\(port)"

		let (data, raw) = try await session.data(from: URL(string: "\(base)/hello?n=1")!)
		let response = try XCTUnwrap(raw as? HTTPURLResponse)
		XCTAssertEqual(response.statusCode, 200)
		XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi 1 from known")
		XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
		XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "15")

		var head = URLRequest(url: URL(string: "\(base)/hello")!)
		head.httpMethod = "HEAD"
		let (headData, headRaw) = try await session.data(for: head)
		XCTAssertEqual((headRaw as? HTTPURLResponse)?.statusCode, 200)
		XCTAssertEqual(headData.count, 0, "HEAD sends no body")

		var post = URLRequest(url: URL(string: "\(base)/hello")!)
		post.httpMethod = "POST"
		let (_, postRaw) = try await session.data(for: post)
		XCTAssertEqual((postRaw as? HTTPURLResponse)?.statusCode, 405)

		let (_, missing) = try await session.data(from: URL(string: "\(base)/missing")!)
		XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)

		let (streamData, streamRaw) = try await session.data(from: URL(string: "\(base)/stream")!)
		let streamResponse = try XCTUnwrap(streamRaw as? HTTPURLResponse)
		XCTAssertEqual(streamResponse.value(forHTTPHeaderField: "icy-name"), "T")
		XCTAssertNil(streamResponse.value(forHTTPHeaderField: "Content-Length"), "endless bodies have no length")
		XCTAssertEqual(String(decoding: streamData, as: UTF8.self), "abcd")
		XCTAssertEqual(server.connectionCount, 0)
	}

	func testServesHTTPSFromPEMFiles() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = directory.appendingPathComponent("key.pem"), cert = directory.appendingPathComponent("cert.pem")
		try OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
		try OpenSSL.run(["req", "-x509", "-new", "-key", key.path, "-out", cert.path, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
		XCTAssertEqual(TLSIdentity.hosts(certificatePEM: cert), ["localhost"])
		XCTAssertNotNil(TLSIdentity.expiry(certificatePEM: cert))

		// A throwaway keychain so the test never touches the user's.
		let keychainPath = directory.appendingPathComponent("test.keychain").path
		var keychain: SecKeychain?
		XCTAssertEqual(SecKeychainCreate(keychainPath, 4, "test", false, nil, &keychain), errSecSuccess)
		defer { if let keychain { SecKeychainDelete(keychain) } }
		let identity = try TLSIdentity.load(certificatePEM: cert, keyPEM: key, keychain: keychain)
		let again = try TLSIdentity.load(certificatePEM: cert, keyPEM: key, keychain: keychain)
		XCTAssertNotNil(again, "a second load finds the existing identity")

		let port = freePort()
		let server = try HTTPServer(port: port, identity: identity) { await self.handler($0) }
		try await server.start()
		defer { server.stop() }
		let session = URLSession(configuration: .ephemeral, delegate: TrustAnything(), delegateQueue: nil)
		let (data, raw) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/hello?n=tls")!)
		XCTAssertEqual((raw as? HTTPURLResponse)?.statusCode, 200)
		XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi tls from known")
	}

	private final class TrustAnything: NSObject, URLSessionDelegate {
		func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
			guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
			return (.useCredential, URLCredential(trust: trust))
		}
	}
}
