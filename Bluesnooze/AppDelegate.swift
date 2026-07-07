//
//  AppDelegate.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Cocoa
import LaunchAtLogin
import OSLog

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var restorePreviousStateMenuItem: NSMenuItem!
    @IBOutlet weak var disconnectSelectedDevicesMenuItem: NSMenuItem!
    @IBOutlet weak var devicesSubmenuItem: NSMenuItem!
    @IBOutlet weak var hideIconMenuItem: NSMenuItem!

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oliverpeate.Bluesnooze",
        category: "app"
    )
    private let bluetooth = BluetoothController()
    private let wakeDebounceInterval: TimeInterval = 2
    private let showIconNotificationName = Notification.Name("com.oliverpeate.Bluesnooze.showIcon")

    private var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastWakeHandledAt: Date?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Preferences.registerDefaults()

        if isAnotherInstanceRunning() {
            Preferences.hideIcon = false
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

        devicesSubmenuItem?.submenu?.delegate = self

        if !Preferences.restorePreviousStateOnWake && !Preferences.disconnectDevicesOnSleep {
            bluetooth.setPower(true)
        }
    }

    // MARK: Click handlers

    @IBAction func launchAtLoginClicked(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        setLaunchAtLoginState()
    }

    @IBAction func restorePreviousStateClicked(_ sender: NSMenuItem) {
        Preferences.restorePreviousStateOnWake.toggle()
        setRestorePreviousStateMenuState()
    }

    @IBAction func disconnectSelectedDevicesClicked(_ sender: NSMenuItem) {
        Preferences.disconnectDevicesOnSleep.toggle()
        setDisconnectSelectedDevicesMenuState()
    }

    @IBAction func hideIconClicked(_ sender: NSMenuItem) {
        Preferences.hideIcon = true
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @IBAction func quitClicked(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    @objc func deviceMenuItemClicked(_ sender: BluetoothDeviceMenuItem) {
        var selected = Preferences.devicesToDisconnect
        if selected.contains(sender.deviceAddressString) {
            selected.removeAll { $0 == sender.deviceAddressString }
        } else {
            selected.append(sender.deviceAddressString)
        }
        Preferences.devicesToDisconnect = selected
    }

    // MARK: Notification handlers

    private func setupNotificationHandlers() {
        [
            NSWorkspace.willSleepNotification: #selector(onPowerDown(note:)),
            NSWorkspace.willPowerOffNotification: #selector(onPowerDown(note:)),
            NSWorkspace.didWakeNotification: #selector(onPowerUp(note:)),
            NSWorkspace.screensDidWakeNotification: #selector(onPowerUp(note:)),
        ].forEach { notification, sel in
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: sel, name: notification, object: nil)
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onShowIconRequested(note:)),
            name: showIconNotificationName,
            object: nil
        )
    }

    @objc private func onPowerDown(note: NSNotification) {
        Preferences.previousBluetoothWasOn = bluetooth.isPoweredOn

        if Preferences.disconnectDevicesOnSleep {
            let paired = bluetooth.pairedClassicDevices()
            Preferences.previousDeviceConnectionStates = Dictionary(
                uniqueKeysWithValues: paired.map { ($0.addressString, $0.isConnected()) }
            )

            let selectedAddresses = Set(Preferences.devicesToDisconnect)
            let disconnected = paired.filter { selectedAddresses.contains($0.addressString) }
            disconnected.forEach(bluetooth.disconnect)

            bluetooth.waitForDisconnect(devices: disconnected, retryInterval: 0.5, timeout: 5)
        } else {
            bluetooth.setPower(false)
        }
    }

    @objc private func onPowerUp(note: NSNotification) {
        if let lastWakeHandledAt = lastWakeHandledAt,
            Date().timeIntervalSince(lastWakeHandledAt) < wakeDebounceInterval {
            let notificationName = note.name.rawValue
            logger.log("Ignoring duplicate wake notification: \(notificationName, privacy: .public)")
            return
        }
        lastWakeHandledAt = Date()

        if Preferences.disconnectDevicesOnSleep {
            let previousStates = Preferences.previousDeviceConnectionStates
            let addresses = Preferences.devicesToDisconnect.filter {
                !Preferences.restorePreviousStateOnWake || (previousStates[$0] ?? false)
            }
            bluetooth.scheduleReconnect(addresses: addresses)
            return
        }

        if Preferences.restorePreviousStateOnWake {
            if Preferences.previousBluetoothWasOn ?? false {
                bluetooth.setPower(true)
            }
        } else {
            bluetooth.setPower(true)
        }
    }

    @objc private func onShowIconRequested(note: NSNotification) {
        Preferences.hideIcon = false
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        initStatusItem()
        setHideIconMenuState()
    }

    // MARK: Devices submenu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === devicesSubmenuItem?.submenu else { return }
        rebuildDevicesSubmenu(menu)
    }

    private func rebuildDevicesSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let devices = bluetooth.pairedClassicDevices()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let selected = Set(Preferences.devicesToDisconnect)
        let enabled = Preferences.disconnectDevicesOnSleep
        for device in devices.sorted(by: {
            BluetoothController.displayName(for: $0) < BluetoothController.displayName(for: $1)
        }) {
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

    // MARK: UI state

    private func initStatusItem() {
        if Preferences.hideIcon {
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
        let state: NSControl.StateValue = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginMenuItem.state = state
    }

    private func setRestorePreviousStateMenuState() {
        restorePreviousStateMenuItem?.state = Preferences.restorePreviousStateOnWake ? .on : .off
    }

    private func setDisconnectSelectedDevicesMenuState() {
        disconnectSelectedDevicesMenuItem?.state = Preferences.disconnectDevicesOnSleep ? .on : .off
    }

    private func setHideIconMenuState() {
        hideIconMenuItem?.state = Preferences.hideIcon ? .on : .off
    }

    private func isAnotherInstanceRunning() -> Bool {
        let myBundleID = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == myBundleID && app.processIdentifier != myPID
        }
    }
}
