//
//  HubConnectionStartTests.swift
//  SignalRClientUnitTests
//
//  Covers repeated `HubConnection.start` calls. Apps call `start` again while the connection is
//  still connecting or reconnecting, and the connection reads its delegate on its callback queue
//  at that time. A start must not replace that delegate. Swapping it freed a delegate that the
//  callback queue was still using (EXC_BAD_ACCESS in `ReconnectableConnection.delegate.setter`).
//

import XCTest
@testable import SignalRClient

class HubConnectionStartTests: XCTestCase {

    func testRepeatedStartKeepsTheConnectionDelegate() {
        let connection = DelegateRecordingConnection()
        let hubConnection = HubConnection(connection: connection,
                                          hubProtocol: JSONHubProtocol(logger: NullLogger()))

        hubConnection.start(resetRetryAttemts: false)
        let firstDelegate = connection.delegate
        hubConnection.start(resetRetryAttemts: true)
        hubConnection.start(resetRetryAttemts: true)

        XCTAssertNotNil(firstDelegate)
        XCTAssertTrue(connection.delegate === firstDelegate)
        XCTAssertEqual(connection.delegateAssignments, 1)
        XCTAssertEqual(connection.startCalls, [false, true, true])
    }

    func testRepeatedStartWhileCallbacksReadTheDelegateDoesNotCrash() {
        let connection = DelegateRecordingConnection()
        let hubConnection = HubConnection(connection: connection,
                                          hubProtocol: JSONHubProtocol(logger: NullLogger()))
        hubConnection.start(resetRetryAttemts: false)

        let callbackQueue = DispatchQueue(label: "test.connection.callbackQueue")
        let readsDone = expectation(description: "callback queue reads finished")
        callbackQueue.async {
            for _ in 0..<20_000 {
                // What the reconnect path does on the callback queue between attempts.
                connection.delegate?.currentReconnectionAttempt(currentAttempt: 1)
            }
            readsDone.fulfill()
        }
        for _ in 0..<20_000 {
            hubConnection.start(resetRetryAttemts: true)
        }

        wait(for: [readsDone], timeout: 10)
        XCTAssertEqual(connection.delegateAssignments, 1)
    }
}

/// Records how `HubConnection` drives the connection; never opens.
private final class DelegateRecordingConnection: Connection {
    var state: HttpConnection.State = .initial
    var inherentKeepAlive = false
    var connectionId: String? = "fake-connection"

    private let lock = NSLock()
    private weak var storedDelegate: ConnectionDelegate?
    private var assignments = 0
    private var starts: [Bool] = []

    var delegate: ConnectionDelegate? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue; assignments += 1 } }
    }

    var delegateAssignments: Int { lock.withLock { assignments } }
    var startCalls: [Bool] { lock.withLock { starts } }

    func start(resetRetryAttemts: Bool) {
        lock.withLock { starts.append(resetRetryAttemts) }
    }

    func send(data: Data, sendDidComplete: @escaping (Error?) -> Void) {
        DispatchQueue.global().async { sendDidComplete(nil) }
    }

    func stop(stopError: Error?) {}

    func abort(error: Error) {}
}
