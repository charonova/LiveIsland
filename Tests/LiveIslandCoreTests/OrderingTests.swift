import Testing
@testable import LiveIslandCore

@Suite("Tab order")
struct OrderingTests {
    let tabs = ["Media", "Agents", "Activity", "Accounts"]

    func restore(_ saved: [String]) -> [String] {
        Ordering.restore(saved, all: tabs, name: { $0 })
    }

    @Test func keepsTheOrderThePersonPicked() {
        #expect(restore(["Agents", "Media", "Accounts", "Activity"]) == ["Agents", "Media", "Accounts", "Activity"])
    }

    @Test func startsFromTheDefaultOrder() {
        #expect(restore([]) == tabs)
    }

    @Test func dropsTabsThatNoLongerExistAndRepeats() {
        #expect(restore(["Agents", "Weather", "Agents", "Media"]) == ["Agents", "Media", "Activity", "Accounts"])
    }

    @Test func addsNewTabsAtTheEnd() {
        // An order saved before Accounts existed.
        #expect(restore(["Activity", "Agents", "Media"]) == ["Activity", "Agents", "Media", "Accounts"])
    }

    @Test func movesOnePlaceAtATime() {
        #expect(Ordering.move(tabs, from: 1, by: -1) == ["Agents", "Media", "Activity", "Accounts"])
        #expect(Ordering.move(tabs, from: 1, by: 1) == ["Media", "Activity", "Agents", "Accounts"])
        #expect(Ordering.move(tabs, from: 0, by: 3) == ["Agents", "Activity", "Accounts", "Media"])
    }

    @Test func stopsAtTheEnds() {
        #expect(Ordering.move(tabs, from: 0, by: -1) == tabs)
        #expect(Ordering.move(tabs, from: 3, by: 1) == tabs)
        #expect(Ordering.move(tabs, from: 9, by: -1) == tabs)
    }
}
