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
}

public extension Connection {
    func start(resetRetryAttemts: Bool = false) -> Void {
        start(resetRetryAttemts: resetRetryAttemts)
    }
}
