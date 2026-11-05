//
//  HubConnectionOptions.swift
//  SignalRClient
//
//  Created by Pawel Kadluczka on 10/4/21.
//

import Foundation

/**
 HubConnection configuration options.
 */
public class HubConnectionOptions {
    /**
     Keep-alive interval in seconds. If nil keep-alive is disabled
     */
    public var keepAliveInterval: Double? = 15

    /**
     Server timeout in seconds. If no message arrives from the server within this interval the connection is
     considered lost and dropped, so a reconnectable connection reconnects. Catches half-open sockets (a weak
     network, a Wi-Fi to cellular handoff) that never report an error. Keep it at least double the server's
     keep-alive interval (15 seconds by default). If nil the server timeout is disabled.
     */
    public var serverTimeoutInterval: Double? = 30

    /**
    The queue to run callbacks on
     */
    public var callbackQueue: DispatchQueue = DispatchQueue.main
    
    /**
     Initializes `HubConnectionOptions`
     */
    public init() {
    }
}
