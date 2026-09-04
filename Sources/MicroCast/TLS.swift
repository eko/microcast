import Foundation
import Security

enum TLSError: LocalizedError {
	case openssl(String)
	case importFailed(OSStatus)
	case noIdentity

	var errorDescription: String? {
		switch self {
		case .openssl(let message): "openssl: \(message)"
		case .importFailed(let status): "certificate import failed (\(status))"
		case .noIdentity: "no identity found in the certificate"
		}
	}
}

/// Runs the system `openssl` (LibreSSL, present on every Mac) for key, CSR and PKCS#12 work.
enum OpenSSL {
	@discardableResult
	static func run(_ arguments: [String], input: Data? = nil) throws -> Data {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
		process.arguments = arguments
		let output = Pipe(), errors = Pipe()
		process.standardOutput = output
		process.standardError = errors
		if input != nil {
			let stdin = Pipe()
			process.standardInput = stdin
			try process.run()
			stdin.fileHandleForWriting.write(input!)
			try? stdin.fileHandleForWriting.close()
		} else {
			process.standardInput = FileHandle.nullDevice
			try process.run()
		}
		let data = output.fileHandleForReading.readDataToEndOfFile()
		let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw TLSError.openssl(errorText.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)")
		}
		return data
	}
}

enum TLSIdentity {
	/// A `SecIdentity` for Network.framework from PEM files, via a PKCS#12 bundle (the only public way in).
	/// Imports into the default keychain unless `keychain` is given (tests use a throwaway one).
	static func load(certificatePEM: URL, keyPEM: URL, keychain: SecKeychain? = nil) throws -> SecIdentity {
		let bundle = try OpenSSL.run(["pkcs12", "-export", "-inkey", keyPEM.path, "-in", certificatePEM.path, "-passout", "pass:microcast"])
		var items: CFArray?
		var options: [String: Any] = [kSecImportExportPassphrase as String: "microcast"]
		if let keychain { options[kSecImportExportKeychain as String] = keychain }
		let status = SecPKCS12Import(bundle as CFData, options as CFDictionary, &items)
		if status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] {
			return identity as! SecIdentity // swiftlint:disable:this force_cast
		}
		guard status == errSecDuplicateItem else { throw TLSError.importFailed(status) }
		// Already in the keychain from a previous run: find it by its certificate.
		let der = try OpenSSL.run(["x509", "-in", certificatePEM.path, "-outform", "DER"])
		var result: CFTypeRef?
		var query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
		if let keychain { query[kSecMatchSearchList as String] = [keychain] }
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { throw TLSError.noIdentity }
		for identity in identities {
			var certificate: SecCertificate?
			if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
				SecCertificateCopyData(certificate) as Data == der {
				return identity
			}
		}
		throw TLSError.noIdentity
	}

	/// `notAfter` of the first certificate in the PEM file.
	static func expiry(certificatePEM: URL) -> Date? {
		guard let output = try? OpenSSL.run(["x509", "-in", certificatePEM.path, "-noout", "-enddate"]) else { return nil }
		return parseNotAfter(String(decoding: output, as: UTF8.self))
	}

	/// The DNS names in the certificate's subjectAltName, lowercased.
	static func hosts(certificatePEM: URL) -> [String] {
		guard let output = try? OpenSSL.run(["x509", "-in", certificatePEM.path, "-noout", "-text"]) else { return [] }
		return parseDNSNames(String(decoding: output, as: UTF8.self))
	}

	static func parseDNSNames(_ text: String) -> [String] {
		text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
			.compactMap { $0.hasPrefix("DNS:") ? String($0.dropFirst(4)).lowercased() : nil }
	}

	/// "notAfter=Sep  4 12:00:00 2026 GMT"
	static func parseNotAfter(_ text: String) -> Date? {
		guard let value = text.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
		return formatter.date(from: value.replacingOccurrences(of: "  ", with: " "))
	}
}
