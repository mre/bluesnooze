![Bluesnooze logo](images/icon.png)

# Bluesnooze (mre fork)

> A friendlier fork of [odlp/bluesnooze][upstream] for people who want
> their Mac to stop hijacking their Bluetooth headphones the moment it
> goes to sleep — but who also don't want their Bluetooth keyboard and
> mouse to drop dead at the same time.

Requires **macOS 13 (Ventura) or later**.

## What is Bluesnooze?

Bluesnooze is a tiny menu bar app that **prevents your sleeping Mac from
connecting to Bluetooth accessories**.

The annoying scenario it solves: you pair your Bluetooth headphones (or
speakers, or earbuds) with both your phone and your Mac. You're listening
to something on your phone with your Mac asleep nearby. Your Mac decides
to wake up briefly — for a Time Machine backup, a Spotlight reindex, an
incoming iMessage notification, *anything* — and grabs your headphones
out from under your phone. Your audio cuts out. You get angry.

Bluesnooze fixes this by switching Bluetooth **off** when your Mac
sleeps and **on** again when it wakes.

## Why this fork?

The upstream project [odlp/bluesnooze][upstream] is great, but it makes
two design choices that I (and a lot of other people in the issue
tracker) found limiting:

1. **It's all-or-nothing.** Bluesnooze powers the entire Bluetooth radio
   off on sleep. That works fine if your only Bluetooth peripherals are
   audio devices, but if you use a Bluetooth keyboard or trackpad —
   especially as your *only* keyboard, e.g. on a Mac mini or Mac Studio —
   you can no longer wake your Mac with a key press. You have to reach
   for the power button.

2. **It always re-enabled Bluetooth on wake.** If you'd intentionally
   turned Bluetooth off before going to bed, you'd find it back on the
   next morning.

Both of those felt like bugs to me, so this fork addresses them.

## What's different in this fork

### Per-device "disconnect just these" mode

In addition to the original "turn Bluetooth off entirely" behaviour,
there's now a **"Disconnect selected devices on sleep"** mode. Instead
of powering down the whole Bluetooth controller, Bluesnooze will only
disconnect the specific devices you pick (typically your headphones).
The controller stays on, so your Bluetooth keyboard and mouse keep
working — and can still wake the Mac.

A "Selected devices" submenu lists your paired Bluetooth Classic
devices; tick the ones you want disconnected on sleep. They are
reconnected on wake.

> Adapted from [stefansundin/bluesnooze#6][upstream-pr], with a cleaner
> menu (proper submenu instead of hidden marker items), simpler
> defaults, no Wifi handling, and several typo fixes.

### Restore previous Bluetooth state on wake

There's a top-level toggle — **on by default** — that makes Bluesnooze
remember whether Bluetooth was on or off when your Mac went to sleep,
and only turn it back on if it was on before. If you deliberately
disabled Bluetooth, it stays disabled. This honours your explicit
choice rather than overriding it on every wake.

In per-device mode, this toggle controls reconnection too: with it on,
only devices that were actually connected before sleep get reconnected;
with it off, all selected devices get reconnected.

### Hide the menu bar icon (and bring it back without `defaults`)

You can hide Bluesnooze's menu bar icon from the menu itself. To bring
it back, **just launch Bluesnooze again from Finder/Spotlight** — the
already-running instance detects the second launch and re-shows its
icon. No terminal incantations required.

### Modernised under the hood

- **Migrated from Carthage to Swift Package Manager** for dependency
  management. No more `carthage bootstrap` for contributors.
- **Updated `LaunchAtLogin` from the legacy package to
  [`LaunchAtLogin-Modern`][lal-modern]**. The old package was
  archived by its author in September 2025; the modern one uses
  Apple's `SMAppService` API throughout.
- **Adopted Apple's unified logging (`os_log`)** for diagnostics. You
  can stream Bluesnooze's logs live with:
  ```sh
  log stream --predicate 'process == "Bluesnooze"'
  ```
  or dump a recent slice with:
  ```sh
  log show --process Bluesnooze --info --last 1h
  ```
- **Bumped the minimum macOS version to 13 (Ventura).** This drops a
  pile of legacy code paths that aren't needed on any reasonably modern
  Mac.

## Installation

This fork has no signed/notarized release yet. To run it, build from
source:

```sh
git clone https://github.com/mre/bluesnooze.git
cd bluesnooze
open Bluesnooze.xcodeproj
```

Then build and run from Xcode (⌘R), or from the command line:

```sh
xcodebuild -project Bluesnooze.xcodeproj -scheme Bluesnooze \
    -configuration Release build
```

The resulting `.app` will be in
`~/Library/Developer/Xcode/DerivedData/Bluesnooze-*/Build/Products/Release/`.
Drag it into `/Applications`.

If you'd rather use the original signed release (without this fork's
features), grab it from the [upstream releases page][upstream-releases]
or `brew install bluesnooze`.

