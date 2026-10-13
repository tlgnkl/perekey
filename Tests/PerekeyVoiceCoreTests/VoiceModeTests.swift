// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyVoiceCore
import Testing

struct VoiceModeTests {
    @Test func enterIsNeverKeptWithALanguageModel() {
        var mode = VoiceMode(id: "m", name: "M", output: .pasteAndEnter)
        #expect(mode.output == .pasteAndEnter)
        mode.refine = RefineConfig(endpoint: "ollama", model: "qwen2.5:7b", prompt: "Fix it.")
        #expect(mode.output == .paste)
        #expect(!mode.allowsEnter)
        mode.output = .pasteAndEnter
        #expect(mode.output == .paste)
        mode.refine = nil
        mode.output = .pasteAndEnter
        #expect(mode.output == .pasteAndEnter)
        mode.rules.singleLine = true
        #expect(mode.output == .paste)
        let built = VoiceMode(id: "x", name: "X", refine: RefineConfig(endpoint: "a", model: "b", prompt: "c"),
                              output: .pasteAndEnter)
        #expect(built.output == .paste)
    }

    @Test func aFileCannotSmuggleEnterIntoALanguageModelMode() throws {
        let json = #"{"id":"m","name":"M","refine":{"endpoint":"openai","model":"gpt-4o-mini","prompt":"p"},"output":"pasteAndEnter"}"#
        let mode = try JSONDecoder().decode(VoiceMode.self, from: Data(json.utf8))
        #expect(mode.output == .paste)
    }

