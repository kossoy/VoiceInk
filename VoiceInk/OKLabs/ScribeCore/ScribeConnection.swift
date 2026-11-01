import Foundation

/// The socket a `ScribeLiveSession` talks through. Production uses
/// `URLSessionScribeConnection`; tests point it at a local mock server.
public protocol ScribeConnection: AnyObject, Sendable {
    /// Starts the WebSocket handshake.
    func resume()
    /// Sends one text message. `completion` runs once the message is written (or failed).
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    /// Next text message from the server. Throws once the connection is closed or broken.
    func receive() async throws -> String
    /// HTTP status of a rejected handshake, if any.
    var handshakeStatusCode: Int? { get }
    /// Closes the connection; pending sends and receives fail.
    func close()
}

public typealias ScribeConnectionFactory = @Sendable (_ url: URL, _ apiKey: String) -> any ScribeConnection

public final class URLSessionScribeConnection: ScribeConnection, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(url: URL, apiKey: String) {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let configuration = URLSessionConfiguration.ephemeral
        // A long quiet dictation must not trip URLSession's idle timeout; the
        // session's own stall and final-wait limits bound every wait that matters.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    public static let factory: ScribeConnectionFactory = { url, apiKey in
        URLSessionScribeConnection(url: url, apiKey: apiKey)
    }

    public func resume() {
        task.resume()
    }

    public func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text)) { error in completion(error) }
    }

    public func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default:
                continue
            }
        }
    }

    public var handshakeStatusCode: Int? {
        (task.response as? HTTPURLResponse)?.statusCode
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Resumes a continuation exactly once, from whichever callback fires first.
public final class ScribeOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    public init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    public func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
