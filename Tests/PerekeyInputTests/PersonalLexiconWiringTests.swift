// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

/// The joint between the app, the store and the tap
/// (`PersonalLexiconWiring`): the setting in, the snapshot out, the retry of
/// a Keychain that refused the key on the app's activation and on the unlock.
/// The engine runs with no tap; notification centers are the test's own.
@MainActor
struct PersonalLexiconWiringTests {
    @MainActor private final class Counter {
        var value = 0
    }

    @MainActor
    private final class Rig {
        let engine = InputEngine(machine: InputMachine()) { _ in }
        let keys: MemoryLexiconKeyStore
        let store: PersonalLexiconStore
        let wiring: PersonalLexiconWiring
        let application = NotificationCenter()
        let distributed = NotificationCenter()

        init(allowed: Bool = true, keys: MemoryLexiconKeyStore = MemoryLexiconKeyStore()) {
            self.keys = keys
            store = PersonalLexiconStore(file: nil, keys: keys, today: { 20_000 }, allowed: allowed)
            let engine = engine
            wiring = PersonalLexiconWiring(store: store) { [engine] lexicon in engine.handle(.personalLexiconChanged(lexicon)) }
                        wiring.observe(application: application, distributed: distributed)
        }

        var tap: PersonalLexicon { engine.personalLexicon }

        /// Waits until what was posted before this call has been delivered: the queue is in order, so a
        /// post of the test's own, heard last, says the rest were heard or let go.
        func delivered() async {
            let name = Notification.Name("test-sentinel")
            let arrived = Counter()
            for center in [application, distributed] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { arrived.value += 1 }
                }
                center.post(name: name, object: nil)
                await waitUntil("the sentinel came through") { arrived.value > 0 }
                arrived.value = 0
                center.removeObserver(token)
            }
        }
    }

    @Test func theSettingOnGivesTheTapAnEmptyLexiconWithTheKeyAndOffTakesItBack() throws {
        let rig = Rig()
        #expect(!rig.tap.isOn, "before the setting is applied: off")
        rig.wiring.settingsChanged(personalWords: false)
        #expect(!rig.tap.isOn, "off from the start: the tap has nothing, no key was asked for")
        #expect(rig.keys.created == 0)
        rig.wiring.settingsChanged(personalWords: true)
        #expect(rig.tap.isOn && !rig.tap.hasWords)
        #expect(rig.tap.key == (try rig.keys.load()))
        rig.wiring.settingsChanged(personalWords: false)
        #expect(rig.tap == .off)
    }

    @Test func theSameSettingTwiceIsOneKey() {
        let rig = Rig()
        rig.wiring.settingsChanged(personalWords: true)
        rig.wiring.settingsChanged(personalWords: true)
        #expect(rig.keys.created == 1)
    }

    @Test func aProfileThatForbidsItLeavesTheTapOffWhateverTheSetting() {
        let rig = Rig(allowed: false)
        rig.wiring.settingsChanged(personalWords: true)
        #expect(rig.tap == .off)
        #expect(rig.keys.created == 0)
        rig.wiring.settingsChanged(personalWords: false)
        rig.wiring.settingsChanged(personalWords: true)
        #expect(rig.tap == .off)
    }

    @Test func theActivationOfTheAppAsksTheKeychainAgainAndTheTapGetsTheLexicon() async {
        let rig = Rig(keys: MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308)))
        rig.wiring.settingsChanged(personalWords: true)
        #expect(rig.tap == .off)
        let asked = rig.keys.loaded
        rig.application.post(name: PersonalLexiconWiring.appActivated, object: nil)
        await waitUntil("the activation asked the keychain") { rig.keys.loaded == asked + 1 }
        #expect(rig.tap == .off && rig.store.unavailable == .keychain, "still refused: still off")
        rig.keys.setFailure(nil)
        rig.application.post(name: PersonalLexiconWiring.appActivated, object: nil)
        await waitUntil("the tap has the lexicon") { rig.tap.isOn }
        #expect(rig.store.isActive)
    }

    @Test func theUnlockOfTheScreenAsksTheKeychainAgain() async {
        let rig = Rig(keys: MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308)))
        rig.wiring.settingsChanged(personalWords: true)
        rig.keys.setFailure(nil)
        rig.distributed.post(name: PersonalLexiconWiring.screenUnlocked, object: nil)
        await waitUntil("the tap has the lexicon") { rig.tap.isOn }
    }

    @Test func theActivationIsNotHeardOnTheUnlockCenterNorTheUnlockOnTheOther() async {
        let rig = Rig(keys: MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308)))
        rig.wiring.settingsChanged(personalWords: true)
        let asked = rig.keys.loaded
        rig.distributed.post(name: PersonalLexiconWiring.appActivated, object: nil)
        rig.application.post(name: PersonalLexiconWiring.screenUnlocked, object: nil)
        rig.application.post(name: Notification.Name("something else"), object: nil)
        await rig.delivered()
        #expect(rig.keys.loaded == asked, "none of the three is a reason to ask")
    }

    @Test func afterStopObservingNothingIsHeardAndObservingAgainHearsOnce() async {
        let rig = Rig(keys: MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308)))
        rig.wiring.settingsChanged(personalWords: true)
        let asked = rig.keys.loaded
        rig.wiring.stopObserving()
        rig.application.post(name: PersonalLexiconWiring.appActivated, object: nil)
        rig.distributed.post(name: PersonalLexiconWiring.screenUnlocked, object: nil)
        await rig.delivered()
        #expect(rig.keys.loaded == asked)
        rig.wiring.observe(application: rig.application, distributed: rig.distributed)
        rig.application.post(name: PersonalLexiconWiring.appActivated, object: nil)
        await rig.delivered()
        #expect(rig.keys.loaded == asked + 1)
    }

    @Test func observingAgainDoesNotDoubleTheListeners() async {
        let rig = Rig(keys: MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308)))
        rig.wiring.settingsChanged(personalWords: true)
        rig.wiring.observe(application: rig.application, distributed: rig.distributed)
        let asked = rig.keys.loaded
        rig.application.post(name: PersonalLexiconWiring.appActivated, object: nil)
        rig.distributed.post(name: PersonalLexiconWiring.screenUnlocked, object: nil)
        await rig.delivered()
        #expect(rig.keys.loaded == asked + 2, "one ask per post")
    }

    @Test func theNamesAreTheOnesTheSystemPosts() {
        #expect(PersonalLexiconWiring.screenUnlocked.rawValue == "com.apple.screenIsUnlocked")
        #expect(PersonalLexiconWiring.appActivated.rawValue == "NSApplicationDidBecomeActiveNotification")
    }
}
