# Lock-screen buttons with no Face ID

Tyler, Nov 25: "I want to be able to lock my screen but not have to scan my face on my phone to log the set from the
lock screen." Earlier: "With apps like YouTube Music I can change the song... without having to unlock my phone."

This lists every reason found for a Live Activity button (or Control Center's Log set) to ask for an unlock, what
Apple's documentation says about each, and what Virt does about it. Checked against developer.apple.com on
Nov 25, 2026. Where the docs say nothing, this says so.

## What Apple's docs say

1. **Widget and Live Activity buttons are off on a locked phone, by default.** "On a locked device, buttons and
   toggles are inactive and the system doesn't perform actions unless a person authenticates and unlocks their
   device." ([Adding interactivity to widgets and Live
   Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities))
   The page doesn't list exceptions. The same page says: "For a Live Activity interactive, adopt the
   `LiveActivityIntent` protocol. If the interaction starts or pauses media playback, adopt the `AudioPlaybackIntent`
   protocol."
2. **Which intents run in the app.** "By default, the system runs the app intent in the same process as the widget
   extension. However, if the app intent's `openAppWhenRun` property is `true`, or if the intent conforms to
   `AudioPlaybackIntent`, `ForegroundContinuableIntent`, `LiveActivityIntent`, or `PushToTalkTransmissionIntent`, the
   system performs the app intent in the app's process." (same page)
3. **`LiveActivityIntent`.** "When the system performs the intent, the system launches your app process without
   opening the app, performs the intent, and starts the Live Activity."
   ([LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)) Nothing about a
   locked phone.
