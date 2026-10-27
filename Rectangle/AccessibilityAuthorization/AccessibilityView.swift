/// AccessibilityView.swift

import SwiftUI
import AppKit

// MARK: - SwiftUI Views

struct AccessibilityView: View {
    @ObservedObject var manager: AccessibilityAuthorization
    
    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Authorize Rectangle").replacingOccurrences(of: "Rectangle", with: appDisplayName))
                .font(.system(size: 20, weight: .semibold))
            
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .cornerRadius(12)
            }
            
            Text(String(localized: "Rectangle needs your permission to control your window positions.").replacingOccurrences(of: "Rectangle", with: appDisplayName))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            
            Text(systemSettingsPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250)
            
            Button(action: openSystemSettings) {
                Text("Open System Settings")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            
            Text(String(localized: "Enable Rectangle.app").replacingOccurrences(of: "Rectangle", with: appDisplayName))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 320)
    }
    
    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SnapGrid"
    }
    
    private var systemSettingsPath: String {
        if #available(macOS 27, *) {
            return String(localized: "Go to System Settings → Privacy & Security → Device Control and Data Access")
        } else {
            return String(localized: "Go to System Settings → Privacy & Security → Accessibility")
        }
    }
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

