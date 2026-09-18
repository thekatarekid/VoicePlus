import Foundation
import Shared

/// Spans the real final model (parakeet-tdt-0.6b-v3) produced for the number lines of the
/// real-room corpus (`Fixtures/real-room/builtin`, script lines 02–18), captured by
/// `Tests/EngineTests/RealRoomNumbersReplayTests.swift` (`realRoomNumberLineSpans`). The WAVs are
/// git-ignored, so the pipeline tests format this snapshot instead of the audio.
///
/// Each row is (text, confidence, audioStart, audioEnd), exactly as printed by that test.
enum RealRoomNumberSnapshots {
    typealias Row = (String, Float, Double, Double)

    static func spans(_ rows: [Row]) -> [TranscriptSpan] {
        rows.map { TranscriptSpan(text: $0.0, confidence: $0.1, audioRange: $0.2...$0.3, provenance: [.asr]) }
    }

    /// 05 "The invoice total is 2,340 rupees, not 2,430." — raw capture.
    static let line05Raw: [Row] = [
        ("The", 0.991, 0.240, 0.560),
        ("invoice", 0.998, 0.560, 1.360),
        ("total", 1.000, 1.360, 1.680),
        ("is", 1.000, 1.680, 2.000),
        ("two", 0.934, 2.000, 2.160),
        ("three", 0.997, 2.400, 2.640),
        ("four", 0.978, 2.720, 2.960),
        ("zero", 0.988, 2.960, 3.280),
        ("rupees", 0.973, 3.280, 3.920),
        ("not", 0.864, 4.400, 4.640),
        ("two", 0.942, 4.880, 5.040),
        ("four", 0.872, 5.280, 5.600),
        ("three", 0.999, 5.600, 5.840),
        ("zero.", 0.677, 5.920, 7.680),
    ]

    /// 05 — processed (noise-suppressed) copy of the same capture.
    static let line05Processed: [Row] = [
        ("The", 0.993, 0.240, 0.560),
        ("invoice", 0.993, 0.560, 1.360),
        ("total", 1.000, 1.360, 1.680),
        ("is", 1.000, 1.680, 2.000),
        ("two", 0.942, 2.000, 2.160),
        ("three", 0.990, 2.400, 2.640),
        ("four", 0.972, 2.720, 2.960),
        ("zero", 0.990, 2.960, 3.280),
        ("rupees,", 0.750, 3.280, 4.400),
        ("not", 0.949, 4.400, 4.640),
        ("two", 0.978, 4.880, 5.040),
        ("four", 0.868, 5.280, 5.600),
        ("three", 0.997, 5.600, 5.840),
        ("zero.", 0.658, 5.920, 7.680),
    ]

    /// 04 "My flight lands at 11:45, …" — processed copy; the model spelled the time out.
    static let line04Processed: [Row] = [
        ("My", 0.979, 0.160, 0.400),
        ("flight", 1.000, 0.400, 0.960),
        ("lands", 1.000, 0.960, 1.360),
        ("at", 1.000, 1.360, 1.680),
        ("eleven", 0.997, 1.680, 2.080),
        ("forty-five,", 0.705, 2.320, 3.920),
        ("so", 0.999, 3.920, 4.240),
        ("let's", 0.881, 4.240, 4.880),
        ("meet", 1.000, 4.880, 5.200),
        ("at", 0.999, 5.200, 5.360),
        ("the", 0.996, 5.360, 5.680),
        ("gate", 0.991, 5.680, 6.080),
        ("around", 0.998, 6.080, 6.640),
        ("noon.", 0.628, 6.640, 7.920),
    ]

    /// 08 "Order two of the large ones and one of the small ones." — small counts stay words.
    static let line08Raw: [Row] = [
        ("Order", 0.998, 0.160, 0.800),
        ("two", 1.000, 0.800, 1.120),
        ("of", 1.000, 1.120, 1.440),
        ("the", 1.000, 1.440, 1.760),
        ("large", 0.983, 1.760, 2.400),
        ("ones", 0.988, 2.400, 2.880),
        ("and", 1.000, 3.120, 3.360),
        ("one", 1.000, 3.360, 3.600),
        ("of", 1.000, 3.600, 3.840),
        ("the", 1.000, 3.840, 4.080),
        ("small", 0.999, 4.080, 4.640),
        ("ones.", 0.522, 4.640, 6.080),
    ]

    /// 11 "Their new address is 14 Carter Road, Bandra, Mumbai 400050." — processed copy.
    static let line11Processed: [Row] = [
        ("Their", 0.729, 0.000, 0.480),
        ("new", 1.000, 0.480, 0.800),
        ("address", 1.000, 0.800, 1.360),
        ("is", 1.000, 1.360, 1.680),
        ("Fourteen", 0.670, 1.680, 2.080),
        ("Carter", 0.917, 2.320, 2.800),
        ("Road,", 0.582, 3.040, 3.520),
        ("Bandra,", 0.691, 3.520, 4.560),
        ("Mumbai", 0.991, 4.560, 5.200),
        ("40050.", 0.531, 5.600, 8.400),
    ]

    /// 18 "We have three options: ship now, …" — raw capture.
    static let line18Raw: [Row] = [
        ("We", 1.000, 0.080, 0.320),
        ("have", 1.000, 0.320, 0.560),
        ("three", 0.997, 0.560, 0.880),
        ("options:", 0.995, 0.880, 1.600),
        ("ship", 1.000, 1.600, 2.080),
        ("now,", 0.996, 2.080, 2.480),
        ("ship", 1.000, 2.480, 2.880),
        ("next", 1.000, 2.880, 3.200),
        ("week,", 0.908, 3.200, 3.600),
        ("or", 1.000, 3.600, 3.920),
        ("do", 0.977, 3.920, 4.000),
        ("not", 1.000, 4.080, 4.320),
        ("ship", 1.000, 4.320, 4.720),
        ("at", 1.000, 4.720, 5.040),
        ("all", 1.000, 5.040, 5.360),
    ]
}
