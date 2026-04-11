// ANCHOR — Caregiver phone companion
// Minimal dashboard: shows watch connection status and a placeholder alert count.
// No external dependencies — uses only built-in HarmonyOS APIs.

@Entry
@Component
struct Index {
  @State watchConnected: boolean = false;
  @State alertCount: number = 0;

  build() {
    Column({ space: 0 }) {

      // Header
      Row() {
        Text('ANCHOR')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')

        Text('Caregiver')
          .fontSize(13)
          .fontColor('#888888')
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 20, right: 20, top: 24, bottom: 8 })

      // Watch status card
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Circle()
            .width(12)
            .height(12)
            .fill(this.watchConnected ? '#1DAB5F' : '#E84026')

          Text(this.watchConnected ? 'Watch connected' : 'Watch not connected')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.watchConnected ? '#0F6E56' : '#A32D2D')
        }
        .alignItems(VerticalAlign.Center)

        Text(this.watchConnected ? 'Monitoring active' : 'Open ANCHOR on the watch to begin')
          .fontSize(13)
          .fontColor('#666666')
      }
      .width('90%')
      .alignItems(HorizontalAlign.Start)
      .padding(20)
      .margin({ top: 16 })
      .borderRadius(12)
      .border({ width: 0.5, color: this.watchConnected ? '#9FE1CB' : '#F7C1C1' })
      .backgroundColor(this.watchConnected ? '#E1F5EE' : '#FCEBEB')

      // Stats row
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('Alerts')
            .fontSize(12)
            .fontColor('#888888')
          Text(this.alertCount.toString())
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text('this week')
            .fontSize(12)
            .fontColor('#AAAAAA')
        }
        .layoutWeight(1)
        .padding(16)
        .borderRadius(10)
        .backgroundColor('#F5F5F5')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text('Status')
            .fontSize(12)
            .fontColor('#888888')
          Text('SAFE')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1DAB5F')
          Text('last known')
            .fontSize(12)
            .fontColor('#AAAAAA')
        }
        .layoutWeight(1)
        .padding(16)
        .borderRadius(10)
        .backgroundColor('#F5F5F5')
        .alignItems(HorizontalAlign.Start)
      }
      .width('90%')
      .margin({ top: 16 })

      // Debug toggle — simulates connection state during emulator testing
      Button(this.watchConnected ? 'Simulate disconnect' : 'Simulate connect')
        .width('90%')
        .height(44)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.watchConnected ? '#E84026' : '#1DAB5F')
        .borderRadius(10)
        .margin({ top: 32 })
        .onClick(() => {
          this.watchConnected = !this.watchConnected;
          if (!this.watchConnected) {
            this.alertCount++;
          }
        })

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Center)
  }
}