    @Test func modesRoundTripAndTolerateJunk() throws {
        let set = VoiceModeSet.defaults()
        let data = try JSONEncoder().encode(set)
        let back = try JSONDecoder().decode(VoiceModeSet.self, from: data)
        #expect(back == set)

        let json = #"""
        {"schemaVersion":1,"defaultModeID":"b","modes":[
          {"id":"a","name":"A","output":"teleport","bindings":[{"app":"com.x"},{"planet":"mars"},{"site":"x.com"}]},
          {"id":"b"},
          {"name":"no id"}
        ],"consents":{"https://api.openai.com:443":3}}
        """#
        let read = try JSONDecoder().decode(VoiceModeSet.self, from: Data(json.utf8))
        #expect(read.modes.map(\.id) == ["a", "b"])
        #expect(read.modes[0].output == .paste)
        #expect(read.modes[0].bindings == [.app("com.x"), .site("x.com")])
        #expect(read.modes[1].name == "b")
        #expect(read.defaultMode?.id == "b")
        #expect(read.consents["https://api.openai.com:443"] == [.audio, .text])
        // Presets are always there, for a file written before one was added.
        #expect(Set(read.endpoints.map(\.id)) == Set(VoiceEndpoint.Preset.allCases.map(\.rawValue)))
        #expect(read.newerSchemaVersion == nil)
    }

    @Test func aNewerFileOpensNoNetwork() throws {
        var set = VoiceModeSet.defaults()
        set.consent([.text], endpoint: "openai")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as! [String: Any]
        object["schemaVersion"] = 7
        let read = try JSONDecoder().decode(VoiceModeSet.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.newerSchemaVersion == 7)
        #expect(read.reachableOrigins(cloudDisabled: false).isEmpty)
    }

    @Test func builtInModes() {
        let set = VoiceModeSet.defaults()
        #expect(set.modes.map(\.id) == ["plain", "clean", "message", "mail", "terminal", "english"])
        #expect(set.defaultMode?.id == "plain")
        #expect(set.mode("plain")?.refine == nil)
        #expect(set.mode("terminal")?.refine == nil)
        #expect(set.mode("terminal")?.rules.singleLine == true)
        #expect(set.mode("terminal")?.allowsEnter == false)
        for id in ["clean", "message", "mail", "english"] {
            #expect(set.mode(id)?.refine?.endpoint == "ollama", "\(id)")
            #expect(set.mode(id)?.allowsEnter == false, "\(id)")
        }
        #expect(set.mode("message")?.bindings.contains(.app("ru.keepcoder.Telegram")) == true)
        #expect(set.mode("message")?.bindings.contains(.app("com.tinyspeck.slackmacgap")) == true)
        #expect(set.mode("message")?.bindings.contains(.app("net.whatsapp.WhatsApp")) == true)
        #expect(set.mode("mail")?.bindings.contains(.app("com.apple.mail")) == true)
        #expect(set.mode("mail")?.bindings.contains(.site("mail.google.com")) == true)
        #expect(set.mode("terminal")?.bindings.contains(.app("com.apple.Terminal")) == true)
        #expect(set.mode("terminal")?.bindings.contains(.app("com.jetbrains.")) == true)
        // Localized names and prompts come from the caller.
        let ru = VoiceModeSet.defaults { ($0 == .asSaid ? "Как сказал" : $0.englishName, $0.englishPrompt) }
        #expect(ru.mode("plain")?.name == "Как сказал")
    }

    @Test func whatAModeSends() {
        var mode = VoiceMode(id: "m", name: "M", model: "cloud:groq:whisper-large-v3-turbo",
                             refine: RefineConfig(endpoint: "openai", model: "gpt-4o-mini", prompt: "p"),
                             context: ModeContext(selection: true, app: true, site: false))
        #expect(mode.data(for: "groq") == [.audio])
        #expect(mode.data(for: "openai") == [.text, .selection, .app])
        #expect(mode.data(for: "ollama") == [])
        #expect(mode.endpoints == ["groq", "openai"])
        mode.model = "cloud:openai:gpt-4o-transcribe"
        #expect(mode.data(for: "openai") == [.audio, .text, .selection, .app])
        #expect(mode.endpoints == ["openai"])
    }

    @Test func consentCoversADataSetAndAskesAgainForMore() {
        var set = VoiceModeSet.defaults()
        var mode = VoiceMode(id: "m", name: "M", refine: RefineConfig(endpoint: "openai", model: "gpt-4o-mini", prompt: "p"))
        #expect(set.missingConsent(mode, endpoint: "openai") == [.text])
        set.consent([.text], endpoint: "openai")
        #expect(set.missingConsent(mode, endpoint: "openai") == [])
        // The mode now sends the app's name too: asked again, for that only.
        mode.context.app = true
        #expect(set.missingConsent(mode, endpoint: "openai") == [.app])
        // A server on this Mac needs none.
        let local = VoiceMode(id: "l", name: "L", refine: RefineConfig(endpoint: "ollama", model: "q", prompt: "p"),
                              context: ModeContext(selection: true, app: true, site: true))
        #expect(set.missingConsent(local, endpoint: "ollama") == [])
        // Consent follows the address, not the endpoint's id.
        set.endpoints[set.endpoints.firstIndex { $0.id == "openai" }!].address = "https://proxy.example.com/v1"
        #expect(set.missingConsent(mode, endpoint: "openai") == [.text, .app])
    }

    @Test func reachableOrigins() {
        var set = VoiceModeSet.defaults()
        #expect(set.reachableOrigins(cloudDisabled: false) == ["http://localhost:11434", "http://localhost:1234"])
        set.consent([.text], endpoint: "openai")
        #expect(set.reachableOrigins(cloudDisabled: false).contains("https://api.openai.com:443"))
        #expect(!set.reachableOrigins(cloudDisabled: false).contains("https://api.groq.com:443"))
        #expect(set.reachableOrigins(cloudDisabled: true) == ["http://localhost:11434", "http://localhost:1234"])
        // A server in the local network is not this Mac: consent first.
        set.addEndpoint(name: "Studio", address: "http://192.168.1.20:11434/v1")
        #expect(!set.reachableOrigins(cloudDisabled: false).contains("http://192.168.1.20:11434"))
    }

    @Test func bindingMovesBetweenModes() {
        var set = VoiceModeSet.defaults()
        set.bind(.app("ru.keepcoder.Telegram"), to: "mail")
        #expect(set.mode("message")?.bindings.contains(.app("ru.keepcoder.Telegram")) == false)
        #expect(set.mode("mail")?.bindings.contains(.app("ru.keepcoder.Telegram")) == true)
    }

    @Test func addingAndRemovingModes() {
        var set = VoiceModeSet.defaults()
        set.pinnedModeID = "clean"
        let added = set.addMode(name: "New")
        #expect(set.mode(added.id) != nil)
        set.removeMode("clean")
        #expect(set.pinnedModeID == nil)
        set.removeMode("plain")
        #expect(set.defaultModeID == set.modes[0].id)
    }

    @Test func cloudSpeechModelIDs() {
        #expect(CloudSpeechModel(id: "cloud:openai:gpt-4o-mini-transcribe") == CloudSpeechModel(endpoint: "openai", model: "gpt-4o-mini-transcribe"))
        #expect(CloudSpeechModel(id: "cloud:custom-1:org/model:v2")?.model == "org/model:v2")
        #expect(CloudSpeechModel(id: "parakeet-tdt-v3") == nil)
        #expect(CloudSpeechModel(id: "cloud::x") == nil)
        #expect(CloudSpeechModel.known.allSatisfy { CloudSpeechModel(id: $0.id) == $0 })
    }
}

struct ModeResolverTests {
    let set = VoiceModeSet.defaults()

    @Test func siteThenAppThenDefault() {
        // Gmail in Safari: the site's mode, not the browser's.
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "mail.google.com", in: set)?.mode.id == "mail")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "mail.google.com", in: set)?.reason
            == .site("mail.google.com"))
        #expect(ModeResolver.resolve(bundleID: "com.google.Chrome", host: "web.telegram.org", in: set)?.mode.id == "message")
        #expect(ModeResolver.resolve(bundleID: "ru.keepcoder.Telegram", host: nil, in: set)?.mode.id == "message")
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", host: nil, in: set)?.mode.id == "mail")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Terminal", host: nil, in: set)?.mode.id == "terminal")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "example.com", in: set)?.mode.id == "plain")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "example.com", in: set)?.reason == .fallback)
        #expect(ModeResolver.resolve(bundleID: nil, host: nil, in: set)?.mode.id == "plain")
    }

    @Test func aSiteCoversItsSubdomainsAndTheMostSpecificWins() {
        var set = self.set
        set.bind(.site("google.com"), to: "clean")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "docs.google.com", in: set)?.mode.id == "clean")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "mail.google.com", in: set)?.mode.id == "mail")
    }

    @Test func aSiteBindingWinsOverTheAppEvenWhenTheAppHasOne() {
        var set = self.set
        set.bind(.app("com.apple.Safari"), to: "english")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "app.slack.com", in: set)?.mode.id == "message")
        #expect(ModeResolver.resolve(bundleID: "com.apple.Safari", host: "example.com", in: set)?.mode.id == "english")
    }

    @Test func prefixesAndExactIDs() {
        var set = self.set
        #expect(ModeResolver.resolve(bundleID: "com.jetbrains.pycharm", host: nil, in: set)?.mode.id == "terminal")
        set.bind(.app("com.jetbrains.pycharm"), to: "english")
        #expect(ModeResolver.resolve(bundleID: "com.jetbrains.pycharm", host: nil, in: set)?.mode.id == "english")
        #expect(ModeResolver.resolve(bundleID: "com.jetbrains.goland", host: nil, in: set)?.mode.id == "terminal")
    }

    @Test func aPinnedModeHoldsEverywhere() {
        var set = self.set
        set.pinnedModeID = "english"
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", host: nil, in: set)?.mode.id == "english")
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", host: nil, in: set)?.reason == .pinned)
        set.pinnedModeID = "gone"
        #expect(ModeResolver.resolve(bundleID: "com.apple.mail", host: nil, in: set)?.mode.id == "mail")
    }

    @Test func theDefaultCanBeAnyMode() {
        var set = self.set
        set.defaultModeID = "clean"
        #expect(ModeResolver.resolve(bundleID: "com.apple.Notes", host: nil, in: set)?.mode.id == "clean")
    }

    @Test func terminalsTakeOneLine() {
        #expect(Terminals.contains("com.googlecode.iterm2"))
        #expect(!Terminals.contains("com.microsoft.VSCode"))
        #expect(Terminals.singleLine("git status\nrm -rf /") == "git status rm -rf /")
        #expect(Terminals.singleLine("a  \n\n  b\r\nc") == "a b c")
        #expect(Terminals.singleLine("\nls\n") == "ls")
    }
}

struct EndpointAddressTests {
    @Test func presetsParse() {
        for preset in VoiceEndpoint.Preset.allCases {
            #expect(EndpointAddress(preset.address) != nil, "\(preset)")
        }
        let openAI = EndpointAddress("https://api.openai.com/v1/")
        #expect(openAI?.origin == "https://api.openai.com:443")
        #expect(openAI?.url("/chat/completions") == "https://api.openai.com/v1/chat/completions")
        #expect(openAI?.reach == .internet)
        #expect(EndpointAddress("http://localhost:11434/v1")?.isOnThisMac == true)
        #expect(EndpointAddress("http://localhost:11434/v1")?.url("/x") == "http://localhost:11434/v1/x")
    }

    @Test func plainHTTPOnlyNearby() {
        #expect(EndpointAddress("http://api.openai.com/v1") == nil)
        #expect(EndpointAddress("http://127.0.0.1:1234/v1")?.reach == .loopback)
        #expect(EndpointAddress("http://[::1]:11434")?.reach == .loopback)
        #expect(EndpointAddress("http://[::1]:11434")?.origin == "http://::1:11434")
        #expect(EndpointAddress("http://[::1]:11434")?.url("/v1") == "http://[::1]:11434/v1")
        #expect(EndpointAddress("http://192.168.1.5:11434")?.reach == .localNetwork)
        #expect(EndpointAddress("http://10.0.0.2")?.reach == .localNetwork)
        #expect(EndpointAddress("http://172.20.1.1")?.reach == .localNetwork)
        #expect(EndpointAddress("http://172.32.1.1") == nil)
        #expect(EndpointAddress("http://studio.local:1234")?.reach == .localNetwork)
        #expect(EndpointAddress("http://8.8.8.8") == nil)
    }

    @Test func junkIsRefused() {
        for junk in ["", "api.openai.com", "ftp://x.com", "https://", "https://user:pw@x.com", "https://x.com/v1?key=1",
                     "https://x.com:0", "https://x.com:99999", "https://exa mple.com", "javascript:alert(1)",
                     "file:///etc/passwd", "https://x.com#frag"]
        {
            #expect(EndpointAddress(junk) == nil, "\(junk)")
        }
        #expect(EndpointAddress("  HTTPS://API.Groq.com:8443/openai/v1  ")?.origin == "https://api.groq.com:8443")
        #expect(EndpointAddress("https://api.groq.com:8443/openai/v1")?.displayHost == "api.groq.com:8443")
    }
}
