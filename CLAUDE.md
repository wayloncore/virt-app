# virt-app

Virt: Tyler's private iPhone app for his own workout Training. A native shell around studio Training
(studio.tyleralocke.com/training: the same screens and data, so the website stays the backup), plus the native
pieces the web can't do well: alerts at the exact zero with the phone locked, the timer on the lock screen and in the
Dynamic Island (a Live Activity), and the screen kept awake during a workout. iPhone only (no iPad, no Watch yet).
How to work with Tyler is in the website repo's `CLAUDE.md` (wayloncore/tyleralocke); it applies here too.

## What's here
- `Core/`: the `VirtCore` Swift package, with no UI: the bridge messages (`BridgeMessage.swift`), the timer math, alert
  plan, Live Activity content and screen-awake rule (`TimerBoard.swift`, `TimerDisplay.swift`), and which pages open
  inside the app (`Navigation.swift`). Foundation only, so it tests on Linux.
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
- `UITests/`: run in the iPhone simulator. `project.yml`: the XcodeGen spec (the project file isn't kept).
- `.github/workflows/mac.yml`: the batched Mac run (VirtCore tests, build, UI tests, screenshots printed into the log).
  `core.yml`: VirtCore's tests on Linux on every push that changes `Core/` (free, about a minute).
- `.github/workflows/testflight.yml`: a Linux readiness check (secrets set, both App IDs registered, the App Store
  Connect app there), then the signed build uploaded to TestFlight and the internal testing group. Its build number is
  the run number. `scripts/asc.py` talks to App Store Connect with the key in secrets (ASC_ISSUER_ID, ASC_KEY_ID,
  ASC_KEY_P8, the same key as time2play-app, so the two apps share one distribution certificate).
- App icon: `App/Assets.xcassets/AppIcon.appiconset` (the gold nested V on black, 1024 × 1024, no alpha). Colors: gold
  `#DFC297` (sampled from the icon) and black `#0B0A09`.

## The bridge (the website owns it)
The contract is the website's `docs/kinetic/bridge.md` (`src/lib/training/kinetic.js`). The page posts to the
`window.webkit.messageHandlers.kinetic` handler (keep that name: "Kinetic" was the app's working name) and takes
lock-screen buttons back as `kinetic:command` events. Don't change the website from here: if Virt needs more, open a
small `queue` issue in wayloncore/tyleralocke describing an additive change. Virt also reads `today` and
`set.logged`, sends `startToday` and `rest { seconds }`, and sets `window.kineticApp` before the page loads (#533, #550).
Virt already reads an optional
`upcoming` list on `timer.start` (the steps after this one, each `{ id, kind, label, endsAt }`) and schedules an alert
at each of their zeros; until the page sends it, only the running step's zero sounds while the phone is locked.

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
  studio itself, through the web view. No analytics, no third-party SDKs.
- **Keys only in GitHub secrets**, never in the repo, an issue, a comment or a log.
- **Saved data stays readable by the previous version:** add fields (optional ones), never rename or remove them in
  the same release. That includes the Live Activity's content (`TimerDisplay`) and the Keychain sign-in copy.
- Never submit to App Review (builds are TestFlight internal only). Never change this repo's visibility.
- Apple: Team ID `6WK983RXJT`, bundle ids `com.tyleralocke.virt` and `com.tyleralocke.virt.timer`, home screen name
  "Virt". None of these is secret.
- American spelling. Plain-language comments and PR text.
