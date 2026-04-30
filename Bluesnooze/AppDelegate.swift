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
    @IBOutlet weak var hideIconMenuItem: NSMenuItem!

    private var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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
        setHideIconMenuState()
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

    @IBAction func hideIconClicked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(true, forKey: hideIconKey)
        // Immediately remove the status item. To bring it back the user can
        // simply launch Bluesnooze again from Finder/Spotlight.
        NSStatusBar.system.removeStatusItem(statusItem)
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
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    // MARK: Preferences

    private var restorePreviousStateOnWake: Bool {
        return UserDefaults.standard.bool(forKey: restorePreviousStateKey)
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
            hideIconKey: false
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

    private func setHideIconMenuState() {
        let state = hideIcon ? NSControl.StateValue.on : NSControl.StateValue.off
        hideIconMenuItem?.state = state
    }
}