## Migrating from upstream Bluesnooze

If you're moving from the original Bluesnooze to this fork:

- **You will need to re-enable "Launch at login" once.** This fork uses
  the modern `SMAppService` API; the registration from the older app
  doesn't carry over automatically.
- All your previous settings (`disableBluetoothOnPowerDown`, `hideIcon`,
  etc.) live under the same `com.oliverpeate.Bluesnooze` defaults
  domain and will be picked up unchanged.

## Caveats

- Not compatible with the "Allow your Apple Watch to unlock your Mac"
  feature.
- Can't be distributed via the App Store because it uses a private
  Bluetooth API to toggle the controller.
- The per-device disconnect mode lists **Bluetooth Classic devices
  only**. Pure-BLE devices are excluded because the macOS APIs we use
  to disconnect them (`IOBluetoothDevice.closeConnection`) are
  unreliable for BLE — `closeConnection` may report success without
  actually disconnecting.
- Some Apple-branded peripherals (e.g. Magic Keyboard with randomised
  Bluetooth address) appear in the device list as
  `Unnamed device (12-34-…)` rather than by name. The legacy
  `IOBluetooth` API doesn't return a friendly name for those; macOS
  System Settings only knows them through a different (CoreBluetooth)
  path.

## Configuration via `defaults`

All settings can also be edited via the `defaults` command:

```sh
# Read everything Bluesnooze stores
defaults read com.oliverpeate.Bluesnooze

# Force Bluetooth off on sleep, on on wake (the original behaviour)
defaults write com.oliverpeate.Bluesnooze restorePreviousStateOnWake -bool false

# Per-device disconnect mode + the list of devices to disconnect
defaults write com.oliverpeate.Bluesnooze disconnectDevicesOnSleep -bool true
defaults write com.oliverpeate.Bluesnooze devicesToDisconnectOnSleep \
    -array "12-34-4a-f0-19-02" "00-1d-43-aa-bb-cc"
```

### Hiding / restoring the menu bar icon from the terminal

```sh
# Hide
defaults write com.oliverpeate.Bluesnooze hideIcon -bool true && killall Bluesnooze

# Restore
defaults delete com.oliverpeate.Bluesnooze hideIcon && killall Bluesnooze
```

(Or just launch Bluesnooze again from Finder — it'll re-show its icon.)

## Credits

- Original app by [Oliver Peate][upstream] (`odlp`).
- Per-device disconnect feature originally proposed by
  [`ramatah`][upstream-pr-author] in
  [stefansundin/bluesnooze#6][upstream-pr], adapted here.
- This fork maintained by [@mre](https://github.com/mre).

[upstream]: https://github.com/odlp/bluesnooze
[upstream-releases]: https://github.com/odlp/bluesnooze/releases/latest
[upstream-pr]: https://github.com/stefansundin/bluesnooze/pull/6
[upstream-pr-author]: https://github.com/ramatah
[lal-modern]: https://github.com/sindresorhus/LaunchAtLogin-Modern