import SwiftUI
import TDLibKit
 
struct ContentView: View {
    @StateObject private var tgManager = TelegramManager.shared
    
    var body: some View {
        Group {
            if tgManager.currentScreen == .mainMenu {
                MainMenuView()
                    .transition(.opacity)
            } else {
                ZStack {
                    Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                    
                    Group {
                        switch tgManager.currentScreen {
                        case .initializing:
                            Color.clear
                        case .welcome:
                            WelcomeView()
                        case .enterPhone, .enterCode, .enterPassword:
                            LoginView()
                        default:
                            EmptyView()
                        }
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                    .id(tgManager.currentScreen)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: tgManager.currentScreen)
        // Фіксований розмір вікна точнісінько під твій дизайн
        .frame(width: 500, height: 450)
    }
}
