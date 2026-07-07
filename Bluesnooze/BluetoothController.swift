//
//  BluetoothController.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Foundation
import IOBluetooth
import os.log

// Private IOBluetooth APIs for toggling the controller power state.
// Declared directly in Swift to avoid needing an Objective-C bridging
// header for two C function symbols.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func IOBluetoothPreferenceGetControllerPowerState() -> Int32

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

final class BluetoothController: NSObject {
    private let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oliverpeate.Bluesnooze",
        category: "bluetooth"
    )

    private let wakeReconnectDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0]
    private let pendingReconnectTimeout: TimeInterval = 15
    private var wakeReconnectGeneration = 0
    private var pendingReconnectDeadlines: [String: Date] = [:]

    var isPoweredOn: Bool {
        IOBluetoothPreferenceGetControllerPowerState() != 0
    }

    func setPower(_ powerOn: Bool) {
        os_log("Setting Bluetooth controller power: %{bool}d", log: log, powerOn)
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    /// Returns paired Bluetooth Classic devices.
    ///
    /// `IOBluetoothDevice.pairedDevices()` has inconsistent behaviour around
    /// BLE devices, and `closeConnection()` on a BLE-backed
    /// `IOBluetoothDevice` is unreliable, so we filter to Classic devices
    /// only. The trick (borrowed from upstream PR #6 / Chromium issue 630581)
    /// is to require the standard PnP Information service record, which BLE
    /// devices don't expose via this API.
    func pairedClassicDevices() -> [IOBluetoothDevice] {
        let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let pnpUUID = IOBluetoothSDPUUID(
            uuid32: kBluetoothSDPUUID16ServiceClassPnPInformation.rawValue)
        return all.filter { $0.getServiceRecord(for: pnpUUID) != nil }
    }

    func disconnect(_ device: IOBluetoothDevice) {
        guard device.isConnected() else { return }
        let status = device.closeConnection()
        os_log(
            "Disconnect %{public}@: success=%{bool}d",
            log: log, device.nameOrAddress ?? device.addressString, status == kIOReturnSuccess)
    }

    func scheduleReconnect(addresses: [String]) {
        guard !addresses.isEmpty else { return }
        wakeReconnectGeneration += 1
        let generation = wakeReconnectGeneration

        for delay in wakeReconnectDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.wakeReconnectGeneration == generation else { return }

                let remaining = addresses.filter { address in
                    guard let device = IOBluetoothDevice(addressString: address) else {
                        return false
                    }
                    return !device.isConnected()
                }

                for address in remaining {
                    self.connect(addressString: address)
                }

                os_log(
                    "Wake reconnect attempt after %.1fs: %d remaining, %d pending",
                    log: self.log, delay, remaining.count, self.pendingReconnectDeadlines.count)
                if remaining.isEmpty {
                    self.wakeReconnectGeneration += 1
                }
            }
        }
    }

    func waitForDisconnect(
        devices: [IOBluetoothDevice],
        retryInterval: TimeInterval,
        timeout: TimeInterval
    ) {
        guard !devices.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        let interval = min(retryInterval, timeout)
        while devices.contains(where: { $0.isConnected() }) {
            if Date() >= deadline {
                os_log("Timed out waiting for devices to disconnect", log: log, type: .info)
                return
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Human-readable name for a Bluetooth device, or an explicit
    /// "Unnamed device (address)" fallback when `device.name` is missing
    /// or just echoes the address back (which `IOBluetooth` does for some
    /// peripherals, sometimes with a different separator or case than
    /// `addressString`).
    static func displayName(for device: IOBluetoothDevice) -> String {
        let address = device.addressString ?? "unknown address"
        let addressKey = address.lowercased().filter(\.isHexDigit)
        if let name = device.name?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty,
            name.lowercased().filter(\.isHexDigit) != addressKey
        {
            return name
        }
        return "Unnamed device (\(address))"
    }

    private func connect(addressString: String) {
        guard let device = IOBluetoothDevice(addressString: addressString) else { return }
        guard device.isPaired(), !device.isConnected(), !isReconnectPending(addressString) else {
            return
        }

        pendingReconnectDeadlines[addressString] = Date().addingTimeInterval(
            pendingReconnectTimeout)
        let status = device.openConnection(self)
        os_log(
            "Start async connect %{public}@: success=%{bool}d",
            log: log, device.nameOrAddress ?? addressString, status == kIOReturnSuccess)

        if status != kIOReturnSuccess {
            pendingReconnectDeadlines.removeValue(forKey: addressString)
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        pendingReconnectDeadlines.removeValue(forKey: device.addressString)
        os_log(
            "Connection complete %{public}@: success=%{bool}d",
            log: log, device.nameOrAddress ?? device.addressString, status == kIOReturnSuccess)
    }

    private func isReconnectPending(_ addressString: String) -> Bool {
        guard let deadline = pendingReconnectDeadlines[addressString] else { return false }
        if Date() < deadline {
            return true
        }
        pendingReconnectDeadlines.removeValue(forKey: addressString)
        return false
    }
}
