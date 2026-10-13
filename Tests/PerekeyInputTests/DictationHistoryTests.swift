// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyInput
import PerekeyVoiceCore
import Testing

@MainActor
struct DictationHistoryTests {
    /// A history in a folder of its own and a clock the test moves.
    @MainActor final class Fixture {
        let directory = URL.temporaryDirectory.appending(path: "perekey-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        var settings = VoiceTextSettings(retention: .week)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var excluded: Set<String> = []
        var managed = ManagedSettings()

        var file: DictationHistoryFile { DictationHistoryFile(directory: directory) }

        func history() -> DictationHistory {
            DictationHistory(
                file: file, managed: managed, settings: { self.settings },
                isExcluded: { bundle, host in
                    self.excluded.contains(bundle ?? "") || self.excluded.contains(host ?? "\u{0}")
                },
                now: { self.date })
        }

        func advance(days: Double) { date = date.addingTimeInterval(days * 24 * 3600) }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func record(_ text: String = "привет мир", bundle: String? = "com.apple.Notes", host: String? = nil,
                        privacy: DictationPrivacy = .normal, audio: [Float]? = nil) -> DictationRecord {
        DictationRecord(text: text, bundleID: bundle, appName: "Notes", host: host, duration: 2.5,
                        model: "parakeet-tdt-v3", pasted: true, privacy: privacy, audio: audio)
    }

    private func isExcluded(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tmutil")
        process.arguments = ["isexcluded", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.contains("[Excluded]")
    }

    // MARK: What is kept

    @Test func recordsAndSurvivesARestart() throws {
        let fixture = Fixture()
        let history = fixture.history()
        #expect(history.record(record("первая")) == .recorded)
        fixture.advance(days: 0.1)
        #expect(history.record(record("вторая")) == .recorded)
        #expect(history.entries.map(\.text) == ["вторая", "первая"])

        let again = fixture.history()
        #expect(again.entries.map(\.text) == ["вторая", "первая"])
        #expect(again.entries.first?.bundleID == "com.apple.Notes")
        #expect(again.entries.first?.model == "parakeet-tdt-v3")
    }

    @Test func passwordFieldsAndSecureInputAreNotKept() {
        let fixture = Fixture()
        let history = fixture.history()
        #expect(history.record(record(privacy: .secureField)) == .skipped(.privateField))
        #expect(history.record(record(privacy: .secureInput)) == .skipped(.privateField))
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))
    }

    @Test func excludedAppsAndSitesAreNotKept() {
        let fixture = Fixture()
        fixture.excluded = ["com.1password.1password", "bank.example"]
        let history = fixture.history()
        #expect(history.record(record(bundle: "com.1password.1password")) == .skipped(.excludedApp))
        #expect(history.record(record(bundle: "com.apple.Safari", host: "bank.example")) == .skipped(.excludedApp))
        #expect(history.record(record(bundle: "com.apple.Safari", host: "example.org")) == .recorded)
        #expect(history.entries.count == 1)
    }

    @Test func retentionOffKeepsNothing() {
        let fixture = Fixture()
        fixture.settings.retention = .off
        let history = fixture.history()
        #expect(history.record(record()) == .skipped(.retentionOff))
        #expect(history.entries.isEmpty)
    }

    @Test func emptyTextIsNotKept() {
        let history = Fixture().history()
        #expect(history.record(record("  \n")) == .skipped(.emptyText))
    }

    // MARK: Terms

    @Test func entriesPastTheTermGoAtLaunch() {
        let fixture = Fixture()
        let history = fixture.history()
        history.record(record("старая"))
        fixture.advance(days: 5)
        history.record(record("свежая"))
        fixture.advance(days: 3)
        // "старая" is 8 days old, "свежая" 3.
        let again = fixture.history()
        #expect(again.entries.map(\.text) == ["свежая"])
    }

    @Test func entriesPastTheTermGoOnceADayWhenSomethingHappens() {
        let fixture = Fixture()
        let history = fixture.history()
        history.record(record("старая"))
        fixture.advance(days: 6.5)
        history.purgeIfDue()
        #expect(history.entries.count == 1)
        // The entry is past the term now, but the last clean was less than a day ago.
        fixture.advance(days: 0.9)
        history.purgeIfDue()
        #expect(history.entries.count == 1)
        fixture.advance(days: 0.2)
        history.purgeIfDue()
        #expect(history.entries.isEmpty)
    }

    @Test func recordingCleansToo() {
        let fixture = Fixture()
        fixture.settings.retention = .day
        let history = fixture.history()
        history.record(record("вчера"))
        fixture.advance(days: 2)
        history.record(record("сегодня"))
        #expect(history.entries.map(\.text) == ["сегодня"])
    }

