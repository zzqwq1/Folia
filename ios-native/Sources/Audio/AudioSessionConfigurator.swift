import Foundation
import AVFoundation

enum AudioSessionConfigurator {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            NSLog("[Folia] AVAudioSession configure failed: \(error)")
        }
    }
}
