import Foundation
import Network
import os

struct HTTPRequest {
	let method: String
	let path: String
	let query: [String: String]
	let headers: [String: String]
	var remoteAddress = ""
}

enum HTTPBody {
	case data(Data)
	case stream(AsyncStream<Data>)
}

struct HTTPResponse {
	var status = 200
	var contentType = "text/plain; charset=utf-8"
	var headers: [String: String] = [:]
	var body = HTTPBody.data(Data())

	static func text(_ status: Int, _ message: String) -> HTTPResponse {
		HTTPResponse(status: status, body: .data(Data(message.utf8)))
	}

	static func data(_ data: Data, type: String, cache: String = "no-cache") -> HTTPResponse {
		HTTPResponse(contentType: type, headers: ["Cache-Control": cache], body: .data(data))
	}

	static func stream(_ stream: AsyncStream<Data>, type: String, headers: [String: String] = [:]) -> HTTPResponse {
		HTTPResponse(contentType: type, headers: headers.merging(["Cache-Control": "no-store"]) { _, new in new }, body: .stream(stream))
	}
}

enum HTTPServerError: LocalizedError {
	case invalidPort

	var errorDescription: String? { "invalid port" }
}

/// Just enough HTTP/1.1 on Network.framework: GET and HEAD, keep-alive, and endless streaming bodies.
final class HTTPServer {
	typealias Handler = (HTTPRequest) async -> HTTPResponse

	private let listener: NWListener
	private let handler: Handler
	private let queue = DispatchQueue(label: "local.microcast.http")
	private let logger = Logger(subsystem: "local.microcast", category: "http")
	private let connections = OSAllocatedUnfairLock(initialState: 0)

	var connectionCount: Int {
		connections.withLock { $0 }
	}

	/// `serviceName` advertises the server over Bonjour as an `_http._tcp` service; `identity` makes it HTTPS.
	init(port: UInt16, serviceName: String? = nil, identity: SecIdentity? = nil, handler: @escaping Handler) throws {
		guard let port = NWEndpoint.Port(rawValue: port) else { throw HTTPServerError.invalidPort }
		let parameters: NWParameters
		if let identity, let secIdentity = sec_identity_create(identity) {
			let tls = NWProtocolTLS.Options()
			sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
			sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
			parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
		} else {
			parameters = .tcp
		}
		parameters.allowLocalEndpointReuse = true
		listener = try NWListener(using: parameters, on: port)
		if let serviceName { listener.service = NWListener.Service(name: serviceName, type: "_http._tcp") }
		self.handler = handler
	}

	func start() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			listener.newConnectionHandler = { [weak self] connection in
				guard let self else { return }
				Task { await self.serve(connection) }
			}
			listener.stateUpdateHandler = { [weak self] state in
				switch state {
				case .ready:
					self?.watchFailures()
					continuation.resume()
				case .failed(let error):
					self?.listener.stateUpdateHandler = nil
					continuation.resume(throwing: error)
				default:
					break
				}
			}
			listener.start(queue: queue)
		}
	}

	func stop() {
		listener.cancel()
	}

	private func watchFailures() {
		listener.stateUpdateHandler = { [logger] state in
			if case .failed(let error) = state { logger.error("listener failed: \(error.localizedDescription)") }
		}
	}

	private func serve(_ connection: NWConnection) async {
		connections.withLock { $0 += 1 }
		defer { connections.withLock { $0 -= 1 } }
		connection.start(queue: queue)
		defer { connection.cancel() }

		let remoteAddress = Self.address(of: connection.endpoint)
		var buffer = Data()
		while var request = await readRequest(on: connection, buffer: &buffer) {
			request.remoteAddress = remoteAddress
			let response = await handler(request)
			let keepAlive = request.headers["connection"]?.lowercased() != "close"
			do {
				try await write(response, to: connection, headOnly: request.method == "HEAD", keepAlive: keepAlive)
			} catch {
				return
			}
			if case .stream = response.body { return }
			if !keepAlive { return }
		}
	}

	private func readRequest(on connection: NWConnection, buffer: inout Data) async -> HTTPRequest? {
		let terminator = Data("\r\n\r\n".utf8)
		while true {
			if let range = buffer.range(of: terminator) {
				let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
				buffer.removeSubrange(buffer.startIndex..<range.upperBound)
				return Self.parse(head)
			}
			guard buffer.count < 64 * 1024, let chunk = await receive(on: connection) else { return nil }
			buffer.append(chunk)
		}
	}

	private func receive(on connection: NWConnection) async -> Data? {
		await withCheckedContinuation { continuation in
			connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
				if let data, !data.isEmpty, error == nil {
					continuation.resume(returning: data)
				} else if isComplete || error != nil {
					continuation.resume(returning: nil)
				} else {
					continuation.resume(returning: Data())
				}
			}
		}
	}

	private static func address(of endpoint: NWEndpoint) -> String {
		if case .hostPort(let host, _) = endpoint { return "\(host)" }
		return "\(endpoint)"
	}

	/// Parses a request head (everything before the blank line). Internal for tests.
	static func parse(_ head: Data) -> HTTPRequest? {
		guard let text = String(data: head, encoding: .utf8) else { return nil }
		var lines = text.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ")
		guard requestLine.count >= 2 else { return nil }
		let target = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
		var query: [String: String] = [:]
		if target.count == 2 {
			for pair in target[1].split(separator: "&") {
				let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
				query[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
			}
		}
		var headers: [String: String] = [:]
		for line in lines {
			guard let colon = line.firstIndex(of: ":") else { continue }
			headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		let rawPath = String(target[0])
		return HTTPRequest(
			method: String(requestLine[0]),
			path: rawPath.removingPercentEncoding ?? rawPath,
			query: query,
			headers: headers
		)
	}

	private func write(_ response: HTTPResponse, to connection: NWConnection, headOnly: Bool, keepAlive: Bool) async throws {
		var headers = response.headers
		headers["Content-Type"] = response.contentType
		headers["Access-Control-Allow-Origin"] = "*"
		switch response.body {
		case .data(let data):
			headers["Content-Length"] = String(data.count)
			headers["Connection"] = keepAlive ? "keep-alive" : "close"
		case .stream:
			headers["Connection"] = "close"
		}
		var head = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
		for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
			head += "\(name): \(value)\r\n"
		}
		head += "\r\n"
		try await send(Data(head.utf8), on: connection)
		guard !headOnly else { return }
		switch response.body {
		case .data(let data):
			if !data.isEmpty { try await send(data, on: connection) }
		case .stream(let stream):
			for await chunk in stream { try await send(chunk, on: connection) }
		}
	}

	private func send(_ data: Data, on connection: NWConnection) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			connection.send(content: data, completion: .contentProcessed { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			})
		}
	}

	private static func reason(for status: Int) -> String {
		switch status {
		case 200: "OK"
		case 400: "Bad Request"
		case 401: "Unauthorized"
		case 404: "Not Found"
		case 405: "Method Not Allowed"
		case 503: "Service Unavailable"
		default: "Error"
		}
	}
}
