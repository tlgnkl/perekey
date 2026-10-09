// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import SwiftUI

/// Language names in the language of the app, not of the system region.
enum LanguageNames {
    private static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// "English", "русский": as the locale spells it, for use inside a sentence.
    static func name(of code: String) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }

    /// The same with a capital, for a title.
    static func title(of code: String) -> String {
        let name = name(of: code)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Which language pairs switch by itself and which only by hand, as statements.
/// Only for more than two languages; General and the onboarding show it.
struct LanguagePairsGroup: View {
    let pairs: LanguagePairs
    /// The keys of the retype shortcut, e.g. "⌥"; `nil` when it has none.
    var retypeKeys: String?

    var body: some View {
        PKGroup(header: Text("Your languages")) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { PKDivider() }
                PairRow(pair: row.pair, automatic: row.automatic)
            }
            PKNote(retypeText)
        }
    }

    private var rows: [(pair: LanguagePairs.Pair, automatic: Bool)] {
        pairs.automatic.map { ($0, true) } + pairs.manualOnly.map { ($0, false) }
    }

    private var retypeText: Text {
        if let retypeKeys {
            Text("\(retypeKeys) walks through the readings: press it again for the next layout, then back to what you typed.")
        } else {
            Text("The retype shortcut walks through the readings: press it again for the next layout, then back to what you typed.")
        }
    }
}

private struct PairRow: View {
    let pair: LanguagePairs.Pair
    let automatic: Bool

    var body: some View {
        let title = "\(LanguageNames.title(of: pair.first)) ↔ \(LanguageNames.name(of: pair.second))"
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: automatic ? "arrow.left.arrow.right" : "hand.point.up.left.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.pkIndigoInk)
                .frame(width: 28, height: 28)
                .background(Color.pkMist, in: RoundedRectangle(cornerRadius: 28 * 0.3, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(PK.Font.body).foregroundStyle(Color.pkInk)
                detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PKTag(text: automatic ? Text("Auto") : Text("By hand"))
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var detail: Text {
        automatic
            ? Text("Perekey switches by itself, and on your shortcut.")
            : Text("Only on your shortcut. The layouts differ in a few letters, so Perekey cannot tell a wrong layout from the other language.")
    }
}

/// The same statement in a few lines, for the welcome step, where a table does not fit.
struct LanguagePairsSummary: View {
    let pairs: LanguagePairs

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !pairs.automatic.isEmpty {
                Text("By itself: \(list(pairs.automatic)).")
            }
            if !pairs.manualOnly.isEmpty {
                Text("Only by hand: \(list(pairs.manualOnly)).")
            }
        }
        .font(PK.Font.caption)
        .foregroundStyle(Color.pkInk2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ pairs: [LanguagePairs.Pair]) -> String {
        pairs.map { "\(LanguageNames.name(of: $0.first)) ↔ \(LanguageNames.name(of: $0.second))" }.joined(separator: ", ")
    }
}