    @Test func shorteningTheTermCleansAtOnce() {
        let fixture = Fixture()
        let history = fixture.history()
        history.record(record("старая"))
        fixture.advance(days: 3)
        history.record(record("свежая"))
        fixture.settings.retention = .day
        history.settingsChanged()
        #expect(history.entries.map(\.text) == ["свежая"])
        fixture.settings.retention = .off
        history.settingsChanged()
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func clearErasesEverything() {
        let fixture = Fixture()
        fixture.settings.keepsAudio = true
        let history = fixture.history()
        history.record(record(audio: [Float](repeating: 0.1, count: 16_000)))
        #expect(FileManager.default.fileExists(atPath: fixture.file.url.path))
        history.clear()
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(fixture.history().entries.isEmpty)
    }

    // MARK: Profile

    @Test func profileLimitsTheTerm() {
        #expect(HistoryRetention.month.limited(byMaxDays: 7) == .week)
        #expect(HistoryRetention.month.limited(byMaxDays: 10) == .week)
        #expect(HistoryRetention.week.limited(byMaxDays: 30) == .week)
        #expect(HistoryRetention.day.limited(byMaxDays: 7) == .day)
        #expect(HistoryRetention.week.limited(byMaxDays: 0) == .off)
        #expect(HistoryRetention.month.limited(byMaxDays: nil) == .month)
    }

    @Test func profileLimitHoldsOnDisk() {
        let fixture = Fixture()
        fixture.settings.retention = .month
        let history = fixture.history()
        history.record(record("старая"))
        fixture.advance(days: 3)
        history.record(record("свежая"))
        fixture.managed = ManagedSettings(voiceHistoryMaxDays: 1)
        let limited = fixture.history()
        #expect(limited.retention == .day)
        #expect(limited.entries.map(\.text) == ["свежая"])

        fixture.managed = ManagedSettings(voiceHistoryMaxDays: 0)
        let none = fixture.history()
        #expect(none.entries.isEmpty)
        #expect(none.record(record()) == .skipped(.retentionOff))
    }

    @Test func managedKeysAreRead() {
        let managed = ManagedSettings { key in
            switch key {
            case "VoiceHistoryMaxDays": 7
            case "VoiceCloudDisabled": true
            default: nil
            }
        }
        #expect(managed.voiceHistoryMaxDays == 7)
        #expect(managed.voiceCloudDisabled)
        #expect(ManagedSettings { _ in nil }.voiceHistoryMaxDays == nil)
        #expect(ManagedSettings { $0 == "VoiceHistoryMaxDays" ? -5 : nil }.voiceHistoryMaxDays == 0)
    }

    // MARK: Time Machine

    @Test func fileAndFolderStayOutOfTimeMachine() {
        let fixture = Fixture()
        fixture.settings.keepsAudio = true
        let history = fixture.history()
        history.record(record(audio: [Float](repeating: 0.1, count: 16_000)))
        history.record(record("ещё"))
        #expect(isExcluded(fixture.directory))
        #expect(isExcluded(fixture.file.url))
        #expect(isExcluded(fixture.file.audioDirectory))
        let entry = history.entries.last!
        #expect(isExcluded(fixture.file.audioURL(for: entry.id)))
    }

    // MARK: Newer schema

    @Test func fileOfANewerVersionIsShownAndNeverWritten() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let newer = """
        {"schemaVersion": 99, "entries": [{"id": "\(UUID().uuidString)", "text": "из будущего",
         "date": "2027-01-01T10:00:00Z", "duration": 1, "model": "m", "pasted": true, "hasAudio": false}], "extra": 1}
        """
        try newer.write(to: fixture.file.url, atomically: true, encoding: .utf8)
        let history = fixture.history()
        #expect(history.isReadOnly)
        #expect(history.entries.map(\.text) == ["из будущего"])
        #expect(history.record(record()) == .skipped(.readOnly))
        history.clear()
        history.purge()
        #expect(try String(contentsOf: fixture.file.url, encoding: .utf8) == newer)
    }

    @Test func brokenFileIsSetAside() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try "not json".write(to: fixture.file.url, atomically: true, encoding: .utf8)
        let history = fixture.history()
        #expect(history.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.file.brokenURL.path))
        #expect(history.record(record()) == .recorded)
    }

    // MARK: Audio

    @Test func audioIsKeptOnlyWhenAsked() {
        let fixture = Fixture()
        let samples = [Float](repeating: 0.1, count: 16_000)
        let history = fixture.history()
        history.record(record(audio: samples))
        #expect(history.entries.first?.hasAudio == false)
        #expect(history.audioURL(of: history.entries[0]) == nil)

        fixture.settings.keepsAudio = true
        history.record(record("со звуком", audio: samples))
        let entry = history.entries[0]
        #expect(entry.hasAudio)
        let url = history.audioURL(of: entry)!
        let head = try? Data(contentsOf: url).prefix(2)
        // ADTS sync word: 12 set bits.
        #expect(head?.first == 0xFF && ((head?.last ?? 0) & 0xF0) == 0xF0)
        #expect(url.pathExtension == "aac")
    }