4. **`AudioPlaybackIntent`.** "Adopt this protocol to indicate to the system that your App Intent plays audio. The
   system can then avoid dialogue or other experiences that might interrupt that audio."
   ([AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)) Nothing about a
   locked phone, and nothing saying the app must actually start audio. Developers on Apple's forums report that the
   lock-screen buttons that run without an unlock "all seem to be audio intents"
   ([forum thread 738252](https://developer.apple.com/forums/thread/738252), no Apple reply).
5. **`authenticationPolicy`.** "The default value of this property is `alwaysAllowed`, which allows the intent to run
   without authentication, including when the device is locked."
   ([authenticationPolicy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy-1r9kh),
   [IntentAuthenticationPolicy](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy)).
   A developer reported setting it alone didn't stop the unlock ask for a plain `AppIntent` widget button (thread
   738252 above). For controls, Apple says the policy decides: "Set the `authenticationPolicy` in the control's app
   intent to refine what level of authentication is necessary to perform the action."
   ([Adding refinements and configuration to
   controls](https://developer.apple.com/documentation/widgetkit/adding-refinements-and-configuration-to-controls))
6. **Opening the app.** `openAppWhenRun` is deprecated in iOS 26 in favor of
   [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes) ("Specify
   `background` to run the action entirely in the background")
   ([openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun)). An app that
   comes to the screen from the Lock Screen needs the phone unlocked; a developer reports an `AudioPlaybackIntent`
   with `openAppWhenRun = true` asked for the passcode when locked
   ([forum thread 793047](https://developer.apple.com/forums/thread/793047), no reply). Apple's engineer on
   `LiveActivityIntent`: "It is not possible to open an app using a LiveActivity. A LiveActivityIntent is designed for
   background execution." ([forum thread 812949](https://developer.apple.com/forums/thread/812949))
7. **A tap on the Live Activity itself (not on a button) opens the app.** "People can tap a Live Activity to launch
   your app." ([Launching your app from a Live
   Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity)) The docs
   don't say how to turn that off, and opening the app from the Lock Screen needs an unlock.
8. **Keychain items.** "When Unlocked: Items with this setting are only accessible when the device is unlocked...
   This is the default accessibility when you don't otherwise specify a setting." "After First Unlock... Use this
   level of accessibility when your app needs to access the item while running in the background."
   ([Restricting keychain item
   accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)) A
   locked keychain item doesn't make iOS ask for Face ID; the read just fails, so the press would do nothing.
9. **Files.** "Complete until first user authentication. (Default)"; "Complete. The file is accessible only when the
   device is unlocked." ([Encrypting Your App's
   Files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)) The docs don't name
   UserDefaults' class; its file is an app file, so it gets the default unless the app asks for more.
10. **iPhone's own setting.** Settings > Face ID & Passcode > "Allow Access When Locked" turns some Lock Screen
    features on or off ([iPhone User
    Guide](https://support.apple.com/guide/iphone/control-access-information-lock-screen-iph9a2a69136/ios)). The
    guide doesn't list the items, so which of them touches Live Activities isn't documented.
11. **Not used here.** `AudioRecordingIntent` is for recording; `ForegroundContinuableIntent` and
    `PushToTalkTransmissionIntent` don't fit. `ControlWidgetButton` takes any `AppIntent`
    ([Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)).

## Each reason, and what Virt does

| Reason iOS could ask for an unlock | Virt |
| --- | --- |
| The intent is a kind iOS won't run locked (1, 4) | `TimerCommandIntent` (every Live Activity button and Control Center's Log set) is both a `LiveActivityIntent` and an `AudioPlaybackIntent`, the kind music apps' buttons use. Apple says the audio kind is for an interaction that "starts or pauses media playback"; Virt's buttons pause and move a timer whose zero is a sound, and Log set starts a rest that ends in one. The docs don't forbid both on one intent, and don't require the app to play audio. |
| The intent asks for authentication (5) | `authenticationPolicy = .alwaysAllowed`, said outright. The Siri/Action button rest timer (`RestTimerIntent`) too. |
| The intent opens the app (6) | `openAppWhenRun = false`, and on iOS 26 `supportedModes = .background`. Nothing in `perform()` or `Engine.command` opens a URL, activates a scene or asks Face ID. |
| The system has to ask a question (a parameter to fill, a confirmation) | The button fills `command`; no `requestConfirmation`, `requestValue` or `@Dependency`. |
| A link or a tap that opens the app (7) | No `Link` or `widgetURL` in the Live Activity. A tap on the card outside a button still opens Virt (iOS's own rule, no documented way off), and that asks for Face ID. Press the buttons themselves. |
| Data the press needs is locked (8, 9) | The board, the live-workout memory and held presses are in UserDefaults (default class, readable after first unlock). Every keychain copy is written "after first unlock, this phone only"; at launch and whenever the phone unlocks, `LockedRead.moveIfNeeded` moves any item kept another way, without deleting it (so the build before still reads it). Virt never sets a stricter file class. |
| Virt's own Face ID lock ("Lock after") | Only runs when Virt's own screen comes forward (`sceneDidBecomeActive`). A press never makes the scene active, and a press counts as a sign of the workout, so coming back mid-workout doesn't ask either. |
| Asking iOS for alert permission from a press | Never: asked only with Virt open on the screen. |
| The press is lost while the page sleeps (not an unlock, but the set must still be saved) | A Log set press with no page (iOS started Virt in the background just for the press) or with the page loading is held on the phone (`PendingLogs`, `virt.pending.logs`) and handed to the page when it's up, with its moment and id. One the web view couldn't run is held again. The page drops an id it has already logged. |

## Checks

- `Core/Tests/VirtCoreTests/LockScreenButtonsTests.swift` (Linux): reads the source for every `Button(intent:)` and
  control action, and fails unless each intent is both kinds, says `.alwaysAllowed`, `openAppWhenRun = false` and
  `.background`, and asks nothing; checks `Engine.command` asks for nothing; no links in the Live Activity; the
  keychain and file class rules; held presses.
- The test build's status line: `intents ok` (read from the real types), `locked-read ok` (every keychain item and
  UserDefaults' file readable after first unlock), `held N`. `testLockScreenButtonsNeverAskToUnlock` checks them
  and a press made with the page asleep.
- What can't be checked off a real iPhone: that iOS 17/18/26 actually runs these buttons locked with no Face ID. The
  simulator can't lock and press a Live Activity button.

## The 30-second test on the phone

1. Start a workout in Virt, open an exercise, lock the phone (side button), wait for the screen to go dark.
2. Wake it (raise or tap), don't look at it for Face ID (or cover the camera), and press **Log set** on the Live
   Activity. The rest should start on the card at once, with no Face ID or passcode ask.
3. Press −15, pause, play, +15 the same way. Then unlock and open Virt: the set is logged once.

If it still asks: check Settings > Face ID & Passcode > Allow Access When Locked, and make sure the press was on a
button (a tap on the card opens the app, which always asks).
