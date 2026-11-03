//
//  ConnectionLossTests.swift
//  SignalRClientUnitTests
//
//  Covers a connection that drops while the app is waiting on the server: pending invocations,
//  keep-alive after a reconnect, and the server timeout for half-open sockets.
//  Runs against an in-memory connection, so no test server is needed.
//

import XCTest
@testable import SignalRClient

class ConnectionLossTests: XCTestCase {

    private let handshakeResponse = "{}\u{1e}".data(using: .utf8)!
    private let pingMessage = "{\"type\":6}\u{1e}".data(using: .utf8)!

    // MARK: Pending invocations

    func testPendingInvocationFailsWhenConnectionStartsReconnecting() {
        let connection = FakeConnection()
        let hubConnection = makeOpenHubConnection(connection: connection)
        let invocationFailed = expectation(description: "invocation failed")

        hubConnection.invoke(method: "CreatePayment", arguments: []) { error in
            guard case .connectionIsReconnecting = error as? SignalRError else {
                return XCTFail("Unexpected error: \(String(describing: error))")
            }
            invocationFailed.fulfill()
        }
        waitUntil { connection.sentMessages.contains { $0.contains("CreatePayment") } }

        connection.delegate?.connectionWillReconnect(error: SignalRError.invalidOperation(message: "network lost"))

        wait(for: [invocationFailed], timeout: 2)
    }

    func testInvocationAfterReconnectStartedFailsImmediately() {
        let connection = FakeConnection()
        let hubConnection = makeOpenHubConnection(connection: connection)
        connection.delegate?.connectionWillReconnect(error: SignalRError.invalidOperation(message: "network lost"))
        let invocationFailed = expectation(description: "invocation failed")

        hubConnection.invoke(method: "CreatePayment", arguments: []) { error in
            XCTAssertNotNil(error)
            invocationFailed.fulfill()
        }

        wait(for: [invocationFailed], timeout: 2)
    }

    // MARK: Keep-alive

    func testKeepAlivePingsResumeAfterReconnect() {
        let options = HubConnectionOptions()
        options.keepAliveInterval = 0.1
        options.serverTimeoutInterval = nil
        let connection = FakeConnection()
        _ = makeOpenHubConnection(connection: connection, options: options)

        connection.delegate?.connectionWillReconnect(error: SignalRError.invalidOperation(message: "network lost"))
        // A ping due while reconnecting must not end the pings for good.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        connection.delegate?.connectionDidReconnect()
        connection.delegate?.connectionDidReceiveData(connection: connection, data: handshakeResponse)
        connection.clearSentMessages()

        // Without a ping the server drops an idle client after its ClientTimeoutInterval.
        waitUntil(timeout: 1) { connection.sentMessages.contains { $0.contains("\"type\":6") } }
    }

    // MARK: Server timeout

    func testSilentServerAbortsConnectionAfterServerTimeout() {
        let options = HubConnectionOptions()
        options.keepAliveInterval = nil
        options.serverTimeoutInterval = 0.2
        let connection = FakeConnection()
        _ = makeOpenHubConnection(connection: connection, options: options)

        waitUntil(timeout: 1) { connection.abortErrors.count == 1 }
        XCTAssertTrue(connection.stopErrors.isEmpty, "A server timeout must reconnect, not stop the connection")
    }

    func testServerMessagesPostponeServerTimeout() {
        let options = HubConnectionOptions()
        options.keepAliveInterval = nil
        options.serverTimeoutInterval = 0.3
        let connection = FakeConnection()
        _ = makeOpenHubConnection(connection: connection, options: options)

        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            connection.delegate?.connectionDidReceiveData(connection: connection, data: pingMessage)
        }

