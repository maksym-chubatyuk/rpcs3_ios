# Manual testing

What has to be checked by hand on an iPhone: taps, other controllers, and anything that needs
you to play. The core paths behind most of these were tested on the device through the app's
test hooks (`scripts/run.sh` with `SETTINGS_SELFTEST`, `PATCH_TEST`, `CONTROLS_TEST`,
`USERDATA_TEST` and others); what remains is the screens themselves and real play.

Tick an item off when it works; note what went wrong otherwise.

## JIT and setup

- [ ] JIT without a Mac: import the pairing file, connect LocalDevVPN, tap Enable JIT (StikJIT inside the app).
- [ ] Firmware: install PS3UPDAT.PUP picked in Files ("Choose PS3UPDAT.PUP in Files…") and from the RPCS3 folder.
- [ ] Add a game folder from Files (iCloud Drive, On My iPhone, an external drive) and an ISO.
- [ ] A game copied into On My iPhone › RPCS3 › Games shows up after pull to refresh.
- [ ] Remove from Library (Files games), and the context menu's Copy Serial and Check Compatibility.

## Installing packages

- [ ] + › Install Packages: pick a game PKG with its .rap licence; the review lists title, version, type and size.
- [ ] The installation shows progress, Cancel stops it, and the installed game appears in the library ("installed").
- [ ] The installed game starts (its licence works).
- [ ] An update PKG for a disc game installs, and the game page's version and patches follow it.
- [ ] An update for the wrong version is marked and skipped.
- [ ] A DLC PKG installs and the game sees it.
- [ ] Uninstall (swipe, long press, game page) deletes the installed game, its update and DLC.
- [ ] Leaving the app during an installation: it either finishes or is cancelled cleanly.

## Playing

- [ ] The screen stays in landscape in a game and the touch controls work.
- [ ] Leaving the app pauses the game; coming back resumes it.
- [ ] The PS button opens RPCS3's home menu; quitting from it closes the game screen.
- [ ] Saving in a game: its save dialog lists and creates saves (the fix for the save dialog is untested).
- [ ] A trophy popup appears when one is earned.
- [ ] Play with Global Settings, Play with Default Settings, Play with a config file from Files.
- [ ] Savestates: make one in the home menu, then Resume Latest Savestate and the savestate list on the game page.

## Game page

- [ ] Opens from ⓘ and from the context menu; Play starts the game after the sheet closes.
- [ ] Caches: sizes are right; swipe or long press removes one; Remove All Caches; Build PPU Cache Now shows progress and closes by itself.
- [ ] Data: Savestates and Updates and DLC removal ask first and work.
- [ ] Use Global Settings Only and Use Global Controls Only appear only when the game has its own, and remove them.

## Settings

- [ ] Every tab opens; search finds settings across tabs and Other.
- [ ] Editors: switches, pickers, number fields, sliders, the console clock and the colour editor.
- [ ] Reset to Default (long press) and the changed-count badges.
- [ ] Game settings: a changed setting is marked, the global value is unchanged, and the game uses it at boot.
- [ ] Settings that apply only at the next start say so while a game runs.

## Patches

- [ ] Download Latest Patches (and "already up to date" the second time).
- [ ] A patch switch turns on and off; only one patch of a group stays on.
- [ ] Patch values: list picker, stepper and slider.
- [ ] Import Patch File… from Files.
- [ ] The notes sheet (ⓘ next to a patch).
- [ ] A game with patches of its own shows them; a patch's effect is visible in the game.

## Controls

- [ ] Global (Settings › Controls) and per game (game page › Controls).
- [ ] Button mapping pickers, stick, trigger and vibration rows, Reset to Default.
- [ ] A physical controller (DualSense, Xbox, MFi) works together with the touch controls as player 1.
- [ ] A second controller can be given to player 2 and plays as player 2.
- [ ] Vibration on a controller.
- [ ] Changing controls while a game runs takes effect at once.

## On-screen controls layout

- [ ] Controls › Edit Layout…: drag each group (face buttons, D-pad, Select/PS/Start), pinch one to resize it.
- [ ] Size, Opacity and Vibrate on Press change what is shown; Reset; Hide Options; Cancel keeps the old layout.
- [ ] Save, then a game shows the controls as arranged, and they still respond where they are drawn.
- [ ] A game's own layout (game page › Controls › Edit Layout… › This Game Only), and Use the Layout for All Games.

## Users, save data, trophies

- [ ] Users (person icon in the library › Users): create, rename, log in, delete (not the logged-in user).
- [ ] A game shows the logged-in user's name; another user starts with no saves and trophies.
- [ ] The user stays logged in after the app is closed and opened again.
- [ ] Save Data: icons, titles and dates; search; details sheet.
- [ ] Export to Files… copies a save folder; Import Save… brings it back (and asks before replacing one).
- [ ] Import a save made by desktop RPCS3 (its dev_hdd0/home/00000001/savedata/<folder>) and the game loads it.
- [ ] Delete one save; the game page's Save Data shows only that game's saves.
- [ ] Trophies: the list of games with progress, one game's trophies, Show Hidden Trophies, the filter.
- [ ] Mark as Earned / Not Earned, and Remove Trophy Data.
- [ ] The game page's Trophies link (for games with trophies).

## RPCN (online)

- [ ] Create an account (person icon › RPCN, or Settings › RPCN); the token arrives by email; enter it in Edit Account.
- [ ] Test Account says it works; Use an Existing Account with a desktop RPCS3 account works too.
- [ ] Play Online with RPCN, then a game that plays online connects (RPCN popups appear if turned on).
- [ ] Send the Token Again, Change Password (reset token by email), Delete Account.
- [ ] Add Server…, switch servers, remove a server.

## Logs

- [ ] Settings › Logs shows RPCS3.log, TTY.log and the app log; the level filter and search work.
- [ ] Share sends the whole log (e.g. to Files or Mail).

## General

- [ ] Dark mode, larger text sizes, and VoiceOver on the main screens.
