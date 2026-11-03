//
//  Connection.swift
//  SignalRClient
//
//  Created by Pawel Kadluczka on 3/4/17.
//  Copyright © 2017 Pawel Kadluczka. All rights reserved.
//

import Foundation

public protocol Connection {
    var state: HttpConnection.State { get }
    var delegate: ConnectionDelegate? { get set }
    var inherentKeepAlive: Bool { get }
    var connectionId: String? { get }
    func start(resetRetryAttemts: Bool) -> Void
    func send(data: Data, sendDidComplete: @escaping (_ error: Error?) -> Void) -> Void
    func stop(stopError: Error?) -> Void
    /// Drops a connection that is no longer usable (e.g. the server went silent) the way a network
    /// failure would: a reconnectable connection reconnects, any other one closes with `error`.
    func abort(error: Error) -> Void
}

public extension Connection {
    func abort(error: Error) -> Void {
        stop(stopError: error)
    }

    func start(resetRetryAttemts: Bool = false) -> Void {
        start(resetRetryAttemts: resetRetryAttemts)
    }
}
