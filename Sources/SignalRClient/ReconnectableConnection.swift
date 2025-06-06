//
//  ReconnectableConnection.swift
//  SignalRClient
//
//  Created by Pawel Kadluczka on 11/17/19.
//

import Foundation

internal class ReconnectableConnection: Connection {
    private let connectionQueue = DispatchQueue(label: "SignalR.reconnection.queue")
    private let callbackQueue: DispatchQueue

    private let connectionFactory: () -> Connection
    private let reconnectPolicy: ReconnectPolicy
    private let logger: Logger

    private var underlyingConnection: Connection
    private var wrappedDelegate: ConnectionDelegate?
    private var reconnectableState = State.disconnected
    var state: HttpConnection.State = .initial
    private var failedAttemptsCount: Int = 0
    private var reconnectStartTime: Date = Date()

    private enum State: String {
        case disconnected = "disconnected"
        case starting = "starting"
        case reconnecting = "reconnecting"
        case running = "running"
        case stopping = "stopping"
    }

    weak var delegate: ConnectionDelegate?
    var connectionId: String? {
        return underlyingConnection.connectionId
    }

    var inherentKeepAlive: Bool {
        return underlyingConnection.inherentKeepAlive
    }

    init(connectionFactory: @escaping () -> Connection, reconnectPolicy: ReconnectPolicy, callbackQueue: DispatchQueue, logger: Logger) {
        self.connectionFactory = connectionFactory
        self.reconnectPolicy = reconnectPolicy
        self.logger = logger
        self.underlyingConnection = connectionFactory()
        self.callbackQueue = callbackQueue
    }
    
    func start(resetRetryAttemts: Bool) {
        if resetRetryAttemts {
            resetRetryAttempts()
        }
        logger.log(logLevel: .info, message: "Starting reconnectable connection")
        if changeState(from: [.disconnected], to: .starting) != nil {
            wrappedDelegate = ReconnectableConnectionDelegate(connection: self)
            startInternal()
        } else {
            logger.log(logLevel: .warning, message: "Reconnectable connection not in the disconnected state. Ignoring start request")
        }
    }

    func send(data: Data, sendDidComplete: @escaping (Error?) -> Void) {
        logger.log(logLevel: .info, message: "Received send request")
        guard reconnectableState != .reconnecting else {
            // TODO: consider buffering
            // Never synchronously respond to avoid upstream deadlocks based on async assumptions
            callbackQueue.async {
                sendDidComplete(SignalRError.connectionIsReconnecting)
            }
            return
        }
        underlyingConnection.send(data: data, sendDidComplete: sendDidComplete)
    }

    func stop(stopError: Error?) {
        logger.log(logLevel: .info, message: "Received connection stop request")
        if changeState(from: [.starting, .reconnecting, .running], to: .stopping) != nil {
          underlyingConnection.stop(stopError: stopError)
        } else {
          logger.log(logLevel: .warning, message: "Reconnectable connection is already in the disconnected state. Ignoring stop request")
        }
    }

    private func startInternal() {
        logger.log(logLevel: .debug, message: "Starting or reconnecting")
        var shouldStart = false
        var currentState = State.disconnected
        connectionQueue.sync {
            shouldStart = reconnectableState == .starting || reconnectableState == .reconnecting
            currentState = reconnectableState
        }

        if (!shouldStart) {
            logger.log(logLevel: .info, message: "Aborting start/reconnect due to connection state: \(currentState)")
            return
        }

        underlyingConnection = connectionFactory()
        underlyingConnection.delegate = wrappedDelegate
        underlyingConnection.start()
    }

    private func changeState(from: [State]?, to: State) -> State? {
        var previousState: State? = nil

        logger.log(logLevel: .debug, message: {
            let initialStates = from?.map{ $0.rawValue }.joined(separator: ", ") ?? "(nil)"
            return "Attempting to change state from: '\(initialStates)' to: '\(to)'"
        }())
        connectionQueue.sync {
            if from?.contains(reconnectableState) ?? true {
                previousState = reconnectableState
                reconnectableState = to
                
                switch to {
                case .disconnected:
                    state = .stopped
                case .starting, .reconnecting:
                    state = .connecting
                case .running:
                    state = .connected
                case .stopping:
                    state = .stopped
                }
            }
        }
        logger.log(logLevel: .debug, message: "Changing state to: '\(to)' \(previousState == nil ? "failed" : "succeeded")")
        return previousState
    }

