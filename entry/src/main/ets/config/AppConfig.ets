// AppConfig.ets
// Central configuration for the ANCHOR app.
// All tuneable thresholds and build-time flags live here so they are easy to adjust.
//
// IMPORTANT: set IS_EMULATOR = false before deploying to a real Huawei Watch.

export class AppConfig {

  // ---------------------------------------------------------------------------
  // Deployment target
  // ---------------------------------------------------------------------------

  // true  → DevEco Studio emulator: uses MockMotionDetector + MockFallDetector
  // false → real Huawei Watch:      uses RealMotionDetector + RealFallDetector
  static readonly IS_EMULATOR: boolean = true;

  // ---------------------------------------------------------------------------
  // Geofence radius thresholds (metres)
  // ---------------------------------------------------------------------------

  // Below this distance: patient is in the SAFE zone
  static readonly DRIFT_RADIUS: number = 30;

  // Beyond this distance (with motion): state escalates to ALERT
  static readonly ALERT_RADIUS: number = 50;

  // ---------------------------------------------------------------------------
  // GPS polling intervals (seconds)
  // ---------------------------------------------------------------------------

  // Faster polling when the accelerometer detects walking — catches exits early
  static readonly GPS_INTERVAL_ACTIVE: number = 10;

  // Slower polling when the patient is still — preserves watch battery
  static readonly GPS_INTERVAL_REST: number = 60;

  // ---------------------------------------------------------------------------
  // Motion detection (accelerometer)
  // ---------------------------------------------------------------------------

  // Net acceleration above gravity (m/s²) required to classify a reading as "moving"
  // Net = |magnitude − 9.8| — removes the constant gravity component
  static readonly MOTION_NET_THRESHOLD: number = 1.2;

  // Rolling window size (number of samples) used for sustained-motion averaging
  // At ~5 Hz (normal interval) this is roughly 2 seconds of data
  static readonly MOTION_SAMPLE_WINDOW: number = 10;

  // A new motion state must persist for this many milliseconds before being committed.
  // Prevents single-jostle or GPS-noise events from flipping the state.
  static readonly MOTION_DEBOUNCE_MS: number = 2000;

  // ---------------------------------------------------------------------------
  // Fall detection (accelerometer)
  // ---------------------------------------------------------------------------

  // Total magnitude (m/s²) that indicates an impact spike — roughly 2.5g
  static readonly FALL_IMPACT_THRESHOLD: number = 25;

  // Net acceleration below this value counts as post-fall stillness (m/s²)
  static readonly FALL_STILLNESS_THRESHOLD: number = 0.5;

  // The patient must remain still for this many ms after the spike to confirm a fall
  static readonly FALL_STILLNESS_DURATION: number = 2000;

  // ---------------------------------------------------------------------------
  // ML Fall Detection — MLFallDetector
  // ---------------------------------------------------------------------------
  // These values control the feature extractor and weighted scoring classifier.
  // They are intentionally separated from the threshold-based FALL_* values above
  // so both detectors can be tuned independently.

  // Number of pre-impact samples to keep in the sliding window.
  // At ~5 Hz (normal sensor interval), 5 samples ≈ 1 second of pre-fall context.
  static readonly ML_PRE_WINDOW_SIZE: number = 5;

  // Number of post-impact samples to collect before classifying.
  // 10 samples ≈ 2 seconds — enough to confirm sustained post-fall stillness.
  static readonly ML_POST_WINDOW_SIZE: number = 10;

  // Safety timeout (ms): if post-impact samples stop arriving (e.g. sensor fault),
  // abandon the candidate after this many ms to avoid the detector getting stuck.
  static readonly ML_POST_TIMEOUT_MS: number = 5000;

  // --- Scoring weights ---
  // Each weight scales one feature's contribution to the final fall score.
  // Must sum to 1.0. Impact and stillness carry more weight — they are the
  // primary biomechanical signatures of a fall.
  static readonly ML_W_IMPACT: number     = 0.40; // peak impact magnitude
  static readonly ML_W_STILLNESS: number  = 0.35; // post-fall mean net-accel (low = still)
  static readonly ML_W_VARIANCE: number   = 0.15; // post-fall variance (low = sustained stillness)
  static readonly ML_W_PRE_ENERGY: number = 0.10; // pre-fall activity level (low = not exercising)

  // --- Feature normalizers ---
  // Each normalizer maps a raw feature value to the [0, 1] score range.
  // Tuned from published wearable fall detection literature.
  // To raise sensitivity (catch more falls, more false positives): lower thresholds.
  // To raise specificity (fewer false positives): raise thresholds.

  // Impact peak normalizer: a magnitude of this value (m/s²) maps to score 1.0.
  // FALL_IMPACT_THRESHOLD is 25 m/s², so a typical 28 m/s² fall scores ~0.70.
  static readonly ML_IMPACT_NORMALIZER: number     = 40;

  // Stillness normalizer: net-accel of this value means "completely active" → score 0.
  // A person lying flat is typically < 0.3 m/s² net, scoring close to 1.0.
  static readonly ML_STILLNESS_NORMALIZER: number  = 2.0;

  // Variance normalizer: post-impact variance of this value means "jittery" → score 0.
  // Sustained stillness produces variance < 0.05, scoring close to 1.0.
  static readonly ML_VARIANCE_NORMALIZER: number   = 0.5;

  // Pre-energy normalizer: mean net-accel of this value means "vigorous activity" → score 0.
  // A seated or slow-walking senior is typically < 1.0 m/s², scoring close to 1.0.
  static readonly ML_PRE_ENERGY_NORMALIZER: number = 3.0;

  // --- Decision threshold ---
  // Minimum weighted score [0.0 – 1.0] required to confirm a fall.
  // 0.55 is tuned for seniors (CLAUDE.md: false negatives are dangerous —
  // err toward detecting real falls over avoiding false positives).
  static readonly ML_FALL_SCORE_THRESHOLD: number = 0.55;
}
