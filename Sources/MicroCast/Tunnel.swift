import Foundation

/// Publishes the local server on the internet through a tunnel CLI: cloudflared, ngrok, Tailscale, or your own command.
final class Tunnel {
	enum Provider: String, CaseIterable, Identifiable {
		case off, cloudflare, cloudflareNamed, ngrok, tailscale, custom, duckdns, ownHost

		var id: String { rawValue }

		var label: String {
			switch self {
			case .off: "Off"
			case .cloudflare: "Cloudflare quick tunnel"
			case .cloudflareNamed: "Cloudflare named tunnel"
			case .ngrok: "ngrok"
			case .tailscale: "Tailscale Funnel"
			case .custom: "Custom command"
			case .duckdns: "DuckDNS + HTTPS (port forwarding)"
			case .ownHost: "Own hostname + HTTPS (port forwarding)"
			}
		}
	}

	struct Configuration {
		var provider: Provider
		var port: UInt16
		var cloudflareToken = ""
		var cloudflareHostname = ""
		var customCommand = ""
	}

	enum TunnelError: LocalizedError {
		case missingBinary(String, hint: String)
		case missingSetting(String)

		var errorDescription: String? {
			switch self {
			case .missingBinary(let name, let hint): "\(name) not found (\(hint))"
			case .missingSetting(let what): "\(what) is missing"
			}
		}
	}

	private struct Launch {
		let executable: URL
		let arguments: [String]
		let urlPattern: String?
		/// Printed once the tunnel is really connected; the URL is announced only after it (DNS is not published before).
		let readyPattern: String?
		let knownURL: URL?
	}

	private let process = Process()
	private let output = Pipe()
	private let knownURL: URL?
	private let lock = NSLock()
	private var parser: TunnelOutputParser

	init(configuration: Configuration) throws {
		let launch = try Self.launch(for: configuration)
		process.executableURL = launch.executable
		process.arguments = launch.arguments
		process.standardOutput = output
		process.standardError = output
		process.standardInput = FileHandle.nullDevice
		parser = TunnelOutputParser(urlPattern: launch.urlPattern, readyPattern: launch.readyPattern)
		knownURL = launch.knownURL
	}

	/// The last lines the tunnel printed, for error messages.
	var recentOutput: String {
		lock.withLock { parser.recentOutput }
	}

	func start(onURL: @escaping (URL) -> Void, onExit: @escaping (Int32) -> Void) throws {
		output.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			guard let self, !data.isEmpty else {
				handle.readabilityHandler = nil
				return
			}
			if let url = consume(data) { onURL(url) }
		}
		process.terminationHandler = { process in onExit(process.terminationStatus) }
		try process.run()
		if let knownURL { onURL(knownURL) }
	}

	func stop() {
		output.fileHandleForReading.readabilityHandler = nil
		process.terminationHandler = nil
		if process.isRunning { process.terminate() }
	}

	private func consume(_ data: Data) -> URL? {
		lock.withLock { parser.feed(String(decoding: data, as: UTF8.self)) }
	}

	private static func launch(for configuration: Configuration) throws -> Launch {
		let port = "\(configuration.port)"
		switch configuration.provider {
		case .off, .duckdns, .ownHost:
			throw TunnelError.missingSetting("tunnel provider")
		case .cloudflare:
			return Launch(
				executable: try locate("cloudflared", hint: "brew install cloudflared"),
				arguments: ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"],
				urlPattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
				readyPattern: "Registered tunnel connection",
				knownURL: nil
			)
		case .cloudflareNamed:
			guard !configuration.cloudflareToken.isEmpty else { throw TunnelError.missingSetting("Cloudflare tunnel token") }
			let host = configuration.cloudflareHostname.trimmingCharacters(in: .whitespaces)
			return Launch(
				executable: try locate("cloudflared", hint: "brew install cloudflared"),
				arguments: ["tunnel", "--no-autoupdate", "run", "--token", configuration.cloudflareToken],
				urlPattern: nil,
				readyPattern: nil,
				knownURL: host.isEmpty ? nil : URL(string: "https://\(host)/")
			)
		case .ngrok:
			return Launch(
				executable: try locate("ngrok", hint: "brew install ngrok, then ngrok config add-authtoken …"),
				arguments: ["http", port, "--log", "stdout", "--log-format", "logfmt"],
				urlPattern: #"https://[a-z0-9.-]+\.ngrok[a-z0-9.-]*\.(?:app|dev|io)"#,
				readyPattern: nil,
				knownURL: nil
			)
		case .tailscale:
			return Launch(
				executable: try locate("tailscale", extra: ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"], hint: "install Tailscale and enable Funnel"),
				arguments: ["funnel", port],
				urlPattern: #"https://[a-z0-9.-]+\.ts\.net\S*"#,
				readyPattern: nil,
				knownURL: nil
			)
		case .custom:
			let command = configuration.customCommand.replacingOccurrences(of: "{port}", with: port).trimmingCharacters(in: .whitespaces)
			guard !command.isEmpty else { throw TunnelError.missingSetting("custom tunnel command") }
			return Launch(
				executable: URL(fileURLWithPath: "/bin/sh"),
				arguments: ["-c", "exec \(command)"],
				urlPattern: #"https://[^\s"'<>]+"#,
				readyPattern: nil,
				knownURL: nil
			)
		}
	}

	/// Apps launched from the Finder get a minimal PATH, so also look where package managers install tools.
	static func locate(_ name: String, extra: [String] = [], hint: String) throws -> URL {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
		let directories = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/share/mise/shims", "\(home)/.local/bin"] + pathDirectories
		let candidates = extra + directories.map { "\($0)/\(name)" }
		guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
			throw TunnelError.missingBinary(name, hint: hint)
		}
		return URL(fileURLWithPath: found)
	}
}

/// Watches a tunnel CLI's output for the public URL, announcing it only once the tunnel reports it is
/// connected (cloudflared prints the address a few seconds before the DNS name exists).
struct TunnelOutputParser {
	private let urlPattern: NSRegularExpression?
	private let readyPattern: NSRegularExpression?
	private var transcript = ""
	private var foundURL: URL?
	private var ready = false
	private var announced = false

	init(urlPattern: String?, readyPattern: String?) {
		self.urlPattern = urlPattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
		self.readyPattern = readyPattern.flatMap { try? NSRegularExpression(pattern: $0, options: []) }
	}

	/// The last lines seen, for error messages.
	var recentOutput: String {
		String(transcript.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Feeds more output; returns the public URL the first time it can be announced.
	mutating func feed(_ text: String) -> URL? {
		transcript += text
		let range = NSRange(transcript.startIndex..., in: transcript)
		if foundURL == nil, let urlPattern, let match = urlPattern.firstMatch(in: transcript, range: range),
			let matchRange = Range(match.range, in: transcript) {
			foundURL = URL(string: String(transcript[matchRange]))
		}
		if !ready, readyPattern?.firstMatch(in: transcript, range: range) != nil { ready = true }
		if transcript.count > 4000 { transcript = String(transcript.suffix(2000)) }
		guard !announced, let foundURL, ready || readyPattern == nil else { return nil }
		announced = true
		return foundURL
	}
}
