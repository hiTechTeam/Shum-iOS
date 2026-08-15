import SwiftUI
import CoreBluetooth

struct ScanToggle: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleVM: PeopleViewModel
    
    @Binding var isScaning: Bool
    
    @State private var showBluetoothAlert = false
    
    private let frameWidth: CGFloat = 360
    private let frameHeight: CGFloat = 46
    private let cornerRadius: CGFloat = 13
    private let paddingHorizontal: CGFloat = 14
    private let imageSize: CGFloat = 28
    private let telescanIDKey: String = GlobalVars.telescanIDKey
    private let bleManager = BLEManager.shared
    
    private var iconEye: some View {
        Image.iconEye
            .resizable()
            .scaledToFit()
            .frame(width: imageSize, height: imageSize)
    }
    
    private var scanToggle: some View {
        Toggle(Inc.Scanning.scanning.localized, isOn: $isScaning)
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .onChange(of: isScaning) { _, newValue in
                coordinator.isScaning = newValue
                UserDefaults.standard.set(newValue, forKey: Keys.isScaning.rawValue)

                if newValue {
                    peopleVM.toggleScanning(true)
                    if let value = UserDefaults.standard.string(
                        forKey: telescanIDKey
                    ), let telescanID = UUID(uuidString: value) {
                        peopleVM.startAdvertising(telescanID: telescanID)
                    }
                    if !bleManager.isBluetoothAvailable {
                        showBluetoothAlert = true
                    }
                } else {
                    peopleVM.stopAllBluetoothActivity()
                }
            }
            .alert(Inc.Alerts.turnOnBLE.localized, isPresented: $showBluetoothAlert) {
                Button(Inc.Common.okey) { }
            }
    }
    
    private var content: some View {
        HStack {
            iconEye
            scanToggle
        }
        .padding(.horizontal, paddingHorizontal)
        .frame(width: frameWidth, height: frameHeight)
        .background(Color.grOne)
        .cornerRadius(cornerRadius)
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