        XCTAssertTrue(connection.abortErrors.isEmpty)
    }

    func testServerTimeoutStopsWhileReconnecting() {
        let options = HubConnectionOptions()
        options.keepAliveInterval = nil
        options.serverTimeoutInterval = 0.2
        let connection = FakeConnection()
        _ = makeOpenHubConnection(connection: connection, options: options)

        connection.delegate?.connectionWillReconnect(error: SignalRError.invalidOperation(message: "network lost"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(connection.abortErrors.isEmpty)
    }

    func testServerTimeoutIsSkippedForInherentKeepAlive() {
        let options = HubConnectionOptions()
        options.keepAliveInterval = nil
        options.serverTimeoutInterval = 0.2
        let connection = FakeConnection()
        connection.inherentKeepAlive = true
        _ = makeOpenHubConnection(connection: connection, options: options)

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(connection.abortErrors.isEmpty)
    }

    // MARK: ReconnectableConnection.abort

    func testAbortOfRunningConnectionReconnectsInsteadOfStopping() {
        let delegate = RecordingConnectionDelegate()
        let willReconnect = expectation(description: "will reconnect")
        let didReconnect = expectation(description: "did reconnect")
        delegate.onWillReconnect = { willReconnect.fulfill() }
        delegate.onDidReconnect = { didReconnect.fulfill() }
        let connection = ReconnectableConnection(connectionFactory: { FakeConnection() },
                                                 reconnectPolicy: DefaultReconnectPolicy(retryIntervals: [.milliseconds(10)]),
                                                 callbackQueue: DispatchQueue.main,
                                                 logger: NullLogger())
        connection.delegate = delegate
        connection.start(resetRetryAttemts: false)
        waitUntil { delegate.didOpen }

        connection.abort(error: SignalRError.invalidOperation(message: "Server timeout elapsed"))

        wait(for: [willReconnect, didReconnect], timeout: 2)
        XCTAssertFalse(delegate.didClose)
        connection.stop(stopError: nil)
    }

    func testAbortIsIgnoredWhenConnectionIsNotRunning() {
        let delegate = RecordingConnectionDelegate()
        let connection = ReconnectableConnection(connectionFactory: { FakeConnection() },
                                                 reconnectPolicy: DefaultReconnectPolicy(retryIntervals: [.milliseconds(10)]),
                                                 callbackQueue: DispatchQueue.main,
                                                 logger: NullLogger())
        connection.delegate = delegate

        connection.abort(error: SignalRError.invalidOperation(message: "Server timeout elapsed"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertFalse(delegate.willReconnect)
        XCTAssertFalse(delegate.didClose)
    }

    // MARK: Helpers

    private func makeOpenHubConnection(connection: FakeConnection,
                                       options: HubConnectionOptions = HubConnectionOptions()) -> HubConnection {
        let hubConnection = HubConnection(connection: connection,
                                          hubProtocol: JSONHubProtocol(logger: NullLogger()),
                                          hubConnectionOptions: options)
        let delegate = OpenWaitingHubDelegate()
        hubConnection.delegate = delegate
        hubConnection.start(resetRetryAttemts: false)
        connection.delegate?.connectionDidReceiveData(connection: connection, data: handshakeResponse)
        waitUntil { delegate.didOpen }
        connection.clearSentMessages()
        // Timers hold the hub connection weakly, and tests that only watch the fake would drop it.
        retained.append(contentsOf: [hubConnection, delegate] as [AnyObject])
        return hubConnection
    }

    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout)s", file: file, line: line)
    }
}

// MARK: - Fakes

private final class FakeConnection: Connection {
    var state: HttpConnection.State = .initial
    weak var delegate: ConnectionDelegate?
    var inherentKeepAlive = false
    var connectionId: String? = "fake-connection"

    private let lock = NSLock()
    private var sent: [String] = []
    private var aborts: [Error] = []
    private var stops: [Error?] = []

    var sentMessages: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    var abortErrors: [Error] { lock.lock(); defer { lock.unlock() }; return aborts }
    var stopErrors: [Error?] { lock.lock(); defer { lock.unlock() }; return stops }

    func clearSentMessages() {
        lock.lock(); sent.removeAll(); lock.unlock()
    }

    func start(resetRetryAttemts: Bool) {
        state = .connected
        delegate?.transportConnectionDidOpen(connection: self)
    }

    func send(data: Data, sendDidComplete: @escaping (Error?) -> Void) {
        lock.lock(); sent.append(String(decoding: data, as: UTF8.self)); lock.unlock()
        DispatchQueue.global().async { sendDidComplete(nil) }
    }

    func stop(stopError: Error?) {
        lock.lock(); stops.append(stopError); lock.unlock()
        state = .stopped
        DispatchQueue.global().async { [weak self] in
            self?.delegate?.connectionDidClose(error: stopError)
        }
    }

    func abort(error: Error) {
        lock.lock(); aborts.append(error); lock.unlock()
    }
}

private final class OpenWaitingHubDelegate: HubConnectionDelegate {
    var didOpen = false

    func hubConnectionDidOpen(hubConnection: HubConnection) { didOpen = true }
    func hubConnectionDidFailToOpen(error: Error) {}
    func hubConnectionDidClose(error: Error?) {}
    func currentReconnectionAttempt(currentAttempt: Int) {}
}

private final class RecordingConnectionDelegate: ConnectionDelegate {
    var didOpen = false
    var willReconnect = false
    var didClose = false
    var onWillReconnect: (() -> Void)?
    var onDidReconnect: (() -> Void)?

    func transportConnectionDidOpen(connection: Connection) { didOpen = true }
    func hubConnectionDidOpen(connection: Connection) { didOpen = true }
    func connectionDidFailToOpen(error: Error) {}
    func connectionDidReceiveData(connection: Connection, data: Data) {}
    func connectionDidClose(error: Error?) { didClose = true }
    func connectionWillReconnect(error: Error) {
        willReconnect = true
        onWillReconnect?()
    }
    func connectionDidReconnect() { onDidReconnect?() }
    func currentReconnectionAttempt(currentAttempt: Int) {}
}
