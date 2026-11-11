// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A table of the report: a title, columns, rows of text. The first column is text; the rest are numbers.
struct ReportTable {
    var title: String?
    var columns: [String]
    var rows: [[String]]
    /// Drawn closed in HTML, behind its title.
    var collapsed = false
    /// Columns that hold text, not numbers (the first always does).
    var textColumns: Set<Int> = [0]
}

enum ReportBlock {
    case line(String)
    case table(ReportTable)
}

/// The number formats: a decimal comma, a no-break space between thousands (plan, 11.3).
enum Fmt {
    static func int(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, digit) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append("\u{00A0}") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }

    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// A value to the scale (‰ or %), with as many digits as keep two significant ones.
    static func scaled(_ value: Double?, scale: Double) -> String {
        guard let value else { return "—" }
        let shown = value * scale
        return number(shown, digits: shown == 0 ? 1 : abs(shown) >= 100 ? 0 : abs(shown) >= 10 ? 1 : 2)
    }

    /// «0,31 (0,22–0,43)»; with no event «0 (≤ 0,21)», the rule of three.
    static func estimate(_ estimate: Estimate, scale: Double) -> String {
        guard let value = estimate.value else { return "—" }
        if estimate.events == 0, let upper = estimate.upperIfNone { return "0 (≤ \(scaled(upper, scale: scale)))" }
        guard let low = estimate.low, let high = estimate.high else { return scaled(value, scale: scale) }
        return "\(scaled(value, scale: scale)) (\(scaled(low, scale: scale))–\(scaled(high, scale: scale)))"
    }

    static func share(_ events: Int, of count: Int, scale: Double = 1000) -> String {
        count > 0 ? scaled(Double(events) / Double(count), scale: scale) : "—"
    }
}

enum ReportRender {
    static func title(_ data: ReportData) -> String {
        let models = data.models.keys.sorted().map { "\($0) \(data.models[$0]!.prefix(4))…" }.joined(separator: ", ")
        var parts = ["Perekey Eval — \(data.system), \(data.commit)"]
        if !models.isEmpty { parts.append("модели \(models)") }
        if let tier = data.tier { parts.append("уровень \(tier)") }
        parts.append("эпоха " + data.epochs.map(String.init).joined(separator: ","))
        if let settings = data.settings { parts.append("настройки \(settings)") }
        if let options = data.options { parts.append("--options \(options)") }
        parts.append("счётчик \(data.scorer)")
        if data.testRevealed { parts.append("ТЕСТ РАСКРЫТ") }
        return parts.joined(separator: ", ")
    }

