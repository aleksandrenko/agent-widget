import SwiftUI

/// The month's score in the header: a row of tiny dots filled to the share of the target reached, the dots the pace
/// would add by the month end faint, then the percent. Hover shows the whole picture.
struct ScoreDots: View {
    var score: Snapshot.Score
    static let count = 14

    var body: some View {
        let reached = score.score / score.target
        let filled = min(Self.count, Int((reached * Double(Self.count)).rounded()))
        let ahead = min(Self.count, Int((score.forecast / score.target * Double(Self.count)).rounded()))
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<Self.count, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? score.tone : i < ahead ? score.tone.opacity(0.35) : Palette.ink.opacity(0.18))
                        .frame(width: 3, height: 3)
                }
            }
            Text("\(Int((reached * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink.opacity(0.75))
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                Tooltip.shared.show(content: ScoreCard(score: score))
            } else {
                Tooltip.shared.hide()
            }
        }
    }
}

extension Snapshot.Score {
    /// Green when the month end at this pace reaches the target, amber within 80% of it, red below.
    var tone: Color {
        forecast >= target ? Palette.hex(0x4ADE80) : forecast >= 0.8 * target ? Palette.hex(0xFBBF24) : Palette.hex(0xF87171)
    }
}

/// The hover card: the score and its share of the target, the score and work points bars (so far, and dashed to the
/// month end at this pace), what is left to do, then the counted, not counted and open work, and last month.
struct ScoreCard: View {
    var score: Snapshot.Score
    private let grey = Color(white: 0.68)
    private let amber = Palette.hex(0xE5A53A)
    private let blue = Palette.hex(0x4A8BE8)
    private let paleBlue = Palette.hex(0x3B68B5)
    private let mono = Font.system(size: 11, weight: .bold, design: .monospaced)

