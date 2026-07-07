//
//  Preferences.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Foundation

enum Preferences {
    private static let previousPowerStateKey = "previousBluetoothPowerState"
    private static let restorePreviousStateKey = "restorePreviousStateOnWake"
    private static let hideIconKey = "hideIcon"
    private static let disconnectDevicesOnSleepKey = "disconnectDevicesOnSleep"
    private static let devicesToDisconnectKey = "devicesToDisconnectOnSleep"
    private static let previousDeviceStatesKey = "previousDeviceConnectionStates"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            restorePreviousStateKey: true,
            disconnectDevicesOnSleepKey: false,
            hideIconKey: false,
        ])
    }

    static var previousBluetoothWasOn: Bool? {
        get { UserDefaults.standard.object(forKey: previousPowerStateKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: previousPowerStateKey) }
    }

    static var restorePreviousStateOnWake: Bool {
        get { UserDefaults.standard.bool(forKey: restorePreviousStateKey) }
        set { UserDefaults.standard.set(newValue, forKey: restorePreviousStateKey) }
    }

    static var hideIcon: Bool {
        get { UserDefaults.standard.bool(forKey: hideIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideIconKey) }
    }

    static var disconnectDevicesOnSleep: Bool {
        get { UserDefaults.standard.bool(forKey: disconnectDevicesOnSleepKey) }
        set { UserDefaults.standard.set(newValue, forKey: disconnectDevicesOnSleepKey) }
    }

    static var devicesToDisconnect: [String] {
        get { UserDefaults.standard.array(forKey: devicesToDisconnectKey) as? [String] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: devicesToDisconnectKey) }
    }

    static var previousDeviceConnectionStates: [String: Bool] {
        get {
            (UserDefaults.standard.dictionary(forKey: previousDeviceStatesKey) as? [String: Bool])
                ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: previousDeviceStatesKey) }
    }
}
