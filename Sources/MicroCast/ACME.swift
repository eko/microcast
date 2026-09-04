import CryptoKit
import Foundation

enum ACMEError: LocalizedError {
	case server(type: String, detail: String)
	case badResponse(String)
	case challengeFailed(host: String, detail: String)
	case timeout(String)

	var errorDescription: String? {
		switch self {
		case .server(let type, let detail): "Let's Encrypt: \(detail) (\(type.split(separator: ":").last ?? ""))"
		case .badResponse(let what): "unexpected ACME response: \(what)"
		case .challengeFailed(let host, let detail): "validation of \(host) failed: \(detail)"
		case .timeout(let what): "timed out waiting for \(what)"
		}
	}
}

enum Base64URL {
	static func encode(_ data: Data) -> String {
		data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
	}
}

/// The ES256 account key and the JWS/JWK pieces RFC 8555 needs from it.
struct ACMEAccountKey {
	let key: P256.Signing.PrivateKey

	init() { key = P256.Signing.PrivateKey() }
	init(rawRepresentation: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
	var rawRepresentation: Data { key.rawRepresentation }

	var jwk: [String: String] {
		let point = key.publicKey.rawRepresentation
		return ["kty": "EC", "crv": "P-256", "x": Base64URL.encode(point.prefix(32)), "y": Base64URL.encode(point.suffix(32))]
	}

	/// RFC 7638: SHA-256 of the JWK with its required members in lexicographic order, no whitespace.
	var thumbprint: String {
		let jwk = jwk
		let canonical = "{\"crv\":\"\(jwk["crv"]!)\",\"kty\":\"EC\",\"x\":\"\(jwk["x"]!)\",\"y\":\"\(jwk["y"]!)\"}"
		return Base64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
	}

	func sign(_ signingInput: String) throws -> String {
		try Base64URL.encode(key.signature(for: Data(signingInput.utf8)).rawRepresentation)
	}

	/// Flattened JWS as ACME wants it; `payload` nil means POST-as-GET.
	func jws(url: URL, nonce: String, kid: String?, payload: Data?) throws -> Data {
		var header: [String: Any] = ["alg": "ES256", "nonce": nonce, "url": url.absoluteString]
		if let kid { header["kid"] = kid } else { header["jwk"] = jwk }
		let protected = try Base64URL.encode(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
		let body = payload.map(Base64URL.encode) ?? ""
		let signature = try sign("\(protected).\(body)")
		return try JSONSerialization.data(withJSONObject: ["protected": protected, "payload": body, "signature": signature])
	}

	/// What HTTP-01 serves verbatim; DNS-01 publishes its hash.
	func keyAuthorization(token: String) -> String { "\(token).\(thumbprint)" }

	/// The DNS-01 TXT value for a challenge token.
	func dnsChallengeValue(token: String) -> String {
		Base64URL.encode(Data(SHA256.hash(data: Data(keyAuthorization(token: token).utf8))))
	}
}

/// Where the app publishes challenge answers: a DNS TXT record, or a file under /.well-known on port 80.
enum ACMEChallenge {
	case dns01(publish: (_ txtValue: String) async throws -> Void)
	case http01(publish: (_ token: String, _ keyAuthorization: String) async throws -> Void)

	var type: String {
		switch self {
		case .dns01: "dns-01"
		case .http01: "http-01"
		}
	}
}

/// Token → key authorization for HTTP-01, served by the HTTP listener at /.well-known/acme-challenge/<token>.
final class ACMEChallengeStore: @unchecked Sendable {
	private let lock = NSLock()
	private var answers: [String: String] = [:]

	func publish(token: String, keyAuthorization: String) {
		lock.withLock { answers[token] = keyAuthorization }
	}

	func answer(for token: String) -> String? {
		lock.withLock { answers[token] }
	}
}

/// A small RFC 8555 client: account, order, one challenge at a time, finalize, download.
final class ACMEClient {
	static let production = URL(string: "https://acme-v02.api.letsencrypt.org/directory")!
	static let staging = URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!

	private let directoryURL: URL
	private let account: ACMEAccountKey
	private var directory: [String: String] = [:]
	private var nonce: String?
	private(set) var kid: String?
	private let session = URLSession(configuration: .ephemeral)
	var log: (String) -> Void = { _ in }

	init(directoryURL: URL, account: ACMEAccountKey) {
		self.directoryURL = directoryURL
		self.account = account
	}

	func register(email: String?) async throws {
		if directory.isEmpty {
			let (data, _) = try await session.data(from: directoryURL)
			guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ACMEError.badResponse("directory") }
			directory = json.compactMapValues { $0 as? String }
		}
		var payload: [String: Any] = ["termsOfServiceAgreed": true]
		if let email, !email.isEmpty { payload["contact"] = ["mailto:\(email)"] }
		let (_, response) = try await post(directory["newAccount"], payload: payload, useJWK: true)
		guard let location = response.value(forHTTPHeaderField: "Location") else { throw ACMEError.badResponse("account location") }
		kid = location
	}

	/// Issues a certificate for `hosts`, publishing each challenge answer through `challenge`.
	func issue(hosts: [String], challenge: ACMEChallenge) async throws -> (certificatePEM: String, privateKeyPEM: String) {
		let (orderData, orderResponse) = try await post(directory["newOrder"], payload: ["identifiers": hosts.map { ["type": "dns", "value": $0] }])
		guard let orderURL = orderResponse.value(forHTTPHeaderField: "Location").flatMap(URL.init) else { throw ACMEError.badResponse("order location") }
		var order = try json(orderData)
		for authorizationURL in (order["authorizations"] as? [String] ?? []) {
			try await authorize(URL(string: authorizationURL)!, challenge: challenge)
		}
		let (keyPEM, csr) = try Self.makeCSR(hosts: hosts)
		guard let finalize = order["finalize"] as? String else { throw ACMEError.badResponse("finalize URL") }
		_ = try await post(finalize, payload: ["csr": Base64URL.encode(csr)])
		for _ in 0..<30 {
			let (data, _) = try await post(orderURL.absoluteString, payload: nil)
			order = try json(data)
			switch order["status"] as? String {
			case "valid":
				guard let certificateURL = order["certificate"] as? String else { throw ACMEError.badResponse("certificate URL") }
				let (pem, _) = try await post(certificateURL, payload: nil, accept: "application/pem-certificate-chain")
				return (String(decoding: pem, as: UTF8.self), keyPEM)
			case "invalid":
				throw ACMEError.badResponse("order became invalid")
			default:
				try await Task.sleep(for: .seconds(2))
			}
		}
		throw ACMEError.timeout("the certificate")
	}

	private func authorize(_ url: URL, challenge method: ACMEChallenge) async throws {
		var (data, _) = try await post(url.absoluteString, payload: nil)
		var authorization = try json(data)
		let host = (authorization["identifier"] as? [String: Any])?["value"] as? String ?? "?"
		if authorization["status"] as? String == "valid" { return }
		guard let challenges = authorization["challenges"] as? [[String: Any]],
			let challenge = challenges.first(where: { $0["type"] as? String == method.type }),
			let token = challenge["token"] as? String, let challengeURL = challenge["url"] as? String else {
			throw ACMEError.badResponse("no \(method.type) challenge for \(host)")
		}
		switch method {
		case .dns01(let publish):
			log("Publishing the DNS challenge for \(host)…")
			try await publish(account.dnsChallengeValue(token: token))
			try await Task.sleep(for: .seconds(20)) // let the record propagate before the CA looks
		case .http01(let publish):
			log("Answering the HTTP challenge for \(host)…")
			try await publish(token, account.keyAuthorization(token: token))
		}
		_ = try await post(challengeURL, payload: [:])
		for _ in 0..<45 {
			try await Task.sleep(for: .seconds(2))
			(data, _) = try await post(url.absoluteString, payload: nil)
			authorization = try json(data)
			switch authorization["status"] as? String {
			case "valid": return
			case "invalid":
				let detail = (authorization["challenges"] as? [[String: Any]])?
					.compactMap { ($0["error"] as? [String: Any])?["detail"] as? String }.first ?? "rejected by the CA"
				throw ACMEError.challengeFailed(host: host, detail: detail)
			default: continue
			}
		}
		throw ACMEError.timeout("validation of \(host)")
	}

	/// EC P-256 key and a CSR with every host as a SAN, through the system openssl.
	static func makeCSR(hosts: [String]) throws -> (keyPEM: String, csr: Data) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("microcast-acme-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let keyPath = directory.appendingPathComponent("key.pem").path
		try OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyPath])
		let csr = try OpenSSL.run([
			"req", "-new", "-key", keyPath, "-outform", "DER", "-subj", "/CN=\(hosts[0])",
			"-addext", "subjectAltName=" + hosts.map { "DNS:\($0)" }.joined(separator: ","),
		])
		return (try String(contentsOfFile: keyPath, encoding: .utf8), csr)
	}

	// MARK: Transport

	private func post(_ urlString: String?, payload: Any?, useJWK: Bool = false, accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
		guard let urlString, let url = URL(string: urlString) else { throw ACMEError.badResponse("missing URL") }
		let body = try payload.map { try JSONSerialization.data(withJSONObject: $0) }
		for attempt in 0..<2 {
			let nonce = try await currentNonce()
			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/jose+json", forHTTPHeaderField: "Content-Type")
			request.setValue(accept, forHTTPHeaderField: "Accept")
			request.httpBody = try account.jws(url: url, nonce: nonce, kid: useJWK ? nil : kid, payload: body)
			let (data, raw) = try await session.data(for: request)
			guard let response = raw as? HTTPURLResponse else { throw ACMEError.badResponse("not HTTP") }
			self.nonce = response.value(forHTTPHeaderField: "Replay-Nonce")
			if (200..<300).contains(response.statusCode) { return (data, response) }
			let problem = (try? json(data)) ?? [:]
			let type = problem["type"] as? String ?? "unknown"
			if type.hasSuffix("badNonce"), attempt == 0 { continue }
			throw ACMEError.server(type: type, detail: problem["detail"] as? String ?? "HTTP \(response.statusCode)")
		}
		throw ACMEError.badResponse("nonce")
	}

	private func currentNonce() async throws -> String {
		if let nonce { self.nonce = nil; return nonce }
		guard let newNonce = directory["newNonce"].flatMap(URL.init) else { throw ACMEError.badResponse("newNonce") }
		var request = URLRequest(url: newNonce)
		request.httpMethod = "HEAD"
		let (_, raw) = try await session.data(for: request)
		guard let nonce = (raw as? HTTPURLResponse)?.value(forHTTPHeaderField: "Replay-Nonce") else { throw ACMEError.badResponse("nonce header") }
		return nonce
	}

	private func json(_ data: Data) throws -> [String: Any] {
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ACMEError.badResponse("JSON") }
		return object
	}
}
