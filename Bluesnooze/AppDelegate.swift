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

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var restorePreviousStateMenuItem: NSMenuItem!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    // Key for persisting the pre-sleep Bluetooth power state across app
    // restarts (e.g. if the app is relaunched while the Mac is asleep).
    private let previousPowerStateKey = "previousBluetoothPowerState"

    // Key for the user preference controlling whether to restore the
    // pre-sleep Bluetooth state on wake (true) or to always turn Bluetooth
    // on at wake (false, original behaviour).
    private let restorePreviousStateKey = "restorePreviousStateOnWake"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        registerDefaults()
        initStatusItem()
        setLaunchAtLoginState()
        setRestorePreviousStateMenuState()
        setupNotificationHandlers()

        // On launch, only force Bluetooth on if the user hasn't opted in to
        // "restore previous state" behaviour. Otherwise leave whatever the
        // current state is alone -- the user might have just disabled it.
        if !restorePreviousStateOnWake {
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

    @IBAction func quitClicked(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    // MARK: Notification handlers

    func setupNotificationHandlers() {
        [
            NSWorkspace.willSleepNotification: #selector(onPowerDown(note:)),
            NSWorkspace.willPowerOffNotification: #selector(onPowerDown(note:)),
            NSWorkspace.didWakeNotification: #selector(onPowerUp(note:)),
            NSWorkspace.screensDidWakeNotification: #selector(onPowerUp(note:))
        ].forEach { notification, sel in
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: sel, name: notification, object: nil)
        }
    }

    @objc func onPowerDown(note: NSNotification) {
        // Snapshot current Bluetooth state so we know what to restore on wake.
        let wasOn = IOBluetoothPreferenceGetControllerPowerState() != 0
        UserDefaults.standard.set(wasOn, forKey: previousPowerStateKey)

        setBluetooth(powerOn: false)
    }

    @objc func onPowerUp(note: NSNotification) {
        if restorePreviousStateOnWake {
            // If we have no recorded previous state (first run, or app was
            // installed while asleep), default to leaving Bluetooth off rather
            // than overriding the user's preference.
            let shouldPowerOn = UserDefaults.standard.object(forKey: previousPowerStateKey) as? Bool ?? false
            if shouldPowerOn {
                setBluetooth(powerOn: true)
            }
        } else {
            setBluetooth(powerOn: true)
        }
    }

    private func setBluetooth(powerOn: Bool) {
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    // MARK: Preferences

    private var restorePreviousStateOnWake: Bool {
        return UserDefaults.standard.bool(forKey: restorePreviousStateKey)
    }

    private func registerDefaults() {
        // Default the new behaviour to ON: restoring the user's pre-sleep
        // Bluetooth state is strictly more respectful of their explicit
        // choice. Users who prefer the legacy "always on at wake" behaviour
        // can disable it from the menu.
        UserDefaults.standard.register(defaults: [
            restorePreviousStateKey: true
        ])
    }

    // MARK: UI state

    private func initStatusItem() {
        if UserDefaults.standard.bool(forKey: "hideIcon") {
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
}