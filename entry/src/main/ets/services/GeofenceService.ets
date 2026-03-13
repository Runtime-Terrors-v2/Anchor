import geoLocationManager from '@ohos.geoLocationManager';
import vibrator from '@ohos.vibrator';
import sensor from '@ohos.sensor';
import { notificationManager } from '@kit.NotificationKit';
import notification from '@ohos.notification'; // needed for ContentType — NotificationContent.contentType is typed against the older @ohos.notification.ContentType in this SDK
import preferences from '@ohos.data.preferences';
import { hilog } from '@kit.PerformanceAnalysisKit';
import common from '@ohos.app.ability.common';

const DOMAIN = 0x0000;
const PREFS_STORE = 'AnchorPrefs';
const KEY_ANCHOR_LAT = 'anchorLat';
const KEY_ANCHOR_LNG = 'anchorLng';
const KEY_PATIENT_NAME = 'patientName';

// --- Tunable thresholds ---

// Distance from anchor (metres) at which DRIFTING starts (requires motion too)
const DRIFTING_RADIUS_M = 30;
// Distance from anchor (metres) at which ALERT fires (requires motion too)
const ALERT_RADIUS_M = 50;

// GPS polling intervals (seconds) — slow at rest to save battery
const GPS_INTERVAL_ACTIVE = 10;  // when accelerometer detects walking
const GPS_INTERVAL_REST = 60;    // when still

// Net acceleration above gravity baseline (m/s²) to classify as "moving"
const MOTION_NET_THRESHOLD = 1.2;
// Number of accelerometer samples to average for sustained motion detection
const MOTION_SAMPLE_WINDOW = 10;

// Total acceleration spike (m/s²) that may indicate a fall (~2.5g)
const FALL_G_THRESHOLD = 25;
// If stillness follows within this window (ms) after a spike, confirm fall
const FALL_STILLNESS_MS = 2000;
// Near-stillness threshold: net accel below this counts as "still"
const FALL_STILLNESS_NET = 0.5;

// --- Public types ---

// The three states the geofence can be in
export enum DriftState {
  SAFE = 'SAFE',
  DRIFTING = 'DRIFTING',
  ALERT = 'ALERT'
}

export interface AnchorPoint {
  latitude: number;
  longitude: number;
}

// Callbacks the UI registers to receive updates.
// bearing: clockwise radians from north — used by the canvas to position the user dot.
export type StateChangeCallback = (state: DriftState, distanceMetres: number, bearing: number) => void;
export type FallDetectedCallback = () => void;

// --- GeofenceService ---

export class GeofenceService {
  private context: common.UIAbilityContext;
  private anchorPoint: AnchorPoint | null = null;
  private currentState: DriftState = DriftState.SAFE;

  // True when the accelerometer has detected sustained walking movement
  private isMotionDetected: boolean = false;

  // Rolling window of net-acceleration samples for motion averaging
  private motionSamples: number[] = [];

  // Timestamp of the last high-G spike (ms) — used for fall detection
  private lastHighGTime: number = 0;

  // Most recent GPS fix — included in fall alert messages
  private lastKnownLocation: geoLocationManager.Location | null = null;

  // Patient name loaded from preferences — shown in alert messages
  private patientName: string = 'Your family member';

  // Reference to the active location listener so we can unsubscribe
  private locationListener: ((location: geoLocationManager.Location) => void) | null = null;

  // Callbacks provided by the UI
  private onStateChange: StateChangeCallback;
  private onFallDetected: FallDetectedCallback;

  constructor(
    context: common.UIAbilityContext,
    onStateChange: StateChangeCallback,
    onFallDetected: FallDetectedCallback
  ) {
    this.context = context;
    this.onStateChange = onStateChange;
    this.onFallDetected = onFallDetected;
  }

  // ------------------------------------------------------------------
  // Anchor management
  // ------------------------------------------------------------------

