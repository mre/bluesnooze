//
//  BluetoothDeviceMenuItem.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Cocoa
import IOBluetooth

/// An `NSMenuItem` that remembers the Bluetooth address of the device it
/// represents, so the click handler can identify the device without having
/// to re-resolve it by title.
final class BluetoothDeviceMenuItem: NSMenuItem {
    let deviceAddressString: String

    init(device: IOBluetoothDevice, action: Selector?, target: AnyObject?) {
        self.deviceAddressString = device.addressString
        super.init(
            title: BluetoothController.displayName(for: device), action: action, keyEquivalent: "")
        self.target = target
    }

    required init(coder: NSCoder) {
        self.deviceAddressString =
            (coder.decodeObject(forKey: "deviceAddressString") as? String) ?? ""
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(deviceAddressString, forKey: "deviceAddressString")
    }
}
