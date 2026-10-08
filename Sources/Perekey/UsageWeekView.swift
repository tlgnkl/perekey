// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import SwiftUI

/// The last 7 days as quiet bars, with the week's total, undone count and share.
/// Plain shapes: no chart library, no animation, nothing that runs while idle.
struct UsageWeekView: View {
    let stats: UsageStats
    var now = Date()
    var calendar = Calendar.current

    private static let barHeight: CGFloat = 54

    var body: some View {
        let week = stats.recent(7, endingAt: now, calendar: calendar)
        let totals = UsageStats.totals(week)
        let peak = max(1, week.map(\.correctionTotal).max() ?? 1)
        let share = totals.corrections == 0 ? 0 : Int((Double(totals.undone) / Double(totals.corrections) * 100).rounded())
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days")
                .font(PK.Font.captionStrong)
                .foregroundStyle(Color.pkInk2)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                    bar(day, peak: peak, isToday: index == week.count - 1, date: date(daysBack: week.count - 1 - index))
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 24) {
                figure(Text("Corrections"), "\(totals.corrections)")
                figure(Text("Undone"), "\(totals.undone)")
                figure(Text("Undone share"), "\(share) %")
                Spacer(minLength: 0)
            }
        }
        .padding(PK.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func date(daysBack: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
    }

    private func bar(_ day: UsageStats.Day, peak: Int, isToday: Bool, date: Date) -> some View {
        let total = day.correctionTotal
        let height = total == 0 ? 3 : max(6, Self.barHeight * CGFloat(total) / CGFloat(peak))
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return VStack(spacing: 5) {
            Text(verbatim: "\(total)")
                .font(PK.Font.tag)
                .foregroundStyle(total == 0 ? Color.pkInk3 : Color.pkInk2)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.pkWash)
                    .frame(height: Self.barHeight)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isToday ? Color.pkIndigoFill : Color.pkIndigo.opacity(0.45))
                    .frame(height: height)
            }
            .frame(height: Self.barHeight)
            Text(verbatim: weekday)
                .font(PK.Font.tag)
                .foregroundStyle(isToday ? Color.pkInk : Color.pkInk3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(weekday), \(total)"))
    }

    private func figure(_ title: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value).font(PK.Font.headline).foregroundStyle(Color.pkInk)
            title.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
        }
    }
}
