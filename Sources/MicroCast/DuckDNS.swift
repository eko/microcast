import Foundation
import os
import Security

enum DuckDNSError: LocalizedError {
	case rejected(String)

	var errorDescription: String? {
		switch self {
		case .rejected(let what): "DuckDNS refused the \(what) update: check the subdomain and token"
		}
	}
}

/// The DuckDNS HTTP API: one call updates the address, another sets the TXT record Let's Encrypt reads.
struct DuckDNS {
	let subdomain: String
	let token: String
	var session = URLSession.shared

	var host: String { "\(subdomain).duckdns.org" }

	static func updateURL(subdomain: String, token: String, ip: String? = "", ipv6: String? = nil, txt: String? = nil, clear: Bool = false) -> URL {
		var components = URLComponents(string: "https://www.duckdns.org/update")!
		var items = [URLQueryItem(name: "domains", value: subdomain), URLQueryItem(name: "token", value: token)]
		if let ip { items.append(URLQueryItem(name: "ip", value: ip)) }
		if let ipv6 { items.append(URLQueryItem(name: "ipv6", value: ipv6)) }
		if let txt { items.append(URLQueryItem(name: "txt", value: txt)) }
		if clear { items.append(URLQueryItem(name: "clear", value: "true")) }
		components.queryItems = items
		return components.url!
	}

	/// Points the name at this Mac's public IPv4 address. Letting DuckDNS detect the address is not enough: when
	/// the request travels over IPv6 it records an AAAA too, browsers then bypass the router's port forwarding
	/// and hit the Mac directly on a port nothing listens on.
	func updateIP() async throws {
		let ipv4 = await Self.publicIPv4()
		try await call(Self.updateURL(subdomain: subdomain, token: token, ip: ipv4 ?? "", ipv6: ipv4 == nil ? nil : ""), what: "address")
	}

	/// Removes both address records, used once at start so a stale IPv6 entry cannot linger.
	func clearAddresses() async throws {
		try await call(Self.updateURL(subdomain: subdomain, token: token, ip: nil, clear: true), what: "address")
	}

	/// Asks an IPv4-only endpoint, so the answer is the address the router forwards for.
	static func publicIPv4() async -> String? {
		for endpoint in ["https://api4.ipify.org", "https://ipv4.icanhazip.com"] {
			if let url = URL(string: endpoint), let (data, _) = try? await URLSession.shared.data(from: url) {
				let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
				if text.split(separator: ".").count == 4, text.allSatisfy({ $0.isNumber || $0 == "." }) { return text }
			}
		}
		return nil
	}

	func setTXT(_ value: String) async throws {
		try await call(Self.updateURL(subdomain: subdomain, token: token, ip: nil, txt: value), what: "TXT")
	}

	func clearTXT() async throws {
		try await call(Self.updateURL(subdomain: subdomain, token: token, ip: nil, txt: "", clear: true), what: "TXT")
	}

	private func call(_ url: URL, what: String) async throws {
		let (data, _) = try await session.data(from: url)
		guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else { throw DuckDNSError.rejected(what) }
	}
}

/// Keeps a public name usable and a Let's Encrypt certificate fresh; the "tunnel" for people who forward a
/// port on their router. Either DuckDNS (the app updates the address, DNS-01 certificate check) or a hostname
/// kept current by the router's own DynDNS (HTTP-01 check through port 80).
final class DuckDNSPublisher {
	enum Mode {
		case duckdns(subdomain: String, token: String, customHostname: String)
		case hostname(String)
	}

	struct Configuration {
		var mode: Mode
		var publicPort: Int
		var https: Bool
		var email: String
		var staging = false
	}

	let configuration: Configuration
	private let challenges: ACMEChallengeStore
	private let logger = Logger(subsystem: "local.microcast", category: "duckdns")
	private var tasks: [Task<Void, Never>] = []

	init(configuration: Configuration, challenges: ACMEChallengeStore) {
		self.configuration = configuration
		self.challenges = challenges
	}

	private var duck: DuckDNS? {
		if case .duckdns(let subdomain, let token, _) = configuration.mode { return DuckDNS(subdomain: subdomain, token: token) }
		return nil
	}

	private var hosts: [String] {
		switch configuration.mode {
		case .duckdns(_, _, let customHostname):
			let custom = customHostname.trimmingCharacters(in: .whitespaces).lowercased()
			return custom.isEmpty ? [duck!.host] : [duck!.host, custom]
		case .hostname(let hostname):
			return [hostname.trimmingCharacters(in: .whitespaces).lowercased()]
		}
	}

	/// The address listeners use: the custom name when set, else the DuckDNS one.
	var publicURL: URL {
		let scheme = configuration.https ? "https" : "http"
		let defaultPort = configuration.https ? 443 : 80
		let port = configuration.publicPort == defaultPort ? "" : ":\(configuration.publicPort)"
		return URL(string: "\(scheme)://\(hosts.last!)\(port)/")!
	}