    @Test func audioGoesWithItsEntry() {
        let fixture = Fixture()
        fixture.settings.keepsAudio = true
        let samples = [Float](repeating: 0.1, count: 16_000)
        let history = fixture.history()
        history.record(record("старая", audio: samples))
        let old = history.entries[0]
        fixture.advance(days: 3)
        history.record(record("свежая", audio: samples))
        let fresh = history.entries[0]
        #expect(fixture.file.audioIDs() == [old.id, fresh.id])

        fixture.advance(days: 5)
        history.purge()
        #expect(history.entries.map(\.text) == ["свежая"])
        #expect(fixture.file.audioIDs() == [fresh.id])

        history.remove(fresh.id)
        #expect(fixture.file.audioIDs().isEmpty)
    }

    @Test func turningAudioOffDeletesTheFiles() {
        let fixture = Fixture()
        fixture.settings.keepsAudio = true
        let history = fixture.history()
        history.record(record(audio: [Float](repeating: 0.1, count: 16_000)))
        #expect(fixture.file.audioIDs().count == 1)
        fixture.settings.keepsAudio = false
        history.settingsChanged()
        #expect(fixture.file.audioIDs().isEmpty)
        #expect(history.entries.count == 1 && history.entries[0].hasAudio == false)
    }

    @Test func orphanAudioIsRemoved() throws {
        let fixture = Fixture()
        fixture.settings.keepsAudio = true
        let history = fixture.history()
        history.record(record(audio: [Float](repeating: 0.1, count: 16_000)))
        let stray = UUID()
        try Data([1, 2, 3]).write(to: fixture.file.audioURL(for: stray))
        history.purge()
        #expect(!fixture.file.audioIDs().contains(stray))
        #expect(fixture.file.audioIDs().count == 1)
    }

    // MARK: Menu

    @Test func menuListsTheTwentyNewest() {
        let fixture = Fixture()
        let history = fixture.history()
        for index in 0..<25 {
            fixture.advance(days: 0.001)
            history.record(record("диктовка \(index)"))
        }
        let recent = history.recent()
        #expect(recent.count == 20)
        #expect(recent.first?.text == "диктовка 24")
        #expect(recent.last?.text == "диктовка 5")
    }

    @Test func previewIsOneShortLine() {
        #expect(DictationHistoryText.preview("коротко") == "коротко")
        let long = String(repeating: "слово ", count: 20)
        #expect(DictationHistoryText.preview(long).count == 41)
        #expect(DictationHistoryText.preview(long).hasSuffix("\u{2026}"))
        #expect(DictationHistoryText.preview("раз\nдва") == "раз два")
        #expect(DictationHistoryText.wordCount("Привет, мир! It's fine.") == 4)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndKeepUnknownKeys() throws {
        let url = URL.temporaryDirectory.appending(path: "perekey-vt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = VoiceTextSettingsFile(url: url)
        #expect(file.load() == VoiceTextSettings())
        #expect(file.load().retention == .week)
        #expect(file.load().keepsAudio == false)

        var settings = VoiceTextSettings(dictionary: [DictionaryEntry(from: "а", to: "б")], retention: .month, keepsAudio: true)
        settings.removesFillers = false
        try file.save(settings)
        #expect(file.load() == settings)

        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["futureKey"] = "kept"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try file.save(settings)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved["futureKey"] as? String == "kept")
    }

    @Test func settingsOfANewerVersionAreNeverWritten() throws {
        let url = URL.temporaryDirectory.appending(path: "perekey-vt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = #"{"schemaVersion": 7, "retention": "month"}"#
        try text.write(to: url, atomically: true, encoding: .utf8)
        let store = VoiceTextStore(file: VoiceTextSettingsFile(url: url))
        #expect(store.isLocked)
        #expect(store.settings.retention == .month)
        store.update { $0.keepsAudio = true }
        #expect(!store.settings.keepsAudio)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func storeEditsTheDictionary() {
        let store = VoiceTextStore(file: nil)
        let start = store.settings.dictionary.count
        #expect(store.setEntry(from: " Вася ", to: "Vasya"))
        #expect(store.settings.dictionary.count == start + 1)
        #expect(store.setEntry(from: "вася", to: "Vasia"))
        #expect(store.settings.dictionary.count == start + 1)
        #expect(store.settings.dictionary.last?.to == "Vasia")
        #expect(!store.setEntry(from: "", to: "x"))
        store.removeEntry(store.settings.dictionary.last!)
        #expect(store.settings.dictionary.count == start)
    }

    @Test func storeOffersOnlyTermsTheProfileAllows() {
        let store = VoiceTextStore(file: nil, managed: ManagedSettings(voiceHistoryMaxDays: 7))
        #expect(store.availableRetentions == [.off, .day, .week])
        store.update { $0.retention = .month }
        #expect(store.effectiveRetention == .week)
    }
}
