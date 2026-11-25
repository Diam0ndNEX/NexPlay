import UIKit
import QuartzCore

// 8.20.0: a game whose frame rate does not divide 60 (RPG Maker XP runs at 40 fps) showed its frames for 16.7 and
// 33.3 ms in turn on a 120 Hz iPhone, because a Metal layer alone keeps the screen at 60 Hz. While such a game runs,
// an idle display link asks for 120 Hz (needs CADisableMinimumFrameDurationOnPhone, which Info.plist sets), so 40 fps
// is shown as 3 + 3 + 3 refreshes. Idea and rule from Empo's ScreenRate.m (#316):
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

@MainActor
enum ScreenRate {
    private static var link: CADisplayLink?
    private static var current: Int = 0

    /// True when 60 Hz can't show `gameRate` evenly (40, 24, 45, 50...).
    nonisolated static func needs120Hz(_ gameRate: Int) -> Bool {
        gameRate > 0 && 60 % gameRate != 0
    }

    /// Tells the screen the game's frame rate; 0 when no game runs.
    static func set(gameRate: Int) {
        guard gameRate != current else { return }
        current = gameRate
        guard needs120Hz(gameRate), UIScreen.main.maximumFramesPerSecond > 60 else {
            if link != nil { AppLog.log("screen rate: back to normal") }
            link?.invalidate()
            link = nil
            return
        }
        guard link == nil else { return }
        let made = CADisplayLink(target: Tick.shared, selector: #selector(Tick.tick(_:)))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        made.add(to: .main, forMode: .common)
        link = made
        AppLog.log("screen rate: 120 Hz for a \(gameRate) fps game (even frame times)")
    }

    private final class Tick: NSObject {
        static let shared = Tick()
        @objc func tick(_ link: CADisplayLink) {}
    }
}
