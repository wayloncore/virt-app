import XCTest
@testable import VirtCore

/// Virt's settings through the bridge (the You tab): the object the page sees, the event, the page's requests, who may
/// send them, and what sign out and Delete account do. Plus `today`'s optional `screen`.
final class PrefsTests: XCTestCase {
    func json(_ s: String) -> Data { s.data(using: .utf8)! }

    let standard = AppPrefs(sounds: true, soundStyle: .chime, reminders: true, reminderLine: "6:00 PM on Mon, Tue and Thu",
                            lockAfter: .fifteenMinutes, notifications: true)

    // MARK: - The object

    func testThePrefsObject() {
        XCTAssertEqual(standard.json,
                       #"{"sounds":true,"soundStyle":"chime","reminders":true,"reminderLine":"6:00 PM on Mon, Tue and Thu","lockAfter":"15m","notifications":"on"}"#)
        let off = AppPrefs(sounds: false, soundStyle: .classic, reminders: false, reminderLine: "6:00 PM every day",
                           lockAfter: .never, notifications: false)
        XCTAssertEqual(off.json,
                       #"{"sounds":false,"soundStyle":"classic","reminders":false,"reminderLine":"","lockAfter":"never","notifications":"off"}"#,
                       "the line is empty while reminders are off")
        // it's real JSON, with exactly the contract's keys and value types
        let o = try! JSONSerialization.jsonObject(with: json(standard.json)) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["sounds", "soundStyle", "reminders", "reminderLine", "lockAfter", "notifications"])
        XCTAssertEqual(o["sounds"] as? Bool, true)
        XCTAssertEqual(o["lockAfter"] as? String, "15m")
        for l in LockAfter.allCases {
            var p = standard; p.lockAfter = l
            XCTAssertTrue(p.json.contains("\"lockAfter\":\"\(l.rawValue)\""))
        }
        XCTAssertEqual(LockAfter.allCases.map(\.rawValue), ["now", "15m", "1h", "never"], "the contract's values")
        XCTAssertEqual(SoundStyle.allCases.map(\.rawValue), ["chime", "digital", "classic"], "the contract's values")
    }

    func testTheLineCanNeverBreakOutOfItsQuotes() {
        var p = standard
        p.reminderLine = "a\"b\\c\nd</script><b>\u{2028}e\u{0}"
        let o = try! JSONSerialization.jsonObject(with: json(p.json)) as! [String: Any]
        XCTAssertEqual(o["reminderLine"] as? String, p.reminderLine, "the same text comes back out")
        XCTAssertFalse(p.json.contains("</script>"))
        XCTAssertFalse(p.json.contains("\u{2028}"))
        XCTAssertFalse(p.json.contains("\n"))
        XCTAssertEqual(AppPrefs.quote("6:00 PM on Mon"), "\"6:00 PM on Mon\"")
    }

    func testTheEventAndThePageStart() {
        let e = standard.eventScript
        XCTAssertTrue(e.contains("new CustomEvent('kinetic:prefs', { detail: p })"))
        XCTAssertTrue(e.contains("const p = \(standard.json);"))
        XCTAssertTrue(e.contains("Object.assign(k.prefs, p)"), "kineticApp.prefs is brought up to date in place")

        let start = PageStart.script(build: 90, prefs: standard)
        XCTAssertTrue(start.contains("app.prefs = \(standard.json);"))
        XCTAssertTrue(start.contains("window.kineticApp = Object.freeze(app)"))
        XCTAssertTrue(start.range(of: "app.prefs =")!.lowerBound < start.range(of: "Object.freeze(app)")!.lowerBound,
                      "prefs are on the object before it's frozen")
        XCTAssertFalse(start.contains("Object.freeze(app.prefs)"), "the prefs object itself can be updated by the event")
        XCTAssertTrue(start.contains("app: 'virt', version: 2, sounds: ['lead-in', 'zero', 'set', 'finish'], settings: true, build: 90"),
                      "nothing an older page reads changes")
        XCTAssertFalse(PageStart.script(build: 90).contains("prefs"), "without prefs, exactly as before")
    }

