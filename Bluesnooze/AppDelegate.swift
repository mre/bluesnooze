//
//  AppDelegate.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Cocoa
import IOBluetooth
import LaunchAtLogin
import os.log

// Private IOBluetooth APIs for toggling the controller power state.
// Declared directly in Swift to avoid needing an Objective-C bridging
// header for two C function symbols.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func IOBluetoothPreferenceGetControllerPowerState() -> Int32

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var restorePreviousStateMenuItem: NSMenuItem!
    @IBOutlet weak var disconnectSelectedDevicesMenuItem: NSMenuItem!
    @IBOutlet weak var devicesSubmenuItem: NSMenuItem!
    @IBOutlet weak var hideIconMenuItem: NSMenuItem!

    private var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oliverpeate.Bluesnooze",
        category: "bluetooth"
    )

    // Key for persisting the pre-sleep Bluetooth power state across app
    // restarts (e.g. if the app is relaunched while the Mac is asleep).
    private let previousPowerStateKey = "previousBluetoothPowerState"

    // Key for the user preference controlling whether to restore the
    // pre-sleep Bluetooth state on wake (true) or to always turn Bluetooth
    // on at wake (false, original behaviour).
    private let restorePreviousStateKey = "restorePreviousStateOnWake"

    // Key for the user preference controlling whether the menu bar icon
    // is hidden.
    private let hideIconKey = "hideIcon"

    // Key for the user preference: when true, instead of powering the
    // Bluetooth controller off on sleep, disconnect a user-selected set
    // of paired devices. This lets the Mac still be woken by a Bluetooth
    // keyboard/mouse while preventing e.g. headphones from auto-connecting.
    private let disconnectDevicesOnSleepKey = "disconnectDevicesOnSleep"

    // Key for the user preference holding the address strings of the
    // paired devices that should be disconnected on sleep.
    private let devicesToDisconnectKey = "devicesToDisconnectOnSleep"

    // Key for the per-device pre-sleep connection state snapshot. Stored
    // as [addressString: Bool].
    private let previousDeviceStatesKey = "previousDeviceConnectionStates"

    private let wakeReconnectDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0]
    private let pendingReconnectTimeout: TimeInterval = 15
    private var wakeReconnectGeneration = 0
    private var pendingReconnectDeadlines: [String: Date] = [:]

    // Distributed notification sent by a second launched instance to ask
    // the already-running instance to re-show its menu bar icon.
    private let showIconNotificationName = Notification.Name("com.oliverpeate.Bluesnooze.showIcon")

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        registerDefaults()

        // If another instance is already running, this launch is the user's
        // way of asking us to re-show the (currently hidden) menu bar icon.
        // Tell the running instance to re-show its icon, then exit so we
        // don't end up with two copies running.
        if isAnotherInstanceRunning() {
            UserDefaults.standard.set(false, forKey: hideIconKey)
            DistributedNotificationCenter.default().postNotificationName(
                showIconNotificationName, object: nil, deliverImmediately: true
            )
            NSApplication.shared.terminate(self)
            return
        }

        initStatusItem()
        setLaunchAtLoginState()
        setRestorePreviousStateMenuState()
        setDisconnectSelectedDevicesMenuState()
        setHideIconMenuState()
        setupNotificationHandlers()

        // Hook the devices submenu so it lazily refreshes the list of
        // paired devices each time the user opens it.
        devicesSubmenuItem?.submenu?.delegate = self

        // On launch, only force Bluetooth on if the user hasn't opted in to
        // "restore previous state" behaviour. Otherwise leave whatever the
        // current state is alone -- the user might have just disabled it.
        // We also skip the force-on when the user is in per-device disconnect
        // mode, since that mode never powers the controller off in the first
        // place.
        if !restorePreviousStateOnWake && !disconnectDevicesOnSleep {
            setBluetooth(powerOn: true)
        }
    }

    // MARK: Click handlers

    @IBAction func launchAtLoginClicked(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        setLaunchAtLoginState()
    }

    @IBAction func restorePreviousStateClicked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!restorePreviousStateOnWake, forKey: restorePreviousStateKey)
        setRestorePreviousStateMenuState()
    }

    @IBAction func disconnectSelectedDevicesClicked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!disconnectDevicesOnSleep, forKey: disconnectDevicesOnSleepKey)
        setDisconnectSelectedDevicesMenuState()
    }

    @IBAction func hideIconClicked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(true, forKey: hideIconKey)
        // Immediately remove the status item. To bring it back the user can
        // simply launch Bluesnooze again from Finder/Spotlight.
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @IBAction func quitClicked(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    @objc func deviceMenuItemClicked(_ sender: BluetoothDeviceMenuItem) {
        var selected = devicesToDisconnect
        if selected.contains(sender.deviceAddressString) {
            selected.removeAll { $0 == sender.deviceAddressString }
        } else {
            selected.append(sender.deviceAddressString)
        }
        UserDefaults.standard.set(selected, forKey: devicesToDisconnectKey)
    }

    // MARK: Notification handlers

    func setupNotificationHandlers() {
        [
            NSWorkspace.willSleepNotification: #selector(onPowerDown(note:)),
            NSWorkspace.willPowerOffNotification: #selector(onPowerDown(note:)),
            NSWorkspace.didWakeNotification: #selector(onPowerUp(note:)),
            NSWorkspace.screensDidWakeNotification: #selector(onPowerUp(note:)),
        ].forEach { notification, sel in
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: sel, name: notification, object: nil)
        }

        // Listen for "please re-show your icon" requests from a second
        // launched instance.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onShowIconRequested(note:)),
            name: showIconNotificationName,
            object: nil
        )
    }

    @objc func onPowerDown(note: NSNotification) {
        // Snapshot current Bluetooth state so we know what to restore on wake.
        let wasOn = IOBluetoothPreferenceGetControllerPowerState() != 0
        UserDefaults.standard.set(wasOn, forKey: previousPowerStateKey)

        if disconnectDevicesOnSleep {
            // Snapshot per-device connection state, then disconnect the
            // user-selected devices. Leaving the controller powered on means
            // a Bluetooth keyboard/mouse can still wake the Mac.
            let paired = pairedClassicDevices()
            var states: [String: Bool] = [:]
            for device in paired {
                states[device.addressString] = device.isConnected()
            }
            UserDefaults.standard.set(states, forKey: previousDeviceStatesKey)

            let toDisconnect = Set(devicesToDisconnect)
            let disconnected = paired.filter { toDisconnect.contains($0.addressString) }
            for device in disconnected {
                disconnect(device)
            }

            // Wait briefly for the disconnects to actually take effect.
            // Otherwise, if the Mac is woken almost immediately after going
            // to sleep, the disconnect may complete *after* wake -- leaving
            // the device in a stuck-disconnected state.
            waitForDisconnect(devices: disconnected, retryInterval: 0.5, timeout: 5)
        } else {
            setBluetooth(powerOn: false)
        }
    }

    @objc func onPowerUp(note: NSNotification) {
        if disconnectDevicesOnSleep {
            // Per-device mode: reconnect the devices we touched. If the user
            // also has "restore previous state" on, only reconnect those that
            // were actually connected before sleep.
            let previousStates =
                (UserDefaults.standard.dictionary(forKey: previousDeviceStatesKey)
                    as? [String: Bool]) ?? [:]
            let restore = restorePreviousStateOnWake
            let addresses = devicesToDisconnect.filter { !restore || (previousStates[$0] ?? false) }
            scheduleReconnect(addresses: addresses)
            return
        }

        if restorePreviousStateOnWake {
            // If we have no recorded previous state (first run, or app was
            // installed while asleep), default to leaving Bluetooth off rather
            // than overriding the user's preference.
            let shouldPowerOn =
                UserDefaults.standard.object(forKey: previousPowerStateKey) as? Bool ?? false
            if shouldPowerOn {
                setBluetooth(powerOn: true)
            }
        } else {
            setBluetooth(powerOn: true)
        }
    }

    @objc func onShowIconRequested(note: NSNotification) {
        UserDefaults.standard.set(false, forKey: hideIconKey)
        // Re-create the status item from scratch. The previous one may have
        // been removed via `removeStatusItem` when the user hid the icon, in
        // which case its button is no longer attached to the status bar.
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        initStatusItem()
        setHideIconMenuState()
    }

    private func setBluetooth(powerOn: Bool) {
        os_log("Setting Bluetooth controller power: %{bool}d", log: log, powerOn)
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    // MARK: Bluetooth devices

    /// Returns paired Bluetooth Classic devices.
    ///
    /// `IOBluetoothDevice.pairedDevices()` has inconsistent behaviour around
    /// BLE devices, and `closeConnection()` on a BLE-backed
    /// `IOBluetoothDevice` is unreliable, so we filter to Classic devices
    /// only. The trick (borrowed from upstream PR #6 / Chromium issue 630581)
    /// is to require the standard PnP Information service record, which BLE
    /// devices don't expose via this API.
    private func pairedClassicDevices() -> [IOBluetoothDevice] {
        let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let pnpUUID = IOBluetoothSDPUUID(
            uuid32: kBluetoothSDPUUID16ServiceClassPnPInformation.rawValue)
        return all.filter { $0.getServiceRecord(for: pnpUUID) != nil }
    }

    private func disconnect(_ device: IOBluetoothDevice) {
        guard device.isConnected() else { return }
        let status = device.closeConnection()
        os_log(
            "Disconnect %{public}@: success=%{bool}d",
            log: log, device.nameOrAddress ?? device.addressString, status == kIOReturnSuccess)
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

    private func scheduleReconnect(addresses: [String]) {
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

    private func waitForDisconnect(
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

    // MARK: Devices submenu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === devicesSubmenuItem?.submenu else { return }
        rebuildDevicesSubmenu(menu)
    }

    private func rebuildDevicesSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let devices = pairedClassicDevices()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let selected = Set(devicesToDisconnect)
        let enabled = disconnectDevicesOnSleep
        for device in devices.sorted(by: { Self.displayName(for: $0) < Self.displayName(for: $1) })
        {
            let item = BluetoothDeviceMenuItem(
                device: device,
                action: #selector(deviceMenuItemClicked(_:)),
                target: self
            )
            item.state = selected.contains(device.addressString) ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }

        if !enabled {
            menu.addItem(.separator())
            let hint = NSMenuItem(
                title: "Enable “Disconnect selected devices on sleep” to choose",
                action: nil, keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        }
    }

    // MARK: Preferences

    private var restorePreviousStateOnWake: Bool {
        return UserDefaults.standard.bool(forKey: restorePreviousStateKey)
    }

    private var disconnectDevicesOnSleep: Bool {
        return UserDefaults.standard.bool(forKey: disconnectDevicesOnSleepKey)
    }

    private var devicesToDisconnect: [String] {
        return UserDefaults.standard.array(forKey: devicesToDisconnectKey) as? [String] ?? []
    }

    private var hideIcon: Bool {
        return UserDefaults.standard.bool(forKey: hideIconKey)
    }

    private func registerDefaults() {
        // Default the "restore previous state" behaviour to ON: it is
        // strictly more respectful of the user's explicit Bluetooth choice.
        // Users who prefer the legacy "always on at wake" behaviour can
        // disable it from the menu.
        UserDefaults.standard.register(defaults: [
            restorePreviousStateKey: true,
            disconnectDevicesOnSleepKey: false,
            hideIconKey: false,
        ])
    }

    private func isAnotherInstanceRunning() -> Bool {
        let myBundleID = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == myBundleID && app.processIdentifier != myPID
        }
    }

    // MARK: UI state

    private func initStatusItem() {
        if hideIcon {
            return
        }

        if let icon = NSImage(named: "bluesnooze") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "Bluesnooze"
        }
        statusItem.menu = statusMenu
    }

    private func setLaunchAtLoginState() {
        let state = LaunchAtLogin.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        launchAtLoginMenuItem.state = state
    }

    private func setRestorePreviousStateMenuState() {
        let state = restorePreviousStateOnWake ? NSControl.StateValue.on : NSControl.StateValue.off
        restorePreviousStateMenuItem?.state = state
    }

    private func setDisconnectSelectedDevicesMenuState() {
        let state = disconnectDevicesOnSleep ? NSControl.StateValue.on : NSControl.StateValue.off
        disconnectSelectedDevicesMenuItem?.state = state
    }

    private func setHideIconMenuState() {
        let state = hideIcon ? NSControl.StateValue.on : NSControl.StateValue.off
        hideIconMenuItem?.state = state
    }
}

/// An `NSMenuItem` that remembers the Bluetooth address of the device it
/// represents, so the click handler can identify the device without having
/// to re-resolve it by title.
class BluetoothDeviceMenuItem: NSMenuItem {
    let deviceAddressString: String

    init(device: IOBluetoothDevice, action: Selector?, target: AnyObject?) {
        self.deviceAddressString = device.addressString
        super.init(title: AppDelegate.displayName(for: device), action: action, keyEquivalent: "")
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