    static func blocks(_ data: ReportData, text: Bool) -> [ReportBlock] {
        var blocks: [ReportBlock] = []
        if !data.profiles.isEmpty {
            blocks.append(.table(ReportTable(
                title: "Профили",
                columns: ["Профиль", "Вред ‰ (95 %)", "Остаток ‰ (95 %)", "Без Perekey ‰", "Тихий ‰", "Чисто %"],
                rows: data.profiles.map { row in
                    [row.name, Fmt.estimate(row.harm, scale: 1000), Fmt.estimate(row.rest, scale: 1000),
                     Fmt.scaled(row.restNull.value, scale: 1000), Fmt.scaled(row.silent.value, scale: 1000),
                     Fmt.scaled(row.exact.value, scale: 100)]
                })))
            for row in data.profiles { if let caveat = row.caveat { blocks.append(.line("ВНИМАНИЕ, профиль \(row.name): \(caveat)")) } }
        }
        func measure(_ group: GroupRow, _ measure: Measure, interval: Bool = false) -> String {
            guard let estimate = group.estimates[measure.rawValue] else { return "—" }
            return interval ? Fmt.estimate(estimate, scale: measure.scale)
                : Fmt.scaled(estimate.value, scale: measure.scale)
        }
        func groupRow(_ group: GroupRow) -> [String] {
            [group.suite, group.scenario, Fmt.int(group.words), measure(group, .harm, interval: true),
             Fmt.int(group.harmEvents), measure(group, .missLayout), measure(group, .botched), measure(group, .silent),
             measure(group, .disputed), measure(group, .rest), measure(group, .restNull), measure(group, .exact),
             group.lag.map { Fmt.number($0, digits: 1) } ?? "—"]
        }
        blocks.append(.table(ReportTable(
            title: "Набор × сценарий",
            columns: ["Набор", "Сценарий", "Слова", "В ‰ (95 %)", "Событий вреда", "П ‰", "Пч ‰", "Т ‰", "Спорно ‰",
                      "О ‰", "О₀ ‰", "Чисто %", "Запазд."],
            rows: (data.groups + [data.total]).map(groupRow), textColumns: [0, 1])))
        let weighted = data.groups.filter { $0.harmWeighted != nil || $0.missLayoutWeighted != nil }
        if !weighted.isEmpty {
            blocks.append(.table(ReportTable(
                title: "С весом токена (наборы классов)",
                columns: ["Набор", "Сценарий", "В ‰ с весом", "П ‰ с весом"],
                rows: weighted.map { [$0.suite, $0.scenario, Fmt.scaled($0.harmWeighted, scale: 1000),
                                      Fmt.scaled($0.missLayoutWeighted, scale: 1000)] },
                textColumns: [0, 1])))
        }
        if !data.worst.isEmpty {
            blocks.append(.table(ReportTable(
                title: "Худшие срезы (лишние ошибки)",
                columns: ["Срез", "Слова", "Ошибок ‰", "В ‰", "П ‰", "Лишних"],
                rows: data.worst.map { line in
                    [line.name, Fmt.int(line.counters.words), Fmt.scaled(line.wrongShare, scale: 1000),
                     Fmt.scaled(line.harmShare, scale: 1000), Fmt.scaled(line.missLayoutShare, scale: 1000),
                     "+" + Fmt.int(Int(line.extra.rounded()))]
                })))
        }
        if !data.words.isEmpty {
            blocks.append(.table(ReportTable(
                title: data.testRevealed ? "Слова (dev и test), вес × ошибки" : "Слова (dev), вес × ошибки",
                columns: ["Слово", "Вхождений", "Вред", "Пропуск", "Порча", "Вес ошибок"],
                rows: data.words.map { word in
                    [word.word, Fmt.int(word.occurrences), Fmt.int(word.harm), Fmt.int(word.miss), Fmt.int(word.botched),
                     Fmt.number(word.weight, digits: word.weight == word.weight.rounded() ? 0 : 1)]
                })))
        }
        if !data.seen.isEmpty {
            blocks.append(.table(ReportTable(
                title: "Слова из списков data/ (seen) и остальные",
                columns: ["seen", "Слова", "В ‰", "П ‰", "Починено", "Спорно"],
                rows: data.seen.keys.sorted().map { key in
                    let c = data.seen[key]!
                    return [key, Fmt.int(c.words), Fmt.share(c.harm, of: c.words), Fmt.share(c.missLayout, of: c.layoutErrors),
                            Fmt.int(c.fixed), Fmt.int(c.disputed)]
                })))
        }
        if !data.reasons.isEmpty || !data.margins.isEmpty {
            var rows: [[String]] = []
            for (kind, table) in [("причина", data.reasons), ("запас до порога", data.margins)] {
                for key in table.keys.sorted() {
                    let c = table[key]!
                    rows.append(["\(kind): \(key)", Fmt.int(c.words), Fmt.int(c.miss), Fmt.int(c.harm), Fmt.int(c.botched)])
                }
            }
            blocks.append(.table(ReportTable(title: "Причина и запас до порога (по следу)",
                                             columns: ["Срез", "Слова", "Пропуски", "Вреды", "Порчи"], rows: rows)))
        }
        for feature in data.features {
            blocks.append(.table(ReportTable(
                title: "Признак \(feature.feature)",
                columns: ["Значение", "Слова", "Ошибок ‰ (95 %)", "В ‰ (95 %)", "П ‰", "Починено"],
                rows: feature.lines.map { line in
                    let c = line.counters
                    func interval(_ value: Stats.Interval?, _ events: Int) -> String {
                        guard let value, c.words > 0 else { return "—" }
                        return events == 0 ? "0 (≤ \(Fmt.scaled(Stats.ruleOfThree(of: c.words), scale: 1000)))"
                            : "\(Fmt.share(events, of: c.words)) (\(Fmt.scaled(value.low, scale: 1000))–\(Fmt.scaled(value.high, scale: 1000)))"
                    }
                    return [line.value, Fmt.int(c.words), interval(line.wrong, c.wrong), interval(line.harm, c.harm),
                            Fmt.share(c.missLayout, of: c.layoutErrors), Fmt.int(c.fixed)]
                },
                collapsed: true)))
        }
        var lines: [String] = []
        let incidents = data.incidents
        if incidents.fixed + incidents.open > 0 {
            var line = "Сбои: исправлено \(incidents.fixedPassing) из \(incidents.fixed); ждут починки \(incidents.open)"
            if incidents.openPassing > 0 { line += "; из них проходят и ждут смены статуса: \(incidents.openPassing)" }
            lines.append(line + ".")
        }
        if let protective = data.protective {
            lines.append("Защитные наборы: вред \(protective.events) из \(Fmt.int(protective.of))"
                + (protective.events == 0 ? ", верхняя граница \(Fmt.scaled(protective.upperIfNone, scale: 1000)) ‰." : "."))
        }
        for note in data.notes { lines.append("Примечание: \(note).") }
        blocks += lines.map { .line($0) }
        return blocks
    }