    func testTheRemindersLine() {
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [1, 2, 4], usualTime: "18:00")), "6:00 PM on Mon, Tue and Thu")
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [0, 1, 2, 3, 4, 5, 6], usualTime: "07:05")), "7:05 AM every day")
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [3], usualTime: "12:30")), "12:30 PM on Wed")
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [1, 3])), "", "no time yet")
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [], usualTime: "18:00")), "", "no days yet")
        XCTAssertEqual(ReminderLine.short(TodayInfo(trainingDays: [9], usualTime: "18:00")), "", "no real days")
        XCTAssertEqual(ReminderLine.short(nil), "")
    }

    // MARK: - The page's requests

    func testThePagesRequests() {
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"pref","key":"sounds","value":false}"#)), .setSounds(false))
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"pref","key":"sounds","value":true}"#)), .setSounds(true))
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"pref","key":"soundStyle","value":"digital"}"#)), .setSoundStyle(.digital))
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"pref","key":"reminders","value":true}"#)), .setReminders(true))
        for l in LockAfter.allCases {
            XCTAssertEqual(AppRequest.decode(json(#"{"type":"pref","key":"lockAfter","value":"\#(l.rawValue)"}"#)), .setLockAfter(l))
        }
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"openNotificationSettings"}"#)), .openNotificationSettings)
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"deleteAccount"}"#)), .deleteAccount)
        XCTAssertEqual(AppRequest.decode(json(#"{"type":"signOut","extra":1}"#)), .signOut, "more fields still read")
        XCTAssertEqual(AppRequest.decode(object: ["type": "pref", "key": "lockAfter", "value": "never"]), .setLockAfter(.never),
                       "as WebKit hands it over")
        XCTAssertEqual(AppRequest.decode(object: ["type": "pref", "key": "sounds", "value": false]), .setSounds(false))
    }

    func testUnknownKeysAndOutOfRangeValuesAreIgnored() {
        let ignored = [
            #"{"type":"pref","key":"volume","value":true}"#,
            #"{"type":"pref","key":"lockAfter","value":"5m"}"#,
            #"{"type":"pref","key":"lockAfter","value":"Never"}"#,
            #"{"type":"pref","key":"lockAfter","value":15}"#,
            #"{"type":"pref","key":"soundStyle","value":"loud"}"#,
            #"{"type":"pref","key":"sounds","value":"false"}"#,
            #"{"type":"pref","key":"sounds","value":0}"#,
            #"{"type":"pref","key":"sounds","value":null}"#,
            #"{"type":"pref","key":"reminders"}"#,
            #"{"type":"pref","value":true}"#,
            #"{"type":"pref","key":["sounds"],"value":true}"#,
            #"{"type":"pref","key":"sounds","value":{"on":true}}"#,
            #"{"type":"settings"}"#,
            #"{"type":"timer.start","id":"x"}"#,
            #"{"key":"sounds","value":true}"#,
            #"[1,2]"#,
            #"nope"#,
        ]
        for m in ignored { XCTAssertNil(AppRequest.decode(json(m)), m) }
        XCTAssertNil(AppRequest.decode(object: "pref"))
        XCTAssertTrue(AppRequest.isRequest(object: ["type": "pref", "key": "nope"]), "a bad pref is still a pref: never an Engine message")
        XCTAssertTrue(AppRequest.isRequest(object: ["type": "signOut"]))
        XCTAssertFalse(AppRequest.isRequest(object: ["type": "settings"]), "the sheet's own message stays as it was")
        XCTAssertFalse(AppRequest.isRequest(object: ["type": "today"]))
        XCTAssertFalse(AppRequest.isRequest(object: "signOut"))
    }

    func testOnlyTrainingsOwnMainFrameMayAsk() {
        XCTAssertTrue(AppRequest.allowed(isMainFrame: true, scheme: "https", host: "train.time2play.live", bundled: false))
        XCTAssertTrue(AppRequest.allowed(isMainFrame: true, scheme: "https", host: "studio.tyleralocke.com", bundled: false))
        XCTAssertTrue(AppRequest.allowed(isMainFrame: true, scheme: "virt-app", host: "train", bundled: true))
        XCTAssertFalse(AppRequest.allowed(isMainFrame: true, scheme: "virt-app", host: "train", bundled: false), "the bundle's origin only in bundled mode")
        XCTAssertFalse(AppRequest.allowed(isMainFrame: false, scheme: "https", host: "train.time2play.live", bundled: false), "never an embedded frame")
        XCTAssertFalse(AppRequest.allowed(isMainFrame: false, scheme: "https", host: "studio.tyleralocke.com", bundled: false))
        XCTAssertFalse(AppRequest.allowed(isMainFrame: true, scheme: "http", host: "studio.tyleralocke.com", bundled: false))
        XCTAssertFalse(AppRequest.allowed(isMainFrame: true, scheme: "https", host: "tyleralocke.com", bundled: false))
        XCTAssertFalse(AppRequest.allowed(isMainFrame: true, scheme: "https", host: "www.youtube.com", bundled: true))
        XCTAssertFalse(AppRequest.allowed(isMainFrame: true, scheme: "https", host: "studio.tyleralocke.com.evil.example", bundled: false))
    }

    func testSignOutAndDeleteFollowTheSheetsRules() {
        let d = AccountAsk.decide
        XCTAssertEqual(d(.signOut, .friend, false, false, false), .confirmSignOut)
        XCTAssertEqual(d(.signOut, .tyler, false, false, false), .confirmSignOut)
        XCTAssertEqual(d(.signOut, .friend, true, false, false), .confirmSignOut, "Tyler's own Training with Apple: Sign out")
        XCTAssertEqual(d(.signOut, .friend, false, false, true), .finishFirst, "waits during a workout")
        XCTAssertEqual(d(.signOut, .friend, false, true, false), .ignore, "never for a guest")
        XCTAssertEqual(d(.signOut, nil, false, false, false), .ignore, "no one signed in")

        XCTAssertEqual(d(.deleteAccount, .friend, false, false, false), .confirmDelete)
        XCTAssertEqual(d(.deleteAccount, .friend, false, false, true), .finishFirst)
        XCTAssertEqual(d(.deleteAccount, .friend, false, true, false), .ignore, "never for a guest")
        XCTAssertEqual(d(.deleteAccount, .friend, true, false, false), .ignore, "not Tyler's own account: the sheet doesn't offer it")
        XCTAssertEqual(d(.deleteAccount, .tyler, false, false, false), .ignore, "not on the studio's door: the sheet doesn't offer it")
        XCTAssertEqual(d(.deleteAccount, nil, false, false, false), .ignore)

        XCTAssertEqual(d(.setSounds(true), .friend, false, false, false), .ignore, "settings aren't account asks")
        XCTAssertEqual(AccountAsk.finishFirstLine, "Finish the workout first, then you can switch.")
    }

    // MARK: - today's screen

    func testTodaysScreen() {
        guard case .today(let w)? = BridgeMessage.decode(json(#"{"type":"today","title":"Legs A","live":true,"screen":"workout"}"#)) else {
            return XCTFail("today")
        }
        XCTAssertEqual(w.workoutScreen, .workout)
        guard case .today(let o)? = BridgeMessage.decode(json(#"{"type":"today","screen":"other"}"#)) else { return XCTFail("today") }
        XCTAssertEqual(o.workoutScreen, .other)
        guard case .today(let n)? = BridgeMessage.decode(json(#"{"type":"today","title":"Legs A"}"#)) else { return XCTFail("today") }
        XCTAssertNil(n.workoutScreen, "an older page doesn't say")
        guard case .today(let odd)? = BridgeMessage.decode(json(#"{"type":"today","title":"Legs A","screen":"settings"}"#)),
              case .today(let bad)? = BridgeMessage.decode(json(#"{"type":"today","title":"Legs A","screen":3}"#)) else { return XCTFail("today") }
        XCTAssertNil(odd.workoutScreen, "a screen this Virt doesn't know")
        XCTAssertNil(bad.workoutScreen)
        XCTAssertEqual(bad.title, "Legs A", "a wrong type is skipped, not the message")

        var a = w; a.screen = "other"
        XCTAssertTrue(a.samePlan(as: w), "moving between screens isn't a new plan for the widgets")

        // saved with the field, read back; and a copy saved by an older Virt reads
        XCTAssertEqual(TodayInfo.decodeStored(w.encoded()!), w)
        XCTAssertNil(TodayInfo.decodeStored(json(#"{"title":"Legs A"}"#))?.screen)
    }
}
