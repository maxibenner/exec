import Foundation

/// The shared macOS/iOS independent-neuron animation. Core Animation plays the
/// sampled curves without a per-frame application timer.
public enum NeuralPulse {
    public static let duration = 2 * Double.pi / (0.01 * 1.5)
    public static let curves: [[NSNumber]] = {
        let samples = Int(ceil(duration * 30))
        return (0..<15).map { dot in
            (0...samples).map { sample in
                NSNumber(value: brightness(dot: dot, time: duration * Double(sample) / Double(samples)))
            }
        }
    }()

    public static func brightness(dot: Int, time: Double) -> Float {
        let index = Double((dot / 5) * 7 + dot % 5)
        let phase = index * 2.399
        let time = time * 1.5
        let pulse = sin(time * (1.7 + index.truncatingRemainder(dividingBy: 5) * 0.19) + phase)
        let value = pulse * 0.75 + sin(time * 0.7 + phase * 1.3) * 0.25
        return Float(min(1, pow(max(0, value + 0.1), 2) * 2.5))
    }
}
