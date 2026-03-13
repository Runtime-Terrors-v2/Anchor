import { DriftState, GeofenceService } from '../services/GeofenceService';
import common from '@ohos.app.ability.common';
import geoLocationManager from '@ohos.geoLocationManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

enum AppPage {
  MENU = 'MENU',
  HOME = 'HOME',
  SET_FENCE = 'SET_FENCE',
  CHECK_LOCATION = 'CHECK_LOCATION'
}

const HOME_CANVAS = 130;
const FENCE_CANVAS = 110;
const RING_RATIO = 0.80; // alert ring (50m) fills this fraction of canvas half-width

@Entry
@Component
struct Index {

  // --- Navigation ---
  @State private page: AppPage = AppPage.MENU;

  // --- Geofence state ---
  // distanceMetres starts at 0 — only updated by real GPS, never hardcoded
  @State private driftState: DriftState = DriftState.SAFE;
  @State private distanceMetres: number = 0;
  @State private bearing: number = 0;         // radians, clockwise from north
  @State private hasAnchor: boolean = false;
  @State private hasReceivedFix: boolean = false; // true once first real GPS update arrives
  @State private isFallDetected: boolean = false;

  // --- Check Location page ---
  @State private currentLat: number = 0;
  @State private currentLng: number = 0;
  @State private isFetchingLocation: boolean = false;
  @State private locationError: string = '';

  // --- Set Fence page ---
  @State private isSettingAnchor: boolean = false;

