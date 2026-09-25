import SwiftUI
import CoreBluetooth

struct ScanToggle: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    
    @Binding var isScaning: Bool
    
    @State private var showBluetoothAlert = false
    
    private let frameHeight: CGFloat = 46
    private let cornerRadius: CGFloat = 13
    private let paddingHorizontal: CGFloat = 14
    private let imageSize: CGFloat = 28
    private let bleManager = BLEManager.shared
    
    private var iconEye: some View {
        Image.iconEye
            .resizable()
            .scaledToFit()
            .frame(width: imageSize, height: imageSize)
    }
    
    private var scanToggle: some View {
        Toggle(Inc.Scanning.scanning.localized, isOn: $isScaning)
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .shumOnChange(of: isScaning) { _, newValue in
                coordinator.setScanning(newValue)

                if newValue, !bleManager.isBluetoothAvailable {
                    showBluetoothAlert = true
                }
            }
            .alert(Inc.Alerts.turnOnBLE.localized, isPresented: $showBluetoothAlert) {
                Button(Inc.Common.okey.localized) { }
            }
    }
    
    private var content: some View {
        HStack {
            iconEye
            scanToggle
        }
        .padding(.horizontal, paddingHorizontal)
        .frame(maxWidth: .infinity, minHeight: frameHeight)
        .background(Color.grOne)
        .cornerRadius(cornerRadius)
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
