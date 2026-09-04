import CryptoKit
import XCTest
@testable import MicroCast

final class ACMETests: XCTestCase {
	func testBase64URLHasNoPaddingOrURLUnsafeCharacters() {
		let encoded = Base64URL.encode(Data([0xFB, 0xFF, 0xBF, 0x00]))
		XCTAssertEqual(encoded, "-_-_AA")
	}

	func testAccountKeyRoundTripsAndSigns() throws {
		let key = ACMEAccountKey()
		let restored = try ACMEAccountKey(rawRepresentation: key.rawRepresentation)
		XCTAssertEqual(restored.thumbprint, key.thumbprint)
		XCTAssertEqual(key.thumbprint.count, 43, "base64url of a SHA-256")
		let jws = try key.jws(url: URL(string: "https://acme.test/new-order")!, nonce: "abc", kid: "https://acme.test/acct/1", payload: Data("{}".utf8))
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jws) as? [String: String])
		let protectedJSON = try XCTUnwrap(Data(base64Encoded: pad(object["protected"]!)))
		let header = try XCTUnwrap(JSONSerialization.jsonObject(with: protectedJSON) as? [String: Any])
		XCTAssertEqual(header["alg"] as? String, "ES256")
		XCTAssertEqual(header["nonce"] as? String, "abc")
		XCTAssertEqual(header["kid"] as? String, "https://acme.test/acct/1")
		XCTAssertNil(header["jwk"], "kid and jwk are exclusive")
		let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: pad(object["signature"]!))!)
		let signingInput = Data("\(object["protected"]!).\(object["payload"]!)".utf8)
		XCTAssertTrue(key.key.publicKey.isValidSignature(signature, for: signingInput))
	}

	func testHTTPChallengeAnswerIsTokenDotThumbprint() {
		let key = ACMEAccountKey()
		XCTAssertEqual(key.keyAuthorization(token: "tok"), "tok.\(key.thumbprint)")
		let store = ACMEChallengeStore()
		store.publish(token: "tok", keyAuthorization: key.keyAuthorization(token: "tok"))
		XCTAssertEqual(store.answer(for: "tok"), "tok.\(key.thumbprint)")
		XCTAssertNil(store.answer(for: "other"))
	}

	func testDNSChallengeValueMatchesRFC8555() {
		let key = ACMEAccountKey()
		let expected = Base64URL.encode(Data(SHA256.hash(data: Data("token123.\(key.thumbprint)".utf8))))
		XCTAssertEqual(key.dnsChallengeValue(token: "token123"), expected)
	}

	func testNewAccountUsesJWK() throws {
		let key = ACMEAccountKey()
		let jws = try key.jws(url: URL(string: "https://acme.test/new-acct")!, nonce: "n", kid: nil, payload: nil)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jws) as? [String: String])
		XCTAssertEqual(object["payload"], "", "POST-as-GET has an empty payload")
		let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base64Encoded: pad(object["protected"]!))!) as? [String: Any])
		XCTAssertEqual((header["jwk"] as? [String: String])?["kty"], "EC")
	}

	func testDuckDNSURLs() {
		let url = DuckDNS.updateURL(subdomain: "mystream", token: "t0k/en", ip: nil, txt: "abc+def")
		XCTAssertEqual(url.host, "www.duckdns.org")
		let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
		XCTAssertEqual(query.first { $0.name == "domains" }?.value, "mystream")
		XCTAssertEqual(query.first { $0.name == "token" }?.value, "t0k/en")
		XCTAssertEqual(query.first { $0.name == "txt" }?.value, "abc+def")
		XCTAssertNil(query.first { $0.name == "ip" })
		XCTAssertEqual(DuckDNS.updateURL(subdomain: "a", token: "b").query, "domains=a&token=b&ip=")
		XCTAssertEqual(DuckDNS.updateURL(subdomain: "a", token: "b", ip: "1.2.3.4", ipv6: "").query, "domains=a&token=b&ip=1.2.3.4&ipv6=")
		XCTAssertEqual(DuckDNS.updateURL(subdomain: "a", token: "b", ip: nil, clear: true).query, "domains=a&token=b&clear=true")
	}

	func testDNSNamesParsing() {
		let text = "            X509v3 Subject Alternative Name: \n                DNS:a.duckdns.org, DNS:Cast.Example.com\n    Signature"
		XCTAssertEqual(TLSIdentity.parseDNSNames(text), ["a.duckdns.org", "cast.example.com"])
	}

	func testCertificateExpiryParsing() throws {
		let date = try XCTUnwrap(TLSIdentity.parseNotAfter("notAfter=Sep  4 12:34:56 2026 GMT"))
		XCTAssertEqual(Int(date.timeIntervalSince1970), 1_788_525_296)
	}

	func testCSRCarriesEveryHost() throws {
		let (key, csr) = try ACMEClient.makeCSR(hosts: ["a.duckdns.org", "cast.example.com"])
		XCTAssertTrue(key.contains("PRIVATE KEY"))
		XCTAssertGreaterThan(csr.count, 200)
		let text = try String(decoding: OpenSSL.run(["req", "-inform", "DER", "-noout", "-text"], input: csr), as: UTF8.self)
		XCTAssertTrue(text.contains("DNS:a.duckdns.org, DNS:cast.example.com"))
	}

	private func pad(_ base64url: String) -> String {
		var text = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while text.count % 4 != 0 { text += "=" }
		return text
	}
}
