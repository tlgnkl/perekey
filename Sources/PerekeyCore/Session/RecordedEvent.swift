// SPDX-License-Identifier: GPL-3.0-or-later

/// The classifier a session ran with: the languages of its model and its
/// options. A replay loads the model of those languages from a directory
/// (`perekey-eval replay --model`); the model itself is not recorded.
public struct ClassifierSpec: Hashable, Sendable, Codable {
    /// The codes of the model's languages, in its order.
    public var languages: [String]
    public var options: Classifier.Options

    public init(languages: [String], options: Classifier.Options) {
        self.languages = languages
        self.options = options
    }

    public init(_ classifier: Classifier) {
        self.init(languages: classifier.model.languages.map(\.code), options: classifier.options)
    }
}

/// An `InputEvent` as a session file keeps it (docs/classifier.md, «Замер
/// на живых сессиях»). A type of its own, so the file has a version apart
/// from the machine's events, and so two cases can differ:
/// - `.classifierChanged` carries a memory-mapped model: recorded as its
///   languages and options (`.classifier`), or `.noClassifier`;
/// - `.selectionRead` carries the selected text of someone's document: it is
///   recorded as as many "x" as it has characters (`Character`, the unit
///   `SelectionConversion` counts and iterates in, not scalars or UTF-16).
///
/// Every other case is recorded as it is. `init(_:)` switches over every
/// case without `default`: an event added to `InputEvent` does not compile
/// until it is recorded here.
public enum RecordedEvent: Hashable, Sendable, Codable {
    case key(KeyEvent, time: Double)
    case flagsChanged(keyCode: UInt16, flags: UInt64, origin: EventOrigin, time: Double, location: PointerLocation?)
    case click(time: Double, onHint: Bool)
    case scroll(time: Double)
    case focusChanged(Focus, FocusChange)
    case layoutChanged(LayoutID)
    case layoutsChanged([LayoutMap])
    case secureInputChanged(Bool)
    case settingsChanged(Settings)
    case retypePosted(seq: UInt32, time: Double)
    case retypeCancelled(seq: UInt32)
    /// `text` is "x" as many times as the selection had `Character`s.
    case selectionRead(seq: UInt32, text: String, viaAccessibility: Bool)
    case inputLost
    case dictationTyping(Bool)
    case deadline(time: Double)
    case appModeChanged(AppMode)
    case classifier(ClassifierSpec)
    case noClassifier
    case undoLastCorrection(seq: UInt32, time: Double)
    case languageContextChanged(LanguageContext)
    case personalLexiconChanged(PersonalLexicon)
    case voiceHoldLost
    case voiceSession(Bool)

    public init(_ event: InputEvent) {
        switch event {
        case let .key(key, time): self = .key(key, time: time)
        case let .flagsChanged(keyCode, flags, origin, time, location):
            self = .flagsChanged(keyCode: keyCode, flags: flags, origin: origin, time: time, location: location)
        case let .click(time, onHint): self = .click(time: time, onHint: onHint)
        case let .scroll(time): self = .scroll(time: time)
        case let .focusChanged(focus, change): self = .focusChanged(focus, change)
        case let .layoutChanged(id): self = .layoutChanged(id)
        case let .layoutsChanged(maps): self = .layoutsChanged(maps)
        case let .secureInputChanged(on): self = .secureInputChanged(on)
        case let .settingsChanged(settings): self = .settingsChanged(settings)
        case let .retypePosted(seq, time): self = .retypePosted(seq: seq, time: time)
        case let .retypeCancelled(seq): self = .retypeCancelled(seq: seq)
        case let .selectionRead(seq, text, viaAccessibility):
            self = .selectionRead(seq: seq, text: String(repeating: "x", count: text.count),
                                  viaAccessibility: viaAccessibility)
        case .inputLost: self = .inputLost
        case let .dictationTyping(on): self = .dictationTyping(on)
        case let .deadline(time): self = .deadline(time: time)
        case let .appModeChanged(mode): self = .appModeChanged(mode)
        case let .classifierChanged(classifier): self = classifier.map { .classifier(ClassifierSpec($0)) } ?? .noClassifier
        case let .undoLastCorrection(seq, time): self = .undoLastCorrection(seq: seq, time: time)
        case let .languageContextChanged(context): self = .languageContextChanged(context)
        case let .personalLexiconChanged(lexicon): self = .personalLexiconChanged(lexicon)
        case .voiceHoldLost: self = .voiceHoldLost
        case let .voiceSession(on): self = .voiceSession(on)
        }
    }

    /// The event to hand to a machine. `classifier` makes the classifier of
    /// a `.classifier` event; nil from it means none.
    public func inputEvent(classifier: (ClassifierSpec) -> Classifier?) -> InputEvent {
        switch self {
        case let .key(key, time): .key(key, time: time)
        case let .flagsChanged(keyCode, flags, origin, time, location):
            .flagsChanged(keyCode: keyCode, flags: flags, origin: origin, time: time, location: location)
        case let .click(time, onHint): .click(time: time, onHint: onHint)
        case let .scroll(time): .scroll(time: time)
        case let .focusChanged(focus, change): .focusChanged(focus, change)
        case let .layoutChanged(id): .layoutChanged(id)
        case let .layoutsChanged(maps): .layoutsChanged(maps)
        case let .secureInputChanged(on): .secureInputChanged(on)
        case let .settingsChanged(settings): .settingsChanged(settings)
        case let .retypePosted(seq, time): .retypePosted(seq: seq, time: time)
        case let .retypeCancelled(seq): .retypeCancelled(seq: seq)
        case let .selectionRead(seq, text, viaAccessibility):
            .selectionRead(seq: seq, text: text, viaAccessibility: viaAccessibility)
        case .inputLost: .inputLost
        case let .dictationTyping(on): .dictationTyping(on)
        case let .deadline(time): .deadline(time: time)
        case let .appModeChanged(mode): .appModeChanged(mode)
        case let .classifier(spec): .classifierChanged(classifier(spec))
        case .noClassifier: .classifierChanged(nil)
        case let .undoLastCorrection(seq, time): .undoLastCorrection(seq: seq, time: time)
        case let .languageContextChanged(context): .languageContextChanged(context)
        case let .personalLexiconChanged(lexicon): .personalLexiconChanged(lexicon)
        case .voiceHoldLost: .voiceHoldLost
        case let .voiceSession(on): .voiceSession(on)
        }
    }

    /// When the event reached the tap, for the events that carry it.
    public var time: Double? {
        switch self {
        case let .key(_, time), let .flagsChanged(_, _, _, time, _), let .click(time, _), let .scroll(time),
             let .retypePosted(_, time), let .deadline(time), let .undoLastCorrection(_, time):
            time
        default:
            nil
        }
    }
}
