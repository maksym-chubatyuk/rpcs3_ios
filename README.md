# RPCS3 for iOS

The [RPCS3](https://github.com/RPCS3/rpcs3) PlayStation 3 emulator on iPhone, with its LLVM
recompilers running natively.

## Requirements

- **iOS 26 or later.** Tested on iOS 26.6.
- **iPhone 11 or newer** (what iOS 26 runs on), but memory is what matters:
  - 8 GB or more (iPhone 15 Pro, 16 series, 17 series): recommended, and what this is tested on
    (iPhone 16 Pro Max);
  - 6 GB (iPhone 12 Pro, 13 Pro, 14, 15): untested; lighter games may run;
  - 4 GB or less (iPhone 11, 12, 13, SE): untested; unlikely to run games.
- A computer (Windows, macOS or Linux) and a USB cable, for the first setup and the 7-day reinstall.
- An Apple ID. A free one works.
- Your own PS3 games. This project provides none.

## Installing

### 1. Install the app

1. Download `RPCS3-<version>.ipa` from [Releases](https://github.com/maksym-chubatyuk/rpcs3_ios/releases).
2. Install [iloader](https://github.com/nab138/iloader) on the computer, from its GitHub releases or
   [iloader.app](https://iloader.app).
3. Connect the iPhone with the cable, unlock it and tap **Trust** when it asks about the computer.
4. In iloader, sign in with your Apple ID and import the IPA. iloader signs it with your Apple ID
   and installs it.
5. On the iPhone:
   - **Settings › Privacy & Security › Developer Mode**: turn it on and restart when asked. The
     option shows up only after the app is installed.
   - **Settings › General › VPN & Device Management**: trust your Apple ID if RPCS3 does not open.

### 2. Set up JIT (once)

RPCS3 needs JIT to run games, and on iOS that takes a debugger. The app has one built in (StikJIT).
It needs two things:

1. **The iPhone's pairing file.** Make it with iloader's pairing file option while the iPhone is
   connected, and save it. Send the file to the iPhone (AirDrop, iCloud Drive, or any way it ends
   up in the Files app). In RPCS3, tap **Import Pairing File…** and pick it. The app keeps it.
2. **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** from the App Store. Open it and
   connect. It works on Wi-Fi or with no network, but **not over cellular data**.

Open RPCS3. It enables JIT by itself. The first time, it downloads the Developer Disk Image, which
takes a minute and needs internet.

### 3. Firmware and games

1. Download `PS3UPDAT.PUP` from
   [PlayStation's PS3 system software page](https://www.playstation.com/support/hardware/ps3/system-software/),
   then tap **Choose PS3UPDAT.PUP in Files…** in RPCS3.
2. Add games with **+**:
   - **Game folder**: a dumped disc (the folder with `PS3_GAME` in it) or a PSN/HDD game (with `USRDIR`);
   - **ISO file**;
   - **Install Packages**: PKG files (games, updates, DLC), together with their `.rap` licences
     (PSN games need them to start).

   Games can be anywhere in the Files app (iCloud Drive, an external drive). Folders copied into
   **On My iPhone › RPCS3 › Games** appear by themselves.

### Every time you play

Connect LocalDevVPN first, then open RPCS3.

With a free Apple ID, the app stops opening after 7 days. Install it again with iloader. Your games,
saves and settings stay.

## Troubleshooting

- **JIT does not enable**: check that LocalDevVPN is connected and you are not on cellular data. If
  the iPhone was reset or re-paired with the computer, make a new pairing file in iloader and use
  **Replace Pairing File…**.
- **RPCS3 does not open**: after 7 days with a free Apple ID, reinstall it with iloader. Otherwise,
  check Developer Mode and that your Apple ID is trusted (above).
- **A game does not run well**: see how it runs in RPCS3 itself on the
  [compatibility list](https://rpcs3.net/compatibility). A phone's GPU and memory set further limits.
  Some games run better with different settings: long-press the game › **Game Settings**.

## Reporting problems

[Open an issue](https://github.com/maksym-chubatyuk/rpcs3_ios/issues/new/choose) and attach
RPCS3.log: **Settings › Logs › Share**. After a crash, share the **Previous** log. Please don't
report problems with this iOS version to RPCS3's own tracker.

Building from source: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

GPL-2.0, like RPCS3 (`LICENSE`). StikJIT is MPL-2.0 and contains idevice (MIT); see `third_party/StikJIT`.
