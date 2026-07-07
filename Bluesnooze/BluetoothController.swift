//
//  BluetoothController.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Darwin
import Foundation
import IOBluetooth
import OSLog

final class BluetoothController: NSObject {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oliverpeate.Bluesnooze",
        category: "bluetooth"
    )
    private let powerAPI = BluetoothPowerAPI()

    private let wakeReconnectDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0]
    private let pendingReconnectTimeout: TimeInterval = 15
    private var wakeReconnectGeneration = 0
    private var pendingReconnectDeadlines: [String: Date] = [:]

    var isPoweredOn: Bool {
        powerAPI.getPowerState() != 0
    }

    func setPower(_ powerOn: Bool) {
        logger.log("Setting Bluetooth controller power: \(powerOn, privacy: .public)")
        powerAPI.setPowerState(powerOn ? 1 : 0)
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
        let name = device.nameOrAddress ?? device.addressString ?? "Unknown device"
        let success = device.closeConnection() == kIOReturnSuccess
        logger.log("Disconnect \(name, privacy: .public): success=\(success, privacy: .public)")
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

                let pendingCount = self.pendingReconnectDeadlines.count
                self.logger.log(
                    "Reconnect: r=\(remaining.count, privacy: .public) p=\(pendingCount, privacy: .public)"
                )
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
                logger.info("Timed out waiting for devices to disconnect")
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
            name.lowercased().filter(\.isHexDigit) != addressKey {
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
        let name = device.nameOrAddress ?? addressString
        let status = device.openConnection(self)
        let success = status == kIOReturnSuccess
        logger.log(
            "Start async connect \(name, privacy: .public): success=\(success, privacy: .public)")

        if status != kIOReturnSuccess {
            pendingReconnectDeadlines.removeValue(forKey: addressString)
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        pendingReconnectDeadlines.removeValue(forKey: device.addressString)
        let name = device.nameOrAddress ?? device.addressString ?? "Unknown device"
        let success = status == kIOReturnSuccess
        logger.log(
            "Connection complete \(name, privacy: .public): success=\(success, privacy: .public)")
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

private final class BluetoothPowerAPI {
    private typealias GetPowerState = @convention(c) () -> Int32
    private typealias SetPowerState = @convention(c) (Int32) -> Void

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oliverpeate.Bluesnooze",
        category: "bluetooth"
    )
    private let handle: UnsafeMutableRawPointer?
    private let getControllerPowerState: GetPowerState?
    private let setControllerPowerState: SetPowerState?

    init() {
        handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
        getControllerPowerState = Self.load(
            "IOBluetoothPreferenceGetControllerPowerState", from: handle)
        setControllerPowerState = Self.load(
            "IOBluetoothPreferenceSetControllerPowerState", from: handle)
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func getPowerState() -> Int32 {
        guard let getControllerPowerState else {
            logger.error("Could not resolve IOBluetoothPreferenceGetControllerPowerState")
            return 0
        }
        return getControllerPowerState()
    }

    func setPowerState(_ state: Int32) {
        guard let setControllerPowerState else {
            logger.error("Could not resolve IOBluetoothPreferenceSetControllerPowerState")
            return
        }
        setControllerPowerState(state)
    }

    private static func load<T>(_ symbolName: String, from handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