    /// Both bars share one scale, so the target ticks line up and the month end fits.
    private var scale: Double { max(1, pow(score.forecast / score.target, 2)) * 1.15 }
    private var forecastWork: Double { pow(score.forecast / 10, 2) }
    private var left: Double { score.days - score.elapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(f1(score.score)).font(.system(size: 30, weight: .bold, design: .monospaced))
                Text(pct(score.score, score.target))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(score.tone)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(score.tone.opacity(0.18)))
                Spacer(minLength: 8)
                Text(L("\(days(score.elapsed)) от \(days(score.days)) работни дни", "\(days(score.elapsed)) of \(days(score.days)) working days"))
                    .font(.system(size: 11)).foregroundStyle(grey)
            }
            meter(caption: L("ТОЧКИ · 10 × √ работни точки", "SCORE · 10 × √ work points"),
                  now: score.score, end: score.forecast, of: score.target, fill: blue, height: 9,
                  tick: L("цел \(Int(score.target))", "target \(Int(score.target))"))
            meter(caption: L("РАБОТНИ ТОЧКИ · свършената работа", "WORK POINTS · the work done"),
                  now: score.work, end: forecastWork, of: score.goal, fill: paleBlue, height: 7, tick: nil)
            VStack(spacing: 2) {
                ForEach(status, id: \.self) { Text($0) }
            }
            .font(.system(size: 11)).foregroundStyle(Color(white: 0.85))
            .frame(maxWidth: .infinity)
            HStack(spacing: 16) {
                HStack(spacing: 6) { Capsule().fill(blue).frame(width: 14, height: 5); Text(L("досега", "so far")) }
                HStack(spacing: 6) {
                    Rectangle().strokeBorder(amber, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])).frame(width: 14, height: 6)
                    Text(L("края на месеца с това темпо", "month end at this pace"))
                }
            }
            .font(.system(size: 10)).foregroundStyle(grey)
            Divider().overlay(Color.white.opacity(0.15))
            table
            if let last = score.last {
                Text(L("\(monthName(last.month)): \(f1(last.score)) точки · \(f1(last.work)) работни точки",
                       "\(monthName(last.month)): \(f1(last.score)) score · \(f1(last.work)) work points"))
                    .font(.system(size: 11)).foregroundStyle(grey)
            }
            if !score.jira {
                Text(L("⚠︎ Jira не отговори: всички тикети се броят за готови", "⚠︎ Jira did not answer: every named item counts as done"))
                    .font(.system(size: 10)).foregroundStyle(amber)
            }
            Text(updated).font(.system(size: 10)).foregroundStyle(score.error == nil ? grey : amber)
        }
        .padding(14)
        .frame(width: 380)
    }

    /// A caption, the numbers now and at the month end, then the bar with the target tick.
    private func meter(caption: String, now: Double, end: Double, of target: Double, fill: Color, height: CGFloat, tick: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption).font(.system(size: 10)).kerning(0.5).foregroundStyle(grey)
            HStack(spacing: 10) {
                Text(f1(now))
                Text(pct(now, target)).foregroundStyle(grey)
                Text(f1(end)).foregroundStyle(amber)
                Text(pct(end, target)).foregroundStyle(grey)
            }
            .font(mono)
            GeometryReader { geo in
                let width = geo.size.width
                let x = { (value: Double) in CGFloat(min(value / (target * scale), 1)) * width }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Rectangle().fill(amber.opacity(0.16))
                        .overlay(Rectangle().strokeBorder(amber, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
                        .frame(width: max(x(end) - x(now), 0))
                        .offset(x: x(now))
                    Capsule().fill(fill).frame(width: x(now))
                    Rectangle().fill(Color(white: 0.94)).frame(width: 2, height: height + 8).offset(x: width / scale - 1)
                }
            }
            .frame(height: height)
            if let tick {
                GeometryReader { geo in
                    Text(tick).font(.system(size: 10, design: .monospaced)).foregroundStyle(grey).fixedSize()
                        .position(x: geo.size.width / scale, y: 6)
                }
                .frame(height: 12)
            }
        }
    }

    /// What is left: past the target, or how many work points it still needs and the pace that would close the gap.
    private var status: [String] {
        let gap = score.goal - score.work
        if gap <= 0 {
            return [L("+\(f1(-gap)) работни точки над целта от \(f0(score.goal))", "+\(f1(-gap)) work points past the \(f0(score.goal)) target"),
                    L("\(f1(score.forecast)) точки в края на месеца с това темпо", "\(f1(score.forecast)) score at the month end at this pace")]
        }
        let first = L("още \(f1(gap)) работни точки до целта от \(f0(score.goal))", "\(f1(gap)) more work points to the \(f0(score.goal)) target")
        guard left > 0 else { return [first, L("няма останали работни дни", "0 working days left")] }
        guard score.elapsed > 0 else { return [first, L("\(days(left)) работни дни остават", "\(days(left)) working days left")] }
        let pace = gap / left / max(score.work, 0.1) * score.elapsed
        return [first, L("\(f1(pace))× темпото досега, за оставащите \(days(left)) работни дни",
                         "\(f1(pace))× the pace so far, on the \(days(left)) working days left")]
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            heading(L("ГОТОВО", "DONE"))
            row(score.merged.count, L("PR-а", "PRs"), L("Merged", "Merged"), score.merged.points)
            row(score.bonus.count, L("тикета", "items"), L("Бонус за няколко repo-та", "Bonus for several repos"), score.bonus.points)
            heading(L("НЕ СЕ БРОИ", "NOT COUNTED"))
            ForEach(score.lost, id: \.id) { lost in
                row(lost.count, L("PR-а", "PRs"), lostName(lost.id), lost.points)
            }
            heading(L("ОТВОРЕНИ", "OPEN"))
            row(score.open.count, L("PR-а", "PRs"), L("Ако се merge-нат", "Open, if they merge"), score.open.points)
        }
    }

    private func heading(_ text: String) -> some View {
        GridRow {
            Text(text).font(.system(size: 10)).kerning(0.5).foregroundStyle(grey).padding(.top, 4).gridCellColumns(3)
        }
    }

    private func row(_ count: Int, _ unit: String, _ label: String, _ points: Double) -> some View {
        GridRow {
            Text("\(count) \(unit)")
            Text(label)
            Text(points > 0 ? "+\(f1(points))" : "–").gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .opacity(count == 0 ? 0.45 : 1)
    }

    private func lostName(_ id: String) -> String {
        switch id {
        case "jira": L("Jira тикетът още не е готов", "Jira item not done yet")
        case "cap": L("Редове над тавана от 2,000", "Lines over the 2,000 cap")
        default: L("Няма Jira ключ в заглавието", "No Jira key in the title")
        }
    }

    private var updated: String {
        let time = Date(timeIntervalSince1970: score.at).formatted(date: .omitted, time: .shortened)
        return score.error == nil ? L("обновено в \(time) · на всеки 30 мин", "updated \(time) · every 30 min")
            : L("⚠︎ последното обновяване не успя; числата са от \(time)", "⚠︎ the last update failed; numbers from \(time)")
    }

    private func monthName(_ month: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM"
        guard let date = parse.date(from: month) else { return month }
        let show = DateFormatter()
        show.locale = Locale(identifier: Lang.current == .bg ? "bg_BG" : "en_US")
        show.dateFormat = "LLLL"
        return show.string(from: date).capitalized
    }

    private func f1(_ value: Double) -> String { String(format: "%.1f", value) }
    private func f0(_ value: Double) -> String { String(format: "%.0f", value) }
    private func pct(_ value: Double, _ of: Double) -> String { "\(Int((value / of * 100).rounded()))%" }
    private func days(_ value: Double) -> String { value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value) }
}
