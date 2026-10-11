import Foundation
#if canImport(Nitrakit)
import Nitrakit
#endif

/// Scripted playback / seek / scrub run that prints player stats (dev tool for host apps).
public enum PreviewBenchmark {
    public static func run(_ p: Player, duration: Int64, done: @escaping () -> Void) {
        p.setVolume(volume: 0)
        func secs(_ us: Int64) -> String { String(format: "%.2fs", Double(us) / 1e6) }
        func log(_ s: String) {
            print(s)
            fflush(stdout)
        }
        func stats(_ what: String) {
            let s = p.stats()
            log(String(format: "%@: frames %llu dropped %llu decoders %llu underruns %llu surface errors %llu | frame avg %.2f ms (decode %.2f acquire %.2f gpu %.2f) | pos %@",
                       what, s.frames, s.dropped, s.decodersOpened, s.audioUnderruns, s.surfaceErrors, s.avgFrameMs, s.lastDecodeMs, s.lastAcquireMs, s.lastGpuMs,
                       secs(p.positionUs())))
        }
        /// Polls until the seek count passes `n`, then reports.
        func awaitSeek(_ what: String, after n: UInt64, started: Date, then next: @escaping () -> Void) {
            let s = p.stats()
            if s.seeks > n {
                log(String(format: "%@: first frame %.1f ms, exact %.1f ms, decoders %llu", what, s.lastSeekFirstMs, s.lastSeekMs, s.decodersOpened))
                next()
            } else if Date().timeIntervalSince(started) > 5 {
                log("\(what): TIMEOUT")
                next()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { awaitSeek(what, after: n, started: started, then: next) }
            }
        }
        func after(_ d: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }

        let targets = [0.25, 0.8, 0.1, 0.55, 0.9, 0.3, 0.31, 0.6]
        func seeks(_ i: Int, then next: @escaping () -> Void) {
            guard i < targets.count else { return next() }
            let n = p.stats().seeks
            p.seek(timeUs: Int64(Double(duration) * targets[i]))
            awaitSeek("seek → \(targets[i])", after: n, started: Date()) { after(0.1) { seeks(i + 1, then: next) } }
        }
        func scrub(backward: Bool, then next: @escaping () -> Void) {
            // 60 seeks over a second, like a finger drag over 30% of the timeline.
            let before = p.stats().frames
            for k in 0..<60 {
                after(Double(k) / 60) {
                    let f = 0.3 * Double(k) / 60
                    p.seek(timeUs: Int64(Double(duration) * (backward ? 0.7 - f : 0.2 + f)))
                }
            }
            after(1.6) {
                let s = p.stats()
                log(String(format: "scrub %@: %llu frames shown in 1 s, final seek first %.1f ms exact %.1f ms",
                           backward ? "backward" : "forward", s.frames - before, s.lastSeekFirstMs, s.lastSeekMs))
                next()
            }
        }

        after(1.0) {
            stats("idle")
            p.play()
            after(5.0) {
                stats("played 5s")
                p.pause()
                after(0.2) {
                    seeks(0) {
                        scrub(backward: false) {
                            scrub(backward: true) {
                                p.seek(timeUs: Int64(Double(duration) * 0.45))
                                p.play()
                                after(3.0) {
                                    stats("play from 45% 3s")
                                    p.pause()
                                    after(0.3, done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
