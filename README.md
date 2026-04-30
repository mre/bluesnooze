![Bluesnooze logo](images/icon.png)

# Bluesnooze

[Download the latest release][download-latest] or install via Homebrew:

```sh
brew install bluesnooze
```

Please note the latest release requires macOS Ventura (13.0) or higher.

## Enjoying Bluesnooze? ❤️

Perhaps you could [buy me a coffee](https://www.buymeacoffee.com/odlp) to say thanks :coffee:

## About

**Bluesnooze prevents your sleeping Mac from connecting to Bluetooth accessories.**

If you pair Bluetooth headphones or speakers with both your phone & Mac it can be frustrating when your sleeping Mac connects intermittently and disrupts the audio.

With Bluesnooze the Bluetooth connection is switched off when your Mac sleeps, and switched on when your Mac wakes.

Alternatively, you can choose **Disconnect selected devices on sleep** from the menu and pick specific paired devices (e.g. headphones or speakers) to disconnect on sleep. In this mode the Bluetooth controller stays powered on, so a Bluetooth keyboard or mouse can still wake your Mac. The selected devices are reconnected on wake (subject to the *Restore previous Bluetooth state on wake* setting — when that is on, only devices that were actually connected before sleep will be reconnected).

> **Note:** only Bluetooth Classic devices are listed. BLE devices are excluded because the macOS APIs Bluesnooze uses to disconnect them are unreliable.

![Screenshot showing Bluesnooze in the status bar](images/screenshot.png)

You might also want to check-out Whisper –  [the volume limiter for MacOS](https://apps.apple.com/gb/app/whisper-volume-limiter/id1438132944?mt=12).

## Installation

1. Download `Bluesnooze.zip` from the [latest release][download-latest]
1. In Finder, open `Bluesnooze.zip` in your `Downloads` directory
1. Drag `Bluesnooze.app` to your `Applications` directory
1. *Optional*: Configure 'Launch at login'

## Caveats

- Please note this app is not compatible with the “Allow your Apple Watch to unlock your Mac” feature.
- Unfortunately this app can't be distributed via the App Store because it uses a private API to switch Bluetooth on/off (but the release version is notarized by Apple).

[download-latest]: https://github.com/odlp/bluesnooze/releases/latest

## FAQs

### How can I hide the Bluesnooze icon?

In your terminal run the following command:

```sh
defaults write com.oliverpeate.Bluesnooze hideIcon -bool true && killall Bluesnooze
```

When you next relaunch the application there should be no icon in the menu bar.

### How can I restore the Bluesnooze icon?

In your terminal run the following command:

```sh
defaults delete com.oliverpeate.Bluesnooze hideIcon && killall Bluesnooze
```

When you next relaunch the application it should appear in the menu bar.
