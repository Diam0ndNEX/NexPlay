import SwiftUI

/// Play stats: total time, most played games, time per engine and the games by status.
struct StatsView: View {
    @EnvironmentObject private var store: LibraryStore

    private var games: [Game] { store.games }
    private var totalSeconds: Double { games.reduce(0) { $0 + $1.playSeconds } }
    private var sessions: Int { games.reduce(0) { $0 + $1.playCount } }

    private var mostPlayed: [Game] {
        Array(games.filter { $0.playSeconds >= 60 }.sorted { $0.playSeconds > $1.playSeconds }.prefix(8))
    }

    private struct EngineTime: Identifiable {
        let engine: GameEngine
        let seconds: Double
        let count: Int
        var id: String { engine.rawValue }
    }

    private var byEngine: [EngineTime] {
        var seconds: [GameEngine: Double] = [:]
        var counts: [GameEngine: Int] = [:]
        for game in games {
            seconds[game.engine, default: 0] += game.playSeconds
            counts[game.engine, default: 0] += 1
        }
        return counts.keys.map { EngineTime(engine: $0, seconds: seconds[$0] ?? 0, count: counts[$0] ?? 0) }
            .sorted { $0.seconds == $1.seconds ? $0.count > $1.count : $0.seconds > $1.seconds }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    tile(formatHours(totalSeconds), "Played", "clock.fill", .purple)
                    tile("\(games.count)", "Games", "square.stack.fill", .blue)
                    tile("\(sessions)", "Sessions", "play.fill", .green)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
            }

            if !mostPlayed.isEmpty {
                Section("Most Played") {
                    let top = mostPlayed.first?.playSeconds ?? 1
                    ForEach(mostPlayed) { game in
                        HStack(spacing: 12) {
                            CoverView(game: game).frame(width: 40)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(game.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text(formatDuration(game.playSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                bar(game.playSeconds / max(top, 1), color: game.tagColor ?? NexStyle.accent)
                            }
                        }
                    }
                }
            }

            if !byEngine.isEmpty {
                Section("By Engine") {
                    let top = max(byEngine.map { $0.seconds }.max() ?? 1, 1)
                    ForEach(byEngine) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.engine.symbol)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.engine.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text("\(item.count) · \(formatHours(item.seconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                bar(item.seconds / top, color: .indigo)
                            }
                        }
                    }
                }
            }

            Section("By Status") {
                ForEach(GameStatus.allCases) { status in
                    let count = games.filter { $0.playStatus == status }.count
                    HStack {
                        Label(status.title, systemImage: status.symbol).foregroundStyle(status.color)
                        Spacer()
                        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Play Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ value: String, _ title: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.headline).foregroundStyle(color)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// "12h 30m", "45m", or "0m".
func formatHours(_ seconds: Double) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}
