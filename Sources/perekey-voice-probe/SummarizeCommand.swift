// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoice
import PerekeyVoiceCore

/// `summarize <transcript.json | --fake minutes> <address | fake> <model> [--minutes] [--out file]`:
/// the app's «Конспект» or «Протокол встречи» on a transcript, through a
/// server of the modes (Ollama: http://localhost:11434/v1) or a fake model
/// that answers at once. Prints time, memory and the requests as JSON; the
/// answer goes only to `--out`. A cloud address takes its key from
/// `PEREKEY_PROBE_KEY`.
enum SummarizeCommand {
    static func run(_ arguments: [String]) async throws {
        var rest = arguments
        let action: TranscriptAction = take("--minutes", from: &rest) ? .minutes : .summary
        let output = value("--out", from: &rest)
        let fakeMinutes = value("--fake", from: &rest).flatMap(Double.init)
        guard rest.count == (fakeMinutes == nil ? 3 : 2) else {
            throw ProbeError.message("usage: summarize <transcript.json | --fake minutes> <address | fake> <model> [--minutes] [--out file]")
        }
        let document = try fakeMinutes.map(fakeTranscript) ?? loadTranscript(rest.removeFirst())
        let (server, model) = (rest[0], rest[1])

        let counter = Counter()
        let engine: any SummaryLanguageModel
        let budget: SummaryBudget
        if server == "fake" {
            engine = InstantModel(counter: counter)
            budget = .local
        } else {
            guard let address = EndpointAddress(server) else { throw ProbeError.message("bad address \(server)") }
            let http = VoiceHTTP(allowed: [.conversationLanguageModel])
            http.allowedOrigins = [.conversationLanguageModel: [address.origin]]
            let summary = SummaryServer(model: model, address: address,
                                        key: ProcessInfo.processInfo.environment["PEREKEY_PROBE_KEY"], http: http)
            engine = CountingModel(inner: summary, counter: counter)
            budget = summary.budget
        }
        let lines = TranscriptLines.of(document, labels: .english)
        let chunks = TranscriptChunker.chunks(lines, limit: budget.characters)
        let meter = RunMeter()
        let answer = try await TranscriptSummarizer(model: engine, budget: budget)
            .run(action, lines: lines, language: document.language)
        let report = meter.stop()
        if let output { try Data(answer.utf8).write(to: URL(fileURLWithPath: output)) }
        var json = report.json
        json["action"] = action.rawValue
        json["phrases"] = lines.count
        json["characters"] = lines.reduce(0) { $0 + $1.count }
        json["budget_characters"] = budget.characters
        json["pieces"] = chunks.count
        json["requests"] = counter.value
        json["request_s"] = counter.seconds
        json["answer_characters"] = answer.count
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func take(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func value(_ flag: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func loadTranscript(_ path: String) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// A planning meeting of `minutes`: four speakers, about 150 words a minute, in Russian.
    static func fakeTranscript(minutes: Double) -> TranscriptDocument {
        let phrases = [
            "Давайте пройдёмся по статусу релиза, что у нас с тестами на этой неделе.",
            "Тесты на оплату зелёные, но интеграция с банком падает примерно раз в десять прогонов.",
            "Я бы не выкатывал, пока не поймём, почему падает, это похоже на гонку в очереди.",
            "Хорошо, тогда решаем так: релиз переносим на четверг, а Аня смотрит очередь до среды.",
            "Ещё вопрос по дизайну экрана настроек, макеты готовы, но нет текстов на английском.",
            "Тексты я напишу до пятницы, если кто-то проверит русскую версию после меня.",
            "Проверю я, мне удобно в понедельник утром, раньше не получится из-за конференции.",
            "Отдельно надо решить, кто дежурит в выходные после релиза, в прошлый раз было тяжело.",
            "Предлагаю дежурить по очереди по полдня, и записать это в календарь команды сегодня.",
            "По метрикам: время ответа выросло на двадцать процентов после последнего обновления.",
            "Это из-за нового индекса, его можно перестроить ночью, на пользователях не скажется.",
            "Тогда перестройку индекса ставим на ночь со среды на четверг, до выкатки.",
        ]
        let count = Int(minutes * 12)
        let segments = (0..<count).map { index in
            let start = Double(index) * 5
            return TimedSegment(start: start, end: start + 4.8, text: phrases[(index * 7) % phrases.count],
                                speaker: "speaker-\(index % 4 + 1)")
        }
        return TranscriptDocument(model: "fake", engine: "fake", language: "ru", segments: segments)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var total = 0.0
        var value: Int { lock.withLock { count } }
        var seconds: Double { lock.withLock { total } }
        func add(_ seconds: Double) { lock.withLock { count += 1; total += seconds } }
    }

    /// Short notes at once: the cost of the cutting and the bookkeeping alone.
    struct InstantModel: SummaryLanguageModel {
        let counter: Counter
        func complete(_ messages: [ChatMessage]) async throws -> String {
            counter.add(0)
            return "- Релиз переносится на четверг.\n- Аня смотрит очередь до среды.\n- Тексты до пятницы."
        }
    }

    struct CountingModel: SummaryLanguageModel {
        let inner: any SummaryLanguageModel
        let counter: Counter
        func complete(_ messages: [ChatMessage]) async throws -> String {
            let start = ContinuousClock.now
            defer {
                let elapsed = start.duration(to: .now).components
                counter.add(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
            return try await inner.complete(messages)
        }
    }
}