  // --- Canvas ---
  private renderCfg: RenderingContextSettings = new RenderingContextSettings(true);
  private homeCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderCfg);
  private fenceCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderCfg);
  private homeCanvasReady: boolean = false;
  private fenceCanvasReady: boolean = false;

  private geofenceService: GeofenceService | null = null;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;

    this.geofenceService = new GeofenceService(
      context,
      // State change callback — bearing is now included so the map is accurate
      (state: DriftState, distance: number, brng: number) => {
        this.driftState = state;
        this.distanceMetres = distance;
        this.bearing = brng;
        this.hasReceivedFix = true;
        this.redrawCanvases();
      },
      () => { this.isFallDetected = true; }
    );

    this.geofenceService.init().then(() => {
      this.hasAnchor = this.geofenceService!.hasAnchor();
      this.geofenceService!.startMonitoring();
    });
  }

  aboutToDisappear(): void {
    this.geofenceService?.stopMonitoring();
  }

  // ------------------------------------------------------------------
  // GPS helpers — shared by Set Fence and Check Location
  // ------------------------------------------------------------------

  // Checks that location is enabled before making any location call.
  // Returns false and sets locationError if not.
  private locationEnabled(): boolean {
    if (!geoLocationManager.isLocationEnabled()) {
      this.locationError = 'Location is off. Enable it in watch Settings.';
      return false;
    }
    this.locationError = '';
    return true;
  }

  // Shared request config — 10 s timeout prevents hanging indefinitely.
  private makeLocationRequest(): geoLocationManager.CurrentLocationRequest {
    const req: geoLocationManager.CurrentLocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
      scenario: geoLocationManager.LocationRequestScenario.UNSET,
      maxAccuracy: 0,
      timeoutMs: 10000
    };
    return req;
  }

  private setHomePoint(): void {
    if (!this.locationEnabled()) return;
    this.isSettingAnchor = true;

    geoLocationManager.getCurrentLocation(this.makeLocationRequest())
      .then((location: geoLocationManager.Location) => {
        this.geofenceService?.setAnchorPoint(location.latitude, location.longitude)
          .then(() => {
            this.isSettingAnchor = false;
            this.hasAnchor = true;
            // Snap distance to 0 — the new anchor IS the current position
            this.distanceMetres = 0;
            this.bearing = 0;
            this.redrawCanvases();
            hilog.info(DOMAIN, 'Index', 'Anchor set at %{public}f, %{public}f',
              location.latitude, location.longitude);
          });
      })
      .catch((err: Error) => {
        this.isSettingAnchor = false;
        this.locationError = 'Could not get a GPS fix. Try again outside.';
        hilog.error(DOMAIN, 'Index', 'setHomePoint failed: %{public}s', JSON.stringify(err));
      });
  }

  private fetchCurrentLocation(): void {
    if (!this.locationEnabled()) return;
    this.isFetchingLocation = true;
    this.locationError = '';

    geoLocationManager.getCurrentLocation(this.makeLocationRequest())
      .then((location: geoLocationManager.Location) => {
        this.currentLat = location.latitude;
        this.currentLng = location.longitude;
        this.isFetchingLocation = false;
        hilog.info(DOMAIN, 'Index', 'Location fix: %{public}f, %{public}f',
          location.latitude, location.longitude);
      })
      .catch((err: Error) => {
        this.isFetchingLocation = false;
        this.locationError = 'Could not get a GPS fix. Try again outside.';
        hilog.error(DOMAIN, 'Index', 'fetchLocation failed: %{public}s', JSON.stringify(err));
      });
  }

  // ------------------------------------------------------------------
  // Canvas drawing
  // ------------------------------------------------------------------

  private redrawCanvases(): void {
    if (this.homeCanvasReady) {
      this.drawMap(this.homeCtx, HOME_CANVAS);
    }
    if (this.fenceCanvasReady) {
      this.drawMap(this.fenceCtx, FENCE_CANVAS);
    }
  }

  // Draws geofence radar:
  //   green fill = safe zone (30 m)
  //   amber ring = 30 m drifting boundary
  //   red dashed ring = 50 m alert boundary
  //   white dot = home / anchor (always at centre)
  //   coloured dot = user, placed at real bearing + scaled distance
  private drawMap(ctx: CanvasRenderingContext2D, size: number): void {
    const cx = size / 2;
    const cy = size / 2;
    const scale = (cx * RING_RATIO) / 50; // px per metre

    ctx.clearRect(0, 0, size, size);
    ctx.fillStyle = '#141414';
    ctx.fillRect(0, 0, size, size);

    // Safe zone fill
    ctx.fillStyle = '#4ADE8018';
    ctx.beginPath();
    ctx.arc(cx, cy, 30 * scale, 0, Math.PI * 2);
    ctx.fill();

    // 30 m amber ring
    ctx.strokeStyle = '#FBBF2470';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, 30 * scale, 0, Math.PI * 2);
    ctx.stroke();

    // 50 m red dashed ring
    ctx.strokeStyle = '#F8717170';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([4, 3]);
    ctx.beginPath();
    ctx.arc(cx, cy, 50 * scale, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);

    // N label
    ctx.fillStyle = '#444444';
    ctx.font = `${Math.round(size * 0.08)}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.fillText('N', cx, size * 0.1);

    // Home dot at centre
    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    ctx.arc(cx, cy, 3, 0, Math.PI * 2);
    ctx.fill();

    // User dot — real bearing from GPS, capped at canvas edge
    // bearing = 0 → north (top), π/2 → east (right), π → south (bottom)
    const pxDist = Math.min(this.distanceMetres * scale, cx - 9);
    const ux = cx + pxDist * Math.sin(this.bearing);
    const uy = cy - pxDist * Math.cos(this.bearing);

    // Halo ring
    ctx.strokeStyle = this.statusColor() + '50';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(ux, uy, 7, 0, Math.PI * 2);
    ctx.stroke();

    // Filled dot
    ctx.fillStyle = this.statusColor();
    ctx.beginPath();
    ctx.arc(ux, uy, 3.5, 0, Math.PI * 2);
    ctx.fill();
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  private statusLabel(): string {
    if (this.driftState === DriftState.SAFE) return 'SAFE';
    if (this.driftState === DriftState.DRIFTING) return 'HEADING AWAY';
    return 'ALERT!';
  }

  private statusColor(): string {
    if (this.driftState === DriftState.SAFE) return '#4ADE80';
    if (this.driftState === DriftState.DRIFTING) return '#FBBF24';
    return '#F87171';
  }

  private distanceLabel(): string {
    if (!this.hasAnchor) return 'No home set';
    if (!this.hasReceivedFix) return 'Measuring...';
    if (this.distanceMetres < 5) return 'At home';
    return `${Math.round(this.distanceMetres)} m from home`;
  }

  private formatCoord(value: number, pos: string, neg: string): string {
    return `${Math.abs(value).toFixed(4)}° ${value >= 0 ? pos : neg}`;
  }

  // ------------------------------------------------------------------
  // Root build
  // ------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.Center }) {

      if (this.page === AppPage.MENU) {
        this.MenuPage();
      } else if (this.page === AppPage.HOME) {
        this.HomePage();
      } else if (this.page === AppPage.SET_FENCE) {
        this.SetFencePage();
      } else {
        this.CheckLocationPage();
      }

      if (this.isFallDetected) {
        this.FallOverlay();
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D0D0D')
  }

  // ------------------------------------------------------------------
  // Menu — default view
  // ------------------------------------------------------------------
  @Builder
  MenuPage() {
    Column({ space: 9 }) {

      Text('ANCHOR')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      // Live state badge — colour changes with drift state
      Row({ space: 4 }) {
        Text('●')
          .fontSize(9)
          .fontColor(this.statusColor())
        Text(this.statusLabel())
          .fontSize(11)
          .fontColor(this.statusColor())
          .fontWeight(FontWeight.Medium)
      }
      .padding({ left: 10, right: 10, top: 3, bottom: 3 })
      .borderRadius(10)
      .backgroundColor(this.statusColor() + '20')

      // Home — colour reflects live state so caregiver sees alert at a glance
      Button('Home')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0D0D0D')
        .backgroundColor(this.statusColor())
        .width('72%')
        .height(38)
        .borderRadius(19)
        .onClick(() => { this.page = AppPage.HOME; })

      Button('Set Fence')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#1E1E1E')
        .width('72%')
        .height(38)
        .borderRadius(19)
        .onClick(() => { this.page = AppPage.SET_FENCE; })

      Button('Check Location')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#1E1E1E')
        .width('72%')
        .height(38)
        .borderRadius(19)
        .onClick(() => {
          this.fetchCurrentLocation();
          this.page = AppPage.CHECK_LOCATION;
        })

      // Demo-only: lets you test the fall overlay without real accelerometer data
      Text('Simulate Fall')
        .fontSize(10)
        .fontColor('#3A3A3A')
        .padding({ top: 2, bottom: 2 })
        .onClick(() => { this.isFallDetected = true; })

    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
  }

  // ------------------------------------------------------------------
  // Home — status + distance + live radar
  // ------------------------------------------------------------------
  @Builder
  HomePage() {
    Column({ space: 5 }) {

      this.BackButton();

      Text(this.statusLabel())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.statusColor())

      Text(this.distanceLabel())
        .fontSize(12)
        .fontColor('#FFFFFF')

      Canvas(this.homeCtx)
        .width(HOME_CANVAS)
        .height(HOME_CANVAS)
        .borderRadius(HOME_CANVAS / 2)
        .onReady(() => {
          this.homeCanvasReady = true;
          this.drawMap(this.homeCtx, HOME_CANVAS);
        })

      Row({ space: 10 }) {
        Text('— 30 m')
          .fontSize(9)
          .fontColor('#FBBF24')
        Text('- - 50 m')
          .fontSize(9)
          .fontColor('#F87171')
      }

    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 14, right: 14, top: 4, bottom: 4 })
  }

  // ------------------------------------------------------------------
  // Set Fence — anchor setup + radar
  // ------------------------------------------------------------------
  @Builder
  SetFencePage() {
    Column({ space: 8 }) {

      this.BackButton();

      Text('Set Fence')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      Text(this.hasAnchor ? '● Home point set' : '○ No home point')
        .fontSize(11)
        .fontColor(this.hasAnchor ? '#4ADE80' : '#AAAAAA')

      Canvas(this.fenceCtx)
        .width(FENCE_CANVAS)
        .height(FENCE_CANVAS)
        .borderRadius(FENCE_CANVAS / 2)
        .onReady(() => {
          this.fenceCanvasReady = true;
          this.drawMap(this.fenceCtx, FENCE_CANVAS);
        })

      // Error message if GPS failed
      if (this.locationError !== '') {
        Text(this.locationError)
          .fontSize(10)
          .fontColor('#F87171')
          .textAlign(TextAlign.Center)
          .width('85%')
      }

      // Label changes once anchor is already set
      Button(this.isSettingAnchor ? 'Locating...' : (this.hasAnchor ? 'Reset Home Point' : 'Set Home Point'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0D0D0D')
        .backgroundColor('#4ADE80')
        .width('78%')
        .height(38)
        .borderRadius(19)
        .enabled(!this.isSettingAnchor)
        .onClick(() => { this.setHomePoint(); })

    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 14, right: 14, top: 4, bottom: 4 })
  }

  // ------------------------------------------------------------------
  // Check Location — scrollable, live GPS coordinates
  // ------------------------------------------------------------------
  @Builder
  CheckLocationPage() {
    // Scroll wrapper so content never clips on smaller watch faces
    Scroll() {
      Column({ space: 8 }) {

        this.BackButton();

        Text('Location')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        if (this.isFetchingLocation) {
          // Loading state — friendly copy, no technical jargon
          Column({ space: 6 }) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color('#4ADE80')
            Text('Finding your location…')
              .fontSize(11)
              .fontColor('#AAAAAA')
              .textAlign(TextAlign.Center)
          }
        } else if (this.locationError !== '') {
          Text(this.locationError)
            .fontSize(11)
            .fontColor('#F87171')
            .textAlign(TextAlign.Center)
            .width('85%')
        } else if (this.currentLat === 0 && this.currentLng === 0) {
          // Triggered first time before any fetch completes
          Column({ space: 6 }) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color('#4ADE80')
            Text('Finding your location…')
              .fontSize(11)
              .fontColor('#AAAAAA')
              .textAlign(TextAlign.Center)
          }
        } else {
          // Coordinates
          Text(this.formatCoord(this.currentLat, 'N', 'S'))
            .fontSize(12)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
          Text(this.formatCoord(this.currentLng, 'E', 'W'))
            .fontSize(12)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)

          // Live distance from anchor — uses real GPS, not hardcoded
          if (this.hasAnchor) {
            Text(this.distanceLabel())
              .fontSize(12)
              .fontColor(this.statusColor())
              .fontWeight(FontWeight.Medium)
          }
        }

        // Error text below GPS result (e.g. after a failed refresh)
        if (!this.isFetchingLocation && this.locationError !== '' && this.currentLat !== 0) {
          Text(this.locationError)
            .fontSize(10)
            .fontColor('#F87171')
            .textAlign(TextAlign.Center)
            .width('85%')
        }

        Button(this.isFetchingLocation ? 'Refreshing…' : 'Refresh')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#1E1E1E')
          .width('58%')
          .height(34)
          .borderRadius(17)
          .enabled(!this.isFetchingLocation)
          .onClick(() => { this.fetchCurrentLocation(); })

      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 14, right: 14, top: 6, bottom: 16 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------------
  // Shared back button
  // ------------------------------------------------------------------
  @Builder
  BackButton() {
    Text('< Back')
      .fontSize(11)
      .fontColor('#666666')
      .padding({ top: 3, bottom: 3, left: 6, right: 6 })
      .onClick(() => { this.page = AppPage.MENU; })
  }

  // ------------------------------------------------------------------
  // Fall overlay
  // ------------------------------------------------------------------
  @Builder
  FallOverlay() {
    Column({ space: 12 }) {

      Text('FALL DETECTED')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)

      Text('Caregiver alerted.')
        .fontSize(12)
        .fontColor('#FFCCCC')
        .textAlign(TextAlign.Center)

      Button('Dismiss')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#0D0D0D')
        .backgroundColor('#F87171')
        .width('58%')
        .height(40)
        .borderRadius(20)
        .onClick(() => { this.isFallDetected = false; })

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EE000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(18)
  }
}