  // Load a previously saved anchor point from persistent storage.
  // Call this once when the app starts before startMonitoring().
  async init(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, PREFS_STORE);
      const lat = await store.get(KEY_ANCHOR_LAT, 0) as number;
      const lng = await store.get(KEY_ANCHOR_LNG, 0) as number;
      if (lat !== 0 && lng !== 0) {
        this.anchorPoint = { latitude: lat, longitude: lng };
        hilog.info(DOMAIN, 'GeofenceService', 'Anchor loaded: %{public}s', JSON.stringify(this.anchorPoint));
      } else {
        hilog.info(DOMAIN, 'GeofenceService', 'No saved anchor found — first-run setup needed');
      }
      // Load patient name — used in fall alert messages
      const savedName = await store.get(KEY_PATIENT_NAME, '') as string;
      if (savedName !== '') {
        this.patientName = savedName;
      }
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Failed to load anchor: %{public}s', JSON.stringify(err));
    }
  }

  // Save the patient's name (called from the setup screen).
  // Used in fall alert messages so caregivers immediately know who the alert is about.
  async setPatientName(name: string): Promise<void> {
    this.patientName = name.trim() || 'Your family member';
    try {
      const store = await preferences.getPreferences(this.context, PREFS_STORE);
      await store.put(KEY_PATIENT_NAME, this.patientName);
      await store.flush();
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Failed to save patient name: %{public}s', JSON.stringify(err));
    }
  }

  // Save a new anchor point (called by caregiver tapping "Set Home Point").
  async setAnchorPoint(latitude: number, longitude: number): Promise<void> {
    this.anchorPoint = { latitude, longitude };
    try {
      const store = await preferences.getPreferences(this.context, PREFS_STORE);
      await store.put(KEY_ANCHOR_LAT, latitude);
      await store.put(KEY_ANCHOR_LNG, longitude);
      await store.flush(); // write through to disk immediately
      hilog.info(DOMAIN, 'GeofenceService', 'Anchor saved: %{public}s', JSON.stringify(this.anchorPoint));
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Failed to save anchor: %{public}s', JSON.stringify(err));
    }
  }

  // Returns true if an anchor point has been set (used by UI to decide which screen to show)
  hasAnchor(): boolean {
    return this.anchorPoint !== null;
  }

  // Returns the saved anchor point — used by the canvas map to position the home dot
  getAnchorPoint(): AnchorPoint | null {
    return this.anchorPoint;
  }

  // Returns the most recent GPS fix — used by the canvas map to position the user dot
  getLastLocation(): geoLocationManager.Location | null {
    return this.lastKnownLocation;
  }

  // ------------------------------------------------------------------
  // Monitoring lifecycle
  // ------------------------------------------------------------------

  // Start accelerometer + GPS subscriptions.
  // GPS interval depends on current motion state.
  startMonitoring(): void {
    hilog.info(DOMAIN, 'GeofenceService', 'Starting monitoring');
    this.startAccelerometer();
    this.startGpsTracking(this.isMotionDetected ? GPS_INTERVAL_ACTIVE : GPS_INTERVAL_REST);
  }

  // Stop all sensors and location subscriptions. Call in onBackground/onDestroy.
  stopMonitoring(): void {
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (err) {
      hilog.warn(DOMAIN, 'GeofenceService', 'Accelerometer stop failed: %{public}s', JSON.stringify(err));
    }
    try {
      if (this.locationListener !== null) {
        geoLocationManager.off('locationChange', this.locationListener);
        this.locationListener = null;
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'GeofenceService', 'GPS stop failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'GeofenceService', 'Monitoring stopped');
  }

  // ------------------------------------------------------------------
  // Accelerometer (motion + fall detection)
  // ------------------------------------------------------------------

  private startAccelerometer(): void {
    try {
      // 'normal' interval ≈ 5 Hz — sufficient for walking detection, low power draw
      // Explicitly typed to satisfy ArkTS arkts-no-untyped-obj-literals rule
      const sensorOptions: sensor.Options = { interval: 'normal' };
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.processAccelerometerData(data.x, data.y, data.z);
      }, sensorOptions);
      hilog.info(DOMAIN, 'GeofenceService', 'Accelerometer started');
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Accelerometer start failed: %{public}s', JSON.stringify(err));
    }
  }

  // Processes one accelerometer reading for both motion and fall detection.
  private processAccelerometerData(x: number, y: number, z: number): void {
    // Total vector magnitude; at rest this is ~9.8 (gravity only)
    const magnitude = Math.sqrt(x * x + y * y + z * z);
    // Net acceleration above gravity — represents actual body movement
    const netAccel = Math.abs(magnitude - 9.8);

    // --- Fall detection ---
    // Pattern: sudden large spike (>FALL_G_THRESHOLD m/s²) followed by stillness
    if (magnitude > FALL_G_THRESHOLD) {
      this.lastHighGTime = Date.now();
    } else if (
      this.lastHighGTime > 0 &&
      netAccel < FALL_STILLNESS_NET &&
      (Date.now() - this.lastHighGTime) > FALL_STILLNESS_MS
    ) {
      // High-G spike happened recently, and we've now gone still — probable fall
      hilog.warn(DOMAIN, 'GeofenceService', 'Fall signature detected');
      this.lastHighGTime = 0; // reset so we don't re-fire on the same event
      this.handleFall();
    }

    // --- Sustained motion detection ---
    // Maintain a rolling window of net-acceleration samples and take the average.
    // A single jostle won't trigger — it needs sustained movement (walking).
    this.motionSamples.push(netAccel);
    if (this.motionSamples.length > MOTION_SAMPLE_WINDOW) {
      this.motionSamples.shift(); // drop the oldest sample
    }
    const avgNetAccel = this.motionSamples.reduce((a, b) => a + b, 0) / this.motionSamples.length;

    const wasMoving = this.isMotionDetected;
    this.isMotionDetected = avgNetAccel > MOTION_NET_THRESHOLD;

    // If motion state changed, switch GPS to the appropriate polling rate
    if (this.isMotionDetected !== wasMoving) {
      hilog.info(DOMAIN, 'GeofenceService', 'Motion changed → %{public}s', String(this.isMotionDetected));
      const interval = this.isMotionDetected ? GPS_INTERVAL_ACTIVE : GPS_INTERVAL_REST;
      this.restartGpsTracking(interval);
    }
  }

  // ------------------------------------------------------------------
  // GPS tracking
  // ------------------------------------------------------------------

  private startGpsTracking(intervalSeconds: number): void {
    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
      scenario: geoLocationManager.LocationRequestScenario.UNSET,
      timeInterval: intervalSeconds,
      distanceInterval: 0,
      maxAccuracy: 100 // loose accuracy requirement — works better indoors
    };

    // Store the listener reference so we can remove it later
    this.locationListener = (location: geoLocationManager.Location) => {
      this.onLocationUpdate(location);
    };

    try {
      geoLocationManager.on('locationChange', request, this.locationListener);
      hilog.info(DOMAIN, 'GeofenceService', 'GPS started at %{public}ds interval', intervalSeconds);
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'GPS start failed: %{public}s', JSON.stringify(err));
    }
  }

  // Unsubscribe the current listener and re-subscribe at a new interval.
  // Called when motion state changes to avoid unnecessary battery drain.
  private restartGpsTracking(intervalSeconds: number): void {
    try {
      if (this.locationListener !== null) {
        geoLocationManager.off('locationChange', this.locationListener);
        this.locationListener = null;
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'GeofenceService', 'GPS stop (for restart) failed: %{public}s', JSON.stringify(err));
    }
    this.startGpsTracking(intervalSeconds);
  }

  // Called each time a new GPS fix arrives from the system
  private onLocationUpdate(location: geoLocationManager.Location): void {
    // Always store the latest fix — used in fall alerts regardless of anchor state
    this.lastKnownLocation = location;

    if (this.anchorPoint === null) {
      // No anchor set yet — caregiver hasn't done first-time setup
      return;
    }

    const distanceM = this.haversineDistance(
      this.anchorPoint.latitude,
      this.anchorPoint.longitude,
      location.latitude,
      location.longitude
    );

    // Bearing from anchor to current position (radians, clockwise from north)
    const bearing = this.calculateBearing(
      this.anchorPoint.latitude,
      this.anchorPoint.longitude,
      location.latitude,
      location.longitude
    );

    hilog.info(DOMAIN, 'GeofenceService', 'Distance: %{public}dm bearing: %{public}d°',
      Math.round(distanceM), Math.round(bearing * 180 / Math.PI));
    this.evaluateDriftState(distanceM, bearing);
  }

  // ------------------------------------------------------------------
  // Drift state machine
  // ------------------------------------------------------------------

  // Decides the current DriftState based on distance + motion signal.
  // Only fires haptics/notifications on state *transitions* to avoid spam.
  private evaluateDriftState(distanceM: number, bearing: number): void {
    let newState: DriftState;

    if (!this.isMotionDetected || distanceM < DRIFTING_RADIUS_M) {
      // Still, or within the inner safe zone — no concern
      newState = DriftState.SAFE;
    } else if (distanceM < ALERT_RADIUS_M) {
      // Motion detected AND in the 30–50m band — early warning, not yet critical
      newState = DriftState.DRIFTING;
    } else {
      // Motion detected AND beyond 50m — caregiver must be notified now
      newState = DriftState.ALERT;
    }

    const stateChanged = newState !== this.currentState;

    if (stateChanged) {
      hilog.info(DOMAIN, 'GeofenceService', 'State: %{public}s → %{public}s', this.currentState, newState);
      this.currentState = newState;

      // Haptic on every state change so the patient gets a wrist cue
      this.triggerHaptic(newState);

      // Caregiver notification only on the critical transition to ALERT
      if (newState === DriftState.ALERT) {
        this.triggerCaregiverAlert(distanceM);
      }
    }

    // Always call back so the UI can update the distance readout and map position
    this.onStateChange(newState, distanceM, bearing);
  }

  // ------------------------------------------------------------------
  // Haptic feedback
  // ------------------------------------------------------------------

  private triggerHaptic(state: DriftState): void {
    try {
      if (state === DriftState.DRIFTING) {
        // 1 short pulse — a gentle nudge, not alarming
        this.vibrate(200);
      } else if (state === DriftState.ALERT) {
        // 3 firm pulses (300ms on, 150ms off) — clear, unmistakeable alert
        // HarmonyOS vibrator is single-shot, so we chain calls via setTimeout
        this.vibrate(300);
        setTimeout(() => { this.vibrate(300); }, 450);
        setTimeout(() => { this.vibrate(300); }, 900);
      }
      // No haptic for SAFE — silence is reassurance
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Vibrator failed: %{public}s', JSON.stringify(err));
    }
  }

  // Fires a single vibration of the given duration.
  // Extracted so that vibrator object literals are always explicitly typed —
  // ArkTS forbids untyped inline object literals (arkts-no-untyped-obj-literals).
  private vibrate(durationMs: number): void {
    const effect: vibrator.VibrateTime = { type: 'time', duration: durationMs };
    const attr: vibrator.VibrateAttribute = { id: 0, usage: 'alarm' };
    vibrator.startVibration(effect, attr);
  }

  // ------------------------------------------------------------------
  // Caregiver notifications
  // ------------------------------------------------------------------

  // Sends a push notification to the caregiver's device on ALERT.
  // Uses a fixed notification ID (1001) so repeat alerts update in-place
  // rather than stacking and cluttering the notification shade.
  private triggerCaregiverAlert(distanceM: number): void {
    const distanceText = `${Math.round(distanceM)}m from home`;

    // ArkTS requires every object literal to match an explicit type — declare sub-objects separately
    const normalContent: notificationManager.NotificationBasicContent = {
      title: 'ANCHOR Alert',
      text: `${this.patientName} may have left home. Last known: ${distanceText}.`,
      additionalText: 'Tap to open ANCHOR'
    };
    const content: notificationManager.NotificationContent = {
      contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: normalContent
    };
    const notifRequest: notificationManager.NotificationRequest = {
      id: 1001,
      content: content,
      deliveryTime: Date.now(),
      showDeliveryTime: true
    };

    notificationManager.publish(notifRequest)
      .then(() => hilog.info(DOMAIN, 'GeofenceService', 'Caregiver alert sent'))
      .catch((err: Error) => hilog.error(DOMAIN, 'GeofenceService', 'Notification failed: %{public}s', JSON.stringify(err)));
  }

  // ------------------------------------------------------------------
  // Fall detection
  // ------------------------------------------------------------------

  // Handles a confirmed fall event — fires independently of geofence state.
  // A fall indoors is just as critical as one outside.
  private handleFall(): void {
    // 3 long pulses — distinct from drift pattern so caregiver recognises urgency
    try {
      this.vibrate(500);
      setTimeout(() => { this.vibrate(500); }, 700);
      setTimeout(() => { this.vibrate(500); }, 1400);
    } catch (err) {
      hilog.error(DOMAIN, 'GeofenceService', 'Fall haptic failed: %{public}s', JSON.stringify(err));
    }

    // Build the alert message with name, GPS coords, and timestamp as specified
    const now = Date.now();
    const locationText = this.lastKnownLocation !== null
      ? this.formatCoords(this.lastKnownLocation)
      : 'Unknown';
    const alertText =
      `ANCHOR Fall Alert — ${this.patientName} may have fallen. ` +
      `Location: ${locationText}. Time: ${this.formatTimestamp(now)}.`;

    hilog.warn(DOMAIN, 'GeofenceService', 'Fall alert: %{public}s', alertText);

    // Fall notifications use ID 1002 so they never overwrite drift alerts (ID 1001)
    // ArkTS requires every object literal to match an explicit type — declare sub-objects separately
    const fallNormal: notificationManager.NotificationBasicContent = {
      title: 'ANCHOR Fall Alert',
      text: alertText,
      additionalText: 'Tap to open ANCHOR'
    };
    const fallContent: notificationManager.NotificationContent = {
      contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: fallNormal
    };
    const fallRequest: notificationManager.NotificationRequest = {
      id: 1002,
      content: fallContent,
      deliveryTime: now,
      showDeliveryTime: true
    };

    notificationManager.publish(fallRequest)
      .then(() => hilog.info(DOMAIN, 'GeofenceService', 'Fall notification sent'))
      .catch((err: Error) => hilog.error(DOMAIN, 'GeofenceService', 'Fall notification failed: %{public}s', JSON.stringify(err)));

    // Notify UI so it can show the fall overlay screen
    this.onFallDetected();
  }

  // Formats a GPS location as human-readable coordinates.
  // e.g. "51.5074°N, 0.1278°W"
  private formatCoords(location: geoLocationManager.Location): string {
    const lat = Math.abs(location.latitude).toFixed(4);
    const lng = Math.abs(location.longitude).toFixed(4);
    const latDir = location.latitude >= 0 ? 'N' : 'S';
    const lngDir = location.longitude >= 0 ? 'E' : 'W';
    return `${lat}°${latDir}, ${lng}°${lngDir}`;
  }

  // Formats a Unix timestamp (ms) as HH:MM for inclusion in alert messages.
  private formatTimestamp(timestampMs: number): string {
    const date = new Date(timestampMs);
    const hours = date.getHours().toString().padStart(2, '0');
    const mins = date.getMinutes().toString().padStart(2, '0');
    return `${hours}:${mins}`;
  }

  // ------------------------------------------------------------------
  // Haversine distance calculation
  // ------------------------------------------------------------------

  // Returns the initial bearing in radians (clockwise from north) from point 1 to point 2.
  // Used by the canvas to place the user dot in the correct direction from the home dot.
  private calculateBearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const dLon = this.toRadians(lon2 - lon1);
    const y = Math.sin(dLon) * Math.cos(this.toRadians(lat2));
    const x =
      Math.cos(this.toRadians(lat1)) * Math.sin(this.toRadians(lat2)) -
      Math.sin(this.toRadians(lat1)) * Math.cos(this.toRadians(lat2)) * Math.cos(dLon);
    return Math.atan2(y, x); // result: -π to π, clockwise from north
  }

  // Returns the great-circle distance in metres between two lat/lng points.
  // Used instead of a straight-line calculation because Earth is a sphere.
  private haversineDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R = 6371000; // Earth's mean radius in metres
    const dLat = this.toRadians(lat2 - lat1);
    const dLon = this.toRadians(lon2 - lon1);
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(this.toRadians(lat1)) * Math.cos(this.toRadians(lat2)) *
      Math.sin(dLon / 2) * Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  private toRadians(degrees: number): number {
    return degrees * (Math.PI / 180);
  }
}
