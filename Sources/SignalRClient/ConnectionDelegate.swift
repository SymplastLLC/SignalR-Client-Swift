//
//  ConnectionDelegate.swift
//  SignalRClient
//
//  Created by Pawel Kadluczka on 2/26/17.
//  Copyright © 2017 Pawel Kadluczka. All rights reserved.
//

import Foundation

public protocol ConnectionDelegate: AnyObject {
    func transportConnectionDidOpen(connection: Connection)
    func hubConnectionDidOpen(connection: Connection)
    func connectionDidFailToOpen(error: Error)
    func connectionDidReceiveData(connection: Connection, data: Data)
    func connectionDidClose(error: Error?)
    func connectionWillReconnect(error: Error)
    func connectionDidReconnect()
    func currentReconnectionAttempt(currentAttempt: Int)
}

public extension ConnectionDelegate {
    func connectionWillReconnect(error: Error) {}
    func connectionDidReconnect() {}
}
