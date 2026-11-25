# virt-app

Virt: Tyler's private iPhone app for his own workout Training, and (#578, Training for friends) his friends' too. A native shell around studio Training
(studio.tyleralocke.com/training: the same screens and data, so the website stays the backup), plus the native
pieces the web can't do well: alerts at the exact zero with the phone locked, the timer on the lock screen and in the
Dynamic Island (a Live Activity), and the screen kept awake during a workout. iPhone only (no iPad, no Watch yet).
How to work with Tyler is in the website repo's `CLAUDE.md` (wayloncore/tyleralocke); it applies here too.

## What's here
- `Core/`: the `VirtCore` Swift package, with no UI: the bridge messages (`BridgeMessage.swift`), the timer math, alert
  plan, Live Activity content and screen-awake rule (`TimerBoard.swift`, `TimerDisplay.swift`), which pages open
  inside the app (`Navigation.swift`, per door), and the doors and the friend's sign-in (`Door.swift`). Foundation
  only, so it tests on Linux.
- `App/`: the app. `ShellController.swift` is the web view (the `kinetic` bridge, sign-in kept inside, pull to
  refresh, the offline screen with Retry, the status bar matched to the page, the page's confirm() as native alerts,
  downloads to the share sheet). `Engine.swift` turns the timer state into notifications, the Live Activity, the
  screen kept awake, and the chime and buzz while the app is open. `AppMain.swift` has the app and scene delegates and
  `CookieKeeper` (keeps Access's session cookies in the Keychain across launches).
- `Widget/`: the timer extension (`com.tyleralocke.virt.timer`): the Live Activity and Dynamic Island, with −15,
  pause/resume, +15 and skip buttons. `Shared/`: compiled into both (the activity's attributes, the buttons' intent,
  the colors).
- `Widget/TodayWidgets.swift`: the Today widget (Home Screen small and medium; Lock Screen circular, rectangular and
  inline) and the Week widget (Lock Screen circular and rectangular). Their views are in `Shared/TodayViews.swift`, the
  Live Activity's in `Shared/TimerViews.swift`, so the test build's widget gallery (`App/WidgetGallery.swift`,
  `-uitest-widgets`) draws them at real size for screenshots.
- `Shared/SharedStore.swift`: the last `today` from the page, shared with the widgets through the keychain group
  `6WK983RXJT.com.tyleralocke.virt.shared` (not an App Group: App Store Connect's API can't create those). In an unsigned
  simulator build it falls back to the app's own copy.
- `App/Intents.swift`: Siri, Shortcuts and the Action button (Start my workout; Start a rest timer). `App/Reminders.swift`:
  training-day reminders. `App/Sound.swift` and `App/Sounds/`: the sounds (`LICENSES.md` says where each came from;
  `.github/workflows/sounds.yml` and `scripts/sounds.py` make them). `App/SettingsView.swift`: Virt's own settings and
  tips sheet. `App/Intro.swift`: the video intro and the Face ID lock screen's picture (VirtCore's `IntroFlow` is
  its order of events): the launch clip plays on a fresh launch while Face ID asks and ends on the large V, which is
  the lock screen (`App/Intro/VirtLock.png` is the clip's exact last frame); Face ID's yes plays the unlock clip into
  black, then Training fades in. No sound; with Reduce Motion, no video. The clips in `App/Intro/` are made from
  Tyler's Kling clips by `scripts/intro_video.py` (trims and speeds are in its comments); the launch screen, the intro
  and the lock screen are pure black (#000), the rest of the app keeps its own black.
- The web view is bound to the studio's domains (Info.plist `WKAppBoundDomains`, the same list as
  `Navigation.appBoundDomains`), which is what lets Training's service worker run in the app. A main-frame page outside
  them opens in Safari.
- `App/Bundle/`: Training's screens for the build to embed (filled by `scripts/fetch_bundle.py`; see the bundle below).
- `UITests/`: run in the iPhone simulator. `project.yml`: the XcodeGen spec (the project file isn't kept).
- `.github/workflows/mac.yml`: the batched Mac run (VirtCore tests, build, UI tests, screenshots printed into the log).
  `core.yml`: VirtCore's tests on Linux on every push that changes `Core/` (free, about a minute).
- `.github/workflows/testflight.yml`: a Linux readiness check (secrets set, both App IDs registered, the App Store
  Connect app there), then the signed build uploaded to TestFlight and the internal testing group. Its build number is
  the run number. `scripts/asc.py` talks to App Store Connect with the key in secrets (ASC_ISSUER_ID, ASC_KEY_ID,
  ASC_KEY_P8, the same key as time2play-app, so the two apps share one distribution certificate).
- App icon: `App/Assets.xcassets/AppIcon.appiconset` (the gold nested V on black, 1024 × 1024, no alpha). Colors (v3, #746): graphite `#15171B`, the one action red
  `#FF4B3A` and done-green `#59CF8B`, matching the website's v3 tokens; gold `#DFC297` (sampled from the icon) is the mark
  and records only. The launch, intro and lock screens stay pure black with the gold V.

## The two doors (#578 part 2, #580)
The first screen on a new phone (`App/Account.swift`, `DoorsView`) asks which way in; the choice is saved
(`virt.door` in UserDefaults) and Settings' "Switch sign-in" goes back to it.
- **Tyler's studio:** Cloudflare Access, then studio Training: exactly the path from before doors (Face ID,
  `CookieKeeper`). A phone that used Virt before doors (a studio sign-in, a saved `today`, his settings) opens it
  without asking (`Door.resolve`).
- **Training for friends:** the 13+ question, Sign in with Apple (`com.apple.developer.applesignin`; `asc.py ready`
  turns the capability on), `POST tyleralocke.com/live/players/apple` (the Time2Play accounts server), the session in
  this phone's Keychain (`FriendKeeper`, service `com.tyleralocke.virt.friend`), then train.time2play.live with the
  session handed over as `window.T2P_SESSION` before the page runs (`FriendSignIn.handoverScript`, that host only).
  The page's "Sign out here" posts to Virt's own `virtAccount` handler, and Virt signs out too.
- The first screen (Tyler, Nov 23): pure black, his VIRT word (`VirtWord`, cropped from the launch clip's own frame, so
  the pillar I is his artwork; never re-letter it), "Strength is a virtue. Build it daily.", Sign in with Apple at the
  bottom, and "For ages 13 and up. Terms · Privacy". **The studio's Cloudflare sign-in is gone from Virt
  (Tyler, Nov 23): one sign-in screen for everyone.** Only the test build still opens that door, for its stand-in
  pages (`Door.atLaunch`, `studioAllowed`). On Tyler's phone a sign-in that can't reach his Training says so, and an
  unlinked Apple ID is asked to link in the studio on the web, never made a friend's account (`Door.ownerStep`).
- "Try a workout" (website #806, switch `training-guest`): the first screen's second button opens
  train.time2play.live/try on the friends' door with no session (`guest`, never saved). The page's own Sign in with
  Apple sends `{ type: 'signIn' }` on the bridge, and Virt shows its first screen over the workout, with "Back to the
  workout". Signing in opens their Training, where the page keeps the workout they just did.
- Virt's settings from the page: Virt sets `kineticApp.settings: true`, and the page's "Account and app settings" row on
  You sends `{ type: 'settings' }` on the bridge; Virt opens its settings sheet (sign out, Delete account), so account
  deletion is one tap from inside the app. Never for a guest.
- The streak's morning nudge: `today` may carry `streak`, `streakAtRisk` and `streakAtRiskTomorrow` (website #804);
  with reminders on, Virt sets one plain notification at 9:00 on such a day (`ReminderPlan.streakPlan`). "Remind me"
  asks iOS for alerts, and if iOS has them off for Virt, offers the way to Settings.
- A friend's web view opens only train.time2play.live inside; the studio and everything else go to Safari. Signing
  out of either door clears the widgets' `today`, the reminders, any timer, and that door's sign-in on the phone.
- The server checks the Apple token's audience; it has to accept `com.tyleralocke.virt` as well as Time2Play's
  bundle id (a website issue), and the friend's page is a 404 until Tyler approves the `training-friends` switch.

## Training's screens inside the app (the bundle, tyleralocke#822)
The plan and the contract with the website are wayloncore/tyleralocke#822. The rules are VirtCore's
`TrainBundle.swift` (tested on Linux); the app's side is `App/BundleStore.swift`, `BundleScheme.swift` and
`BundleMove.swift`.
- **Where it comes from:** the website's build lists every file its four pages need in
  `https://train.time2play.live/app/manifest.json` (sizes and SHA-256s). `scripts/fetch_bundle.py` runs in
  testflight.yml and mac.yml before the project is generated, checks every file, and fills `App/Bundle/`
  (`manifest.json` and `files/<path>`; only its `.gitkeep` is in git), which the app embeds as a folder. A 404 for
  the manifest means no bundle; a wrong hash fails the TestFlight build.
- **When it's used:** only when the build shipped with a bundle. Then the friends' door, the owner's session and a
  guest load `virt-app://train/` (a `WKURLSchemeHandler`; `"virt-app:"` in `WKAppBoundDomains` makes the scheme
  app-bound, the list's tenth and last entry) instead of the website, the page is told `kineticApp.bundled` and
  `window.T2P_API_BASE`, and its API calls go to https://train.time2play.live with the session as a Bearer token.
  **With no shipped bundle, Virt loads the website exactly as before and never downloads one.**
- **Updates:** on launch and when the app comes forward (at most every 30 minutes, never during a workout)
  `BundleStore` asks for the manifest, fetches only the files it doesn't have (https, that host only, no cookies),
  checks every hash, and keeps the version in Application Support/Bundles/<version>/. It's used from the next
  launch, never swapped under a running page. The newest, the one before and the shipped copy are kept.
- **The fallback:** a version that has never posted a `kinetic` message gets 8 seconds from the start of its first
  load; if it stays silent it's marked failed (never tried again by this build) and Training reloads from the one
  before, then the shipped copy, then the website. A new app build starts from its own shipped copy.
- **Moving from the old way:** a phone signed in before bundles loads the old page once, hidden, for up to 10
  seconds so it can send a workout it had saved (`virt.bundle-moved` in UserDefaults; with no signal, a later launch).
- **Testing:** `cd Core && swift test` covers the rules. The UI tests never read the embedded bundle or the network:
  `-uitest-bundle` makes a three-file bundle in the test build (`BundleFixture`), and without it there is no bundle,
  so every older test runs the website path. The status line shows `page <address>` and `bundle <version>`.

## The bridge (the website owns it)
The contract is the website's `docs/kinetic/bridge.md` (`src/lib/training/kinetic.js`). The page posts to the
`window.webkit.messageHandlers.kinetic` handler (keep that name: "Kinetic" was the app's working name) and takes
lock-screen buttons back as `kinetic:command` events. Don't change the website from here: if Virt needs more, open a
small `queue` issue in wayloncore/tyleralocke describing an additive change. Virt also reads `today` and
`set.logged`, sends `startToday` and `rest { seconds }`, and sets `window.kineticApp` before the page loads (#533, #550).
Log set (#573): Virt reads `set.next` (and `nextSet` on `timer.start`), the open exercise's next set, and sends
`{ command: 'log', at }`. The Live Activity shows the next set under the rest, and between sets the next set with a big
Log set; Log set starts the set's rest at once and shows the following set, since the page may be asleep
(`TimerBoard.logSet`). The same intent is a Control Center control (`LogSetControl`, iOS 18, in the widget extension).
Virt already reads an optional
`upcoming` list on `timer.start` (the steps after this one, each `{ id, kind, label, endsAt }`) and schedules an alert
at each of their zeros; until the page sends it, only the running step's zero sounds while the phone is locked.
One press is one set (Nov 24, VirtCore's `LogPress`): presses within 0.6 s count once, nothing is sent when Virt's
board has no next set, and each `log` carries its own `id` (`{ command: 'log', at, id }`, additive) so the page can drop
a repeat. The board is kept on the phone (`virt.board` in UserDefaults) so a press that wakes Virt after iOS ended it
still knows the set. `today` may carry `live: true/false` (a workout is open on the page); Virt reads it for the lock
(`LiveWorkout`), and falls back to the 45-minute rule without it.
Settings through the bridge (the You tab; VirtCore's `Prefs.swift`, the app's `App/Prefs.swift`; the website documents
the same contract in its docs/kinetic/bridge.md). All additive:
- Before the page's scripts, every load: `kineticApp.prefs = { sounds: bool, soundStyle: 'chime'|'digital'|'classic',
  reminders: bool, reminderLine: '6:00 PM on Mon, Tue and Thu' ('' when off or not known), lockAfter:
  'now'|'15m'|'1h'|'never', notifications: 'on'|'off' }` ('off' only when iOS has them off; never asked reads 'on').
  The page decides what to show by whether `kineticApp.prefs` exists.
- `kinetic:prefs` on `window` (CustomEvent, `detail` = the same object, and `kineticApp.prefs` updated in place)
  whenever one changes, from the page or Virt's sheet, and each time Virt comes forward.
- The page posts `{ type: 'pref', key: 'sounds'|'soundStyle'|'reminders'|'lockAfter', value }`,
  `{ type: 'openNotificationSettings' }`, `{ type: 'deleteAccount' }` (the sheet's own confirmation still asks; a
  friend's door only, never a guest) and `{ type: 'signOut' }` (the sheet's confirmation; waits during a workout).
  Unknown keys and values are ignored; only from Training's own main frame. Virt's sheet stays, on the same values.
- Sounds off is quiet everywhere Virt controls: no sound in the app, and the Lock Screen's timer alerts are scheduled
  with no sound (so no buzz either). The reminders keep iOS's sound.
- The screen stays awake only in the workout (`TimerBoard.keepAwake`): `today` may carry `screen: 'workout'|'other'`;
  with it, awake only on the workout screen (a countdown, or a sign of the workout within 45 minutes); without it,
  only while a countdown is running.

## Lock-screen buttons, alerts and the lock (Nov 24)
- The Live Activity's buttons and Control Center's Log set are `TimerCommandIntent`, a `LiveActivityIntent` that says
  outright it runs while locked (`authenticationPolicy = .alwaysAllowed`), never opens the app (`openAppWhenRun =
  false`; iOS 26 `supportedModes = .background`), and touches only what a locked phone allows after its first unlock.
  It never asks iOS for alert permission: that's asked while Virt is open, when the first workout starts.
- Workout-timer alerts: iOS plays a notification's sound only with words to show, so each zero is still a quiet
  notification (category and thread `virt.timer`), but Virt takes the delivered ones away every time it runs, all of
  them when it comes forward or the workout ends (`TimerAlerts`); reminders are never touched. While Virt is open
  there's no banner at all: the app plays its own sound.
- The green light (`virt-start-go.caf`, `scripts/sounds.py start`) is the sound when a rest ends in Chime and Digital:
  three short tones then go, started 1.2 s early so the go lands on the zero (`SoundStyle.lead`), with no 3-2-1 ticks.
- The lock: the cover shows only in the background (not for Control Center, Notification Center or the Face ID sheet)
  and lifts on return; never a lock or the launch clip while a workout is live (remembered across a launch,
  `virt.workout.live`); the lock is the app's, not the scene's; "Lock after" in Virt's settings (`lock.after`: Right
  away, 15 minutes, 1 hour, Never).

## Testing
- **Linux:** `core.yml` runs on push. Locally, if Swift is installed: `cd Core && swift test`.
- **Mac (GitHub runner):** one run per finished piece, never per change. Start it with the REST dispatch
  (`gh api -X POST repos/wayloncore/virt-app/actions/workflows/mac.yml/dispatches -f ref=<branch>`) or `[mac]` in a
  pushed commit's message. Screenshots come back as base64 between `BEGIN-SHOT name` and `END-SHOT` in the job log.
  Report how many runs and minutes each session used.
- The UI tests can't sign in to the studio (Access sends a one-time PIN by email), so they check that the sign-in
  opens inside the app, and test the bridge with a stand-in page that talks exactly like Training. The test build
  (Debug, `-uitest`) shows a status line and command buttons; Release builds have neither.

## Rules
- **Health data never reaches any AI.** No AI anywhere in Virt. Nothing about workouts leaves the phone except to the
  studio itself (or, for a friend, train.time2play.live), through the web view. No analytics, no third-party SDKs.
- **Keys only in GitHub secrets**, never in the repo, an issue, a comment or a log.
- **Saved data stays readable by the previous version:** add fields (optional ones), never rename or remove them in
  the same release. That includes the Live Activity's content (`TimerDisplay`) and the Keychain sign-in copy.
- Never submit to App Review (builds are TestFlight internal only). Never change this repo's visibility.
- Apple: Team ID `6WK983RXJT`, bundle ids `com.tyleralocke.virt` and `com.tyleralocke.virt.timer`, home screen name
  "Virt". None of these is secret.
- External TestFlight and Beta App Review for friends are #578 part 3 (#581): Tyler's call, never from a session.
- American spelling. Plain-language comments and PR text.