    private func restartConnection(error: Error?) {
        logger.log(logLevel: .debug, message: "Attempting to restart connection")
        let currentState = reconnectableState
        if currentState == .starting || currentState == .reconnecting {
           
            let retryContext = updateAndCreateRetryContext(error: error)
         
            let nextAttemptInterval = reconnectPolicy.nextAttemptInterval(retryContext: retryContext)
            delegate?.currentReconnectionAttempt(currentAttempt: retryContext.failedAttemptsCount)
            logger.log(logLevel: .debug, message: "nextAttemptInterval: \(nextAttemptInterval), RetryContext: \(retryContext)")
            if nextAttemptInterval != .never {
                logger.log(logLevel: .debug, message: "Scheduling reconnect attempt at: \(nextAttemptInterval)")
                // TODO: not great but running on the connectionQueue deadlocks
                DispatchQueue.main.asyncAfter(deadline: .now() + nextAttemptInterval) { [weak self] in
                    self?.startInternal()
                }
                // running on a random (possibly main) queue but HubConnection will
                // dispatch to the configured queue
                if (currentState == .reconnecting && retryContext.failedAttemptsCount == 0) {
                    delegate?.connectionWillReconnect(error: retryContext.error)
                }
                return
            }
        }

        let previousState = changeState(from: nil, to: .disconnected)
        logger.log(logLevel: .info, message: "Connection not to be restarted. State: \(previousState!.rawValue)")
        if previousState == .starting {
            logger.log(logLevel: .debug, message: "Opening the connection failed")
            delegate?.connectionDidFailToOpen(error: error ?? SignalRError.invalidOperation(message: "Opening connection failed"))
        } else if previousState == .reconnecting {
            logger.log(logLevel: .debug, message: "Reconnecting failed")
            delegate?.connectionDidClose(error: error)
        } else {
            logger.log(logLevel: .debug, message: "Stopping connection")
        }
    }

    private func updateAndCreateRetryContext(error: Error?) -> RetryContext {
        var attemptsCount = -1
        var startTime = Date()
        connectionQueue.sync {
            attemptsCount = failedAttemptsCount
            if attemptsCount == 0 {
                reconnectStartTime = Date()
            }
            startTime = reconnectStartTime
            failedAttemptsCount += 1
        }

        if error == nil {
            logger.log(logLevel: .info, message: "Received nil error. (Can be because Context.Abort())")
        }

        let error = error ?? SignalRError.invalidOperation(message: "Unexpected error.")
        return RetryContext(failedAttemptsCount: attemptsCount, reconnectStartTime: startTime, error: error)
    }

    private func resetRetryAttempts() {
        connectionQueue.sync {
            failedAttemptsCount = 0
            // no need to reset start time - it will be set next time reconnect happens
        }
    }

    private class ReconnectableConnectionDelegate: ConnectionDelegate {
        func currentReconnectionAttempt(currentAttempt: Int) {
            connection?.delegate?.currentReconnectionAttempt(currentAttempt: currentAttempt)
        }
        
        private weak var connection: ReconnectableConnection?

        init(connection: ReconnectableConnection) {
            self.connection = connection
        }

        func hubConnectionDidOpen(connection: Connection) {
            guard let unwrappedConnection = self.connection else {
                return
            }
            unwrappedConnection.logger.log(logLevel: .debug, message: "Connection opened successfully")
            unwrappedConnection.resetRetryAttempts()
            let previousState = unwrappedConnection.changeState(from: [.starting, .reconnecting], to: .running)
            if previousState == .starting {
                unwrappedConnection.delegate?.transportConnectionDidOpen(connection: connection)
            } else if previousState == .reconnecting {
                unwrappedConnection.delegate?.connectionDidReconnect()
            } else {
                unwrappedConnection.logger.log(logLevel: .debug, message: "Internal error - unexpected connection state")
                // TODO: consider using dispatchGroup to block stop while reconnecting/starting.
            }
        }

        func transportConnectionDidOpen(connection: Connection) {
            guard let unwrappedConnection = self.connection else {
                return
            }
            unwrappedConnection.logger.log(logLevel: .debug, message: "Connection opened successfully")
            unwrappedConnection.resetRetryAttempts()
            let previousState = unwrappedConnection.changeState(from: [.starting, .reconnecting], to: .running)
            if previousState == .starting {
                unwrappedConnection.delegate?.hubConnectionDidOpen(connection: connection)
            } else if previousState == .reconnecting {
                unwrappedConnection.delegate?.connectionDidReconnect()
            } else {
                unwrappedConnection.logger.log(logLevel: .debug, message: "Internal error - unexpected connection state")
                // TODO: consider using dispatchGroup to block stop while reconnecting/starting.
            }
        }

        func connectionDidFailToOpen(error: Error) {
            connection?.restartConnection(error: error)
        }

        func connectionDidReceiveData(connection: Connection, data: Data) {
            self.connection?.delegate?.connectionDidReceiveData(connection: connection, data: data)
        }

        func connectionDidClose(error: Error?) {
            guard let unwrappedConnection = self.connection else {
                return
            }
            unwrappedConnection.logger.log(logLevel: .debug, message: "Connection closed")
            let previousState = unwrappedConnection.changeState(from: [.running], to: .reconnecting)
            if previousState != nil {
                unwrappedConnection.logger.log(logLevel: .debug, message: "Initiating connection restart")
                connection?.restartConnection(error: error)
            } else {
                unwrappedConnection.logger.log(logLevel: .debug, message: "Assuming clean stop - stopping connection")
                if  unwrappedConnection.reconnectableState != .stopping {
                    // This is wired to the transport so it should not be fired in the starting, reconnecting
                    // or disconnected state (maybe there is a tiny window when it can happen right after a
                    // the transport connected successfully. For now just log an error.
                    unwrappedConnection.logger.log(logLevel: .error, message: "Internal error - unexpected state")
                }
                _ = unwrappedConnection.changeState(from: nil, to: .disconnected)
                unwrappedConnection.delegate?.connectionDidClose(error: error)
            }
        }
    }
}
