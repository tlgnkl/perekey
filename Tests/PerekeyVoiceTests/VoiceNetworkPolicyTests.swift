// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

struct VoiceNetworkPolicyTests {
    @Test func theNetworkIsOpenOnlyForVoiceThatIsOnAndAllowed() {
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings()) == [.modelDownload])
        #expect(VoiceNetworkPolicy.allowed(isEnabled: false, managed: ManagedSettings()).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceDisabled: true)).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceModelDownloadsDisabled: true)).isEmpty)
        // Not even the cloud purposes: nothing is allowed that no feature asked for.
        #expect(!VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings()).contains(.cloudSpeech))
    }

    /// Cloud speech reaches a server agreed for a dictation's audio or for
    /// recordings of conversations; neither, no server.
    @Test func conversationConsentOpensCloudSpeech() throws {
        var modes = VoiceModeSet.defaults()
        let groq = try #require(modes.endpoint(VoiceEndpoint.Preset.groq.rawValue)?.endpointAddress?.origin)
        func speech() -> Set<String> {
            VoiceNetworkPolicy.origins(isEnabled: true, managed: ManagedSettings(), modes: modes)[.cloudSpeech] ?? []
        }
        #expect(!speech().contains(groq))
        modes.consent(.conversationAudio, endpoint: VoiceEndpoint.Preset.groq.rawValue)
        #expect(speech().contains(groq))
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: ManagedSettings(voiceCloudDisabled: true),
                                           modes: modes)[.cloudSpeech]?.contains(groq) != true)
    }

    /// A summary reaches a server agreed for transcripts of conversations,
    /// and no other: consent to a dictation's text or to a recording is not it.
    @Test func transcriptConsentAloneOpensSummaries() throws {
        var modes = VoiceModeSet.defaults()
        let openAI = VoiceEndpoint.Preset.openAI.rawValue
        let origin = try #require(modes.endpoint(openAI)?.endpointAddress?.origin)
        func summaries(_ managed: ManagedSettings = ManagedSettings()) -> Set<String> {
            VoiceNetworkPolicy.origins(isEnabled: true, managed: managed, modes: modes)[.conversationLanguageModel] ?? []
        }
        #expect(summaries().contains("http://localhost:11434"), "this Mac needs no consent")
        modes.consent([.text, .selection, .app, .site, .audio, .conversationAudio], endpoint: openAI)
        #expect(!summaries().contains(origin))
        modes.consent(.conversationText, endpoint: openAI)
        #expect(summaries().contains(origin))
        // A dictation's language model does not get the transcript's origins by it.
        modes.revokeConsent(endpoint: openAI)
        modes.consent(.conversationText, endpoint: openAI)
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: ManagedSettings(),
                                           modes: modes)[.cloudLanguageModel]?.contains(origin) != true)
        #expect(!summaries(ManagedSettings(voiceCloudDisabled: true)).contains(origin))
    }

    /// Without the consent the gate stops a summary before any request.
    @Test func aSummaryWithoutConsentMakesNoRequest() async throws {
        let fake = try await FakeOpenAI()
        let address = fake.address
        // The fake server is on 127.0.0.1: an origin the policy would open; this one opens none for summaries.
        fake.http.allowed = [.cloudLanguageModel, .conversationLanguageModel]
        fake.http.allowedOrigins = [.cloudLanguageModel: [address.origin]]
        let server = SummaryServer(model: "m", address: address, key: nil, http: fake.http)
        let summarizer = TranscriptSummarizer(model: server, budget: server.budget)
        await #expect(throws: SummaryFailure.needsConsent) {
            try await summarizer.run(.summary, lines: ["[0:01] Аня: Привет"], language: "ru")
        }
        #expect(fake.http.requests.isEmpty)
        #expect(fake.server.requests.isEmpty)
        // With its origin open, the same request goes out as a conversation's.
        fake.http.allowedOrigins[.conversationLanguageModel] = [address.origin]
        let text = try await summarizer.run(.summary, lines: ["[0:01] Аня: Привет"], language: "ru")
        #expect(text == "Привет, мир.")
        #expect(fake.http.requests.map(\.purpose) == [.conversationLanguageModel])
    }

    @Test func aNewerFileAndAnUnsupportedMacKeepTheNetworkClosed() async throws {
        let managed = ManagedSettings()
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, newerSchemaVersion: 2, managed: managed).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, isSupported: false, managed: managed).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, newerSchemaVersion: nil, isSupported: true, managed: managed)
            == [.modelDownload])

        // A real voice.json of a newer version with the switch on opens nothing.
        let data = Data(#"{"schemaVersion":99,"isEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: data)
        let fixture = try await Fixture()
        VoiceNetworkPolicy.apply(isEnabled: settings.isEnabled, newerSchemaVersion: settings.newerSchemaVersion,
                                 managed: managed, to: fixture.http)
        #expect(fixture.http.allowed.isEmpty)
        await #expect(throws: VoiceModelFailure.networkBlocked) { try await fixture.store().download("asr") }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func voiceOffMeansNoRequestsAtAll() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()

        VoiceNetworkPolicy.apply(isEnabled: false, managed: ManagedSettings(), to: fixture.http)
        #expect(fixture.http.allowed.isEmpty)
        await #expect(throws: VoiceModelFailure.networkBlocked) { try await store.download("asr") }
        #expect(fixture.http.requests.isEmpty)
        #expect(fixture.server.requests.isEmpty)

        // Turning voice on opens it, and turning it off closes it again.
        VoiceNetworkPolicy.apply(isEnabled: true, managed: ManagedSettings(), to: fixture.http)
        try await store.download("other")
        #expect(await store.status(of: "other")?.state == .ready)
        let requests = fixture.server.requests.count
        #expect(requests > 0)

        VoiceNetworkPolicy.apply(isEnabled: false, managed: ManagedSettings(), to: fixture.http)
        await #expect(throws: VoiceModelFailure.networkBlocked) { try await store.download("asr") }
        #expect(fixture.server.requests.count == requests)
    }

    @Test func theDefaultModelIsInTheCatalog() {
        #expect(ModelCatalog.entry(id: VoiceSettings.defaultModel)?.engine.recognizes == true)
    }

    @Test func hostSupportNeedsAppleSiliconAndMacOS15() {
        #expect(VoiceHost.isSupported(isAppleSilicon: true, osMajorVersion: 15))
        #expect(VoiceHost.isSupported(isAppleSilicon: true, osMajorVersion: 26))
        #expect(!VoiceHost.isSupported(isAppleSilicon: true, osMajorVersion: 14))
        #expect(!VoiceHost.isSupported(isAppleSilicon: false, osMajorVersion: 15))
    }
}