    // MARK: - Formats

    static func text(_ data: ReportData) -> String {
        var out = title(data) + "\n"
        for block in blocks(data, text: true) {
            switch block {
            case let .line(line): out += "\n" + line
            case let .table(table):
                out += "\n\n" + (table.title.map { $0 + "\n" } ?? "") + aligned(table)
            }
        }
        return out + "\n"
    }

    private static func aligned(_ table: ReportTable) -> String {
        let widths = table.columns.indices.map { column in
            ([table.columns[column]] + table.rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: max(0, widths[column] - cell.count))
                return table.textColumns.contains(column) ? cell + pad : pad + cell
            }.joined(separator: "  ")
        }
        return ([line(table.columns)] + table.rows.map(line)).joined(separator: "\n")
    }

    static func markdown(_ data: ReportData) -> String {
        var out = "# " + title(data) + "\n"
        for block in blocks(data, text: false) {
            switch block {
            case let .line(line): out += "\n" + line + "\n"
            case let .table(table):
                out += "\n## " + (table.title ?? "") + "\n\n"
                out += "| " + table.columns.joined(separator: " | ") + " |\n"
                out += "|" + table.columns.indices.map { table.textColumns.contains($0) ? "---" : "---:" }.joined(separator: "|") + "|\n"
                for row in table.rows { out += "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |\n" }
            }
        }
        return out
    }

    static func html(_ data: ReportData) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = "<h1>\(escape(title(data)))</h1>\n"
        for block in blocks(data, text: false) {
            switch block {
            case let .line(line): body += "<p>\(escape(line))</p>\n"
            case let .table(table):
                var markup = "<table class=\"sortable\">\n<thead><tr>"
                markup += table.columns.enumerated().map { column, name in
                    "<th\(table.textColumns.contains(column) ? " class=\"text\"" : "")>\(escape(name))</th>"
                }.joined()
                markup += "</tr></thead>\n<tbody>\n"
                for row in table.rows {
                    markup += "<tr>" + row.enumerated().map { column, cell in
                        "<td\(table.textColumns.contains(column) ? " class=\"text\"" : "")>\(escape(cell))</td>"
                    }.joined() + "</tr>\n"
                }
                markup += "</tbody></table>\n"
                let heading = escape(table.title ?? "")
                body += table.collapsed ? "<details><summary>\(heading)</summary>\n\(markup)</details>\n"
                    : "<h2>\(heading)</h2>\n\(markup)"
            }
        }
        return """
        <!DOCTYPE html>
        <html lang="ru"><head><meta charset="utf-8"><title>\(escape(title(data)))</title>
        <style>
        body{font:14px/1.45 -apple-system,system-ui,sans-serif;margin:24px;color:#1d1d1f;max-width:1200px}
        h1{font-size:18px}h2{font-size:15px;margin:28px 0 6px}
        table{border-collapse:collapse;margin:4px 0 12px;font-variant-numeric:tabular-nums}
        th,td{padding:3px 10px;border-bottom:1px solid #e3e3e6;text-align:right;white-space:nowrap}
        th{background:#f5f5f7;cursor:pointer;user-select:none;position:sticky;top:0}
        th.text,td.text{text-align:left}
        th.asc::after{content:" ▲"}th.desc::after{content:" ▼"}
        details{margin:8px 0}summary{cursor:pointer;font-weight:600}
        @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f2f2f7}th{background:#2c2c2e}th,td{border-color:#3a3a3c}}
        </style></head><body>
        \(body)<script>
        document.querySelectorAll("table.sortable").forEach(function(table){
          table.querySelectorAll("th").forEach(function(th,column){
            th.addEventListener("click",function(){
              var rows=Array.from(table.tBodies[0].rows),up=!th.classList.contains("asc");
              function key(row){var t=row.cells[column].textContent.replace(/[\\u00a0 ]/g,"").replace(",",".");
                var n=parseFloat(t.replace(/^\\+/,""));return isNaN(n)?t:n}
              rows.sort(function(a,b){var x=key(a),y=key(b);
                return (x<y?-1:x>y?1:0)*(up?1:-1)});
              table.querySelectorAll("th").forEach(function(h){h.classList.remove("asc","desc")});
              th.classList.add(up?"asc":"desc");
              rows.forEach(function(row){table.tBodies[0].appendChild(row)});
            });
          });
        });
        </script></body></html>

        """
    }

    static func json(_ data: ReportData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(data), as: UTF8.self) + "\n"
    }
}