	static var certificateDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MicroCast")
	}

	/// Updates the address, then obtains or reuses the certificate. `onIdentity` fires once TLS can start.
	func start(onStatus: @escaping (String) -> Void, onIdentity: @escaping (SecIdentity) -> Void, onReady: @escaping (URL) -> Void, onFailure: @escaping (String) -> Void) {
		if let duck {
			let updater = Task { [logger] in
				try? await duck.clearAddresses()
				while !Task.isCancelled {
					do {
						try await duck.updateIP()
						logger.info("DuckDNS address updated")
					} catch {
						logger.error("DuckDNS update failed: \(error.localizedDescription)")
					}
					try? await Task.sleep(for: .seconds(300))
				}
			}
			tasks.append(updater)
		}
		let certificate = Task {
			do {
				if let duck {
					onStatus("DuckDNS: updating the address…")
					try await duck.updateIP()
				}
				if configuration.https {
					onStatus("Checking the certificate…")
					let identity = try await ensureCertificate(onStatus: onStatus)
					onIdentity(identity)
				}
				onReady(publicURL)
			} catch {
				onFailure(error.localizedDescription)
			}
		}
		tasks.append(certificate)
		let renewal = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(12 * 3600))
				guard let self, !Task.isCancelled, configuration.https else { continue }
				if let identity = try? await ensureCertificate(onStatus: { _ in }) { onIdentity(identity) }
			}
		}
		tasks.append(renewal)
	}

	func stop() {
		tasks.forEach { $0.cancel() }
		tasks.removeAll()
	}

	/// Loads the cached certificate when it has more than 30 days left, otherwise asks Let's Encrypt for a new one.
	private func ensureCertificate(onStatus: @escaping (String) -> Void) async throws -> SecIdentity {
		let directory = Self.certificateDirectory.appendingPathComponent("certificates/\(hosts.last!)")
		let certificateFile = directory.appendingPathComponent("cert.pem")
		let keyFile = directory.appendingPathComponent("key.pem")
		let covered = TLSIdentity.hosts(certificatePEM: certificateFile)
		if let expiry = TLSIdentity.expiry(certificatePEM: certificateFile), expiry.timeIntervalSinceNow > 30 * 86_400,
			hosts.allSatisfy({ covered.contains($0) }),
			let identity = try? TLSIdentity.load(certificatePEM: certificateFile, keyPEM: keyFile) {
			logger.info("certificate valid until \(expiry)")
			return identity
		}
		if !covered.isEmpty, !hosts.allSatisfy({ covered.contains($0) }) {
			onStatus("The cached certificate lacks \(hosts.filter { !covered.contains($0) }.joined(separator: ", ")); requesting a new one…")
		}
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let client = ACMEClient(directoryURL: configuration.staging ? ACMEClient.staging : ACMEClient.production, account: try accountKey())
		client.log = onStatus
		onStatus("Requesting a certificate from Let's Encrypt…")
		try await client.register(email: configuration.email)
		let challenges = challenges
		let method: ACMEChallenge = duck.map { duck in .dns01 { value in try await duck.setTXT(value) } }
			?? .http01 { token, keyAuthorization in challenges.publish(token: token, keyAuthorization: keyAuthorization) }
		let result: (certificatePEM: String, privateKeyPEM: String)
		do {
			result = try await client.issue(hosts: hosts, challenge: method)
		} catch let error as ACMEError where hosts.count > 1 && duck != nil {
			// The custom name is usually the one missing its _acme-challenge CNAME: fall back to the DuckDNS name alone.
			let duckHost = duck!.host
			logger.error("issuing for both names failed: \(error.localizedDescription)")
			onStatus("\(error.localizedDescription). Retrying with \(duckHost) only…")
			result = try await client.issue(hosts: [duckHost], challenge: method)
		}
		if let duck { try? await duck.clearTXT() }
		try result.certificatePEM.write(to: certificateFile, atomically: true, encoding: .utf8)
		try result.privateKeyPEM.write(to: keyFile, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
		logger.info("new certificate for \(self.hosts.joined(separator: ", "))")
		return try TLSIdentity.load(certificatePEM: certificateFile, keyPEM: keyFile)
	}

	private func accountKey() throws -> ACMEAccountKey {
		let file = Self.certificateDirectory.appendingPathComponent("acme-account.key")
		if let data = try? Data(contentsOf: file), let key = try? ACMEAccountKey(rawRepresentation: data) { return key }
		let key = ACMEAccountKey()
		try FileManager.default.createDirectory(at: Self.certificateDirectory, withIntermediateDirectories: true)
		try key.rawRepresentation.write(to: file, options: .completeFileProtection)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
		return key
	}
}
