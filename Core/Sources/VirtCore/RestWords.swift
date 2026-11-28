import Foundation

/// What a rest is called on the lock screen and in the Dynamic Island, the same way the website's workout says it
/// (Tyler, Nov 27: "instead of the word rest between workouts I want next exercise starts in: ... but in between
/// reps/sets it's still rest"; the website's v3/up-next.js, `waitWords`):
///
/// - "Next exercise" when the rest leads to a different exercise from the one just logged: the last set of an
///   exercise before the next one, a pair's or circuit's switch to its next exercise, a timed exercise's turn.
/// - "Rest" between sets of the same exercise, and for a pair's or circuit's rest between rounds (the website keeps
///   "Rest" there too, as its circuit card says "Rest · then round 2 of 4").
/// - "Rest" whenever Virt can't tell (nothing logged yet, a rest from Siri with nothing known after it).
///
/// Only the words change: the page still sends `label: 'Rest'` for every rest, and Virt picks the words from what
/// the page already says (`set.logged`'s exercise, `nextSet`, the rest's `next`) or from its own Log set. Plain values,
/// so the tests can walk every case.
public enum RestWords {
    public static let rest = "Rest"
    public static let nextExercise = "Next exercise"
    /// The same, where there's only room for a word (the expanded Dynamic Island's leading corner).
    public static let nextShort = "Next"

    /// - `logged`: the exercise of the set just logged (the page's `set.logged`, or Log set's own).
    /// - `loggedLast`: that set was its exercise's last (only Log set knows; the page's `next` says it otherwise).
    /// - `nextSet`: the set Log set would log once the rest is over (the page's `nextSet` and `set.next`, or Log set's
    ///   `then`).
    /// - `next`: what the rest leads to, in the page's words: "set 3 of Chest press machine", "Leg press",
    ///   "round 2 of 3", "A2 Seated row machine", "Plank".
    public static func label(logged: String?, loggedLast: Bool = false, nextSet: NextSet?, next: String) -> String {
        let said = next.trimmingCharacters(in: .whitespacesAndNewlines)
        // a pair's or circuit's rest between rounds stays "Rest", as on the website
        if said.range(of: #"^round \d+ of \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return rest }
        guard let logged = logged?.trimmingCharacters(in: .whitespacesAndNewlines), !logged.isEmpty else { return rest }
        // the set the next Log set would log: its exercise says it
        if let n = nextSet, !n.exercise.isEmpty { return same(n.exercise, logged) ? rest : nextExercise }
        // "set 3 of Chest press machine": another set of the exercise it names
        if let r = said.range(of: #"^set \d+ of "#, options: [.regularExpression, .caseInsensitive]) {
            return same(String(said[r.upperBound...]), logged) ? rest : nextExercise
        }
        // nothing named: only the end of the exercise says a different one comes next (or the workout's end)
        if said.isEmpty || ["the next set", "the next one", "done"].contains(said.lowercased()) {
            return loggedLast ? nextExercise : rest
        }
        // a name: the next exercise, or a timed exercise's turn
        return same(said, logged) ? rest : nextExercise
    }

    /// The short form of a label, for the narrowest place it shows.
    public static func short(_ label: String) -> String { label == nextExercise ? nextShort : label }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b) == .orderedSame
    }
}
