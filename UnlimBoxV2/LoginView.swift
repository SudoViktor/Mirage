import SwiftUI
import TDLibKit
 
struct LoginView: View {
    @StateObject private var tgManager = TelegramManager.shared
    @State private var phoneNumber: String = ""
    @State private var authCode: String = ""
    @State private var password: String = ""
    
    var body: some View {
        VStack(spacing: 25) {
            HStack {
                Button(action: {
                    tgManager.cancelLogin()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 20)
            .padding(.horizontal, 30)
            
            Spacer()
            
            Image(systemName: iconName)
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .symbolEffect(.bounce, value: tgManager.currentScreen)
            
            VStack(spacing: 8) {
                Text(titleText)
                    .font(.title2.bold())
                Text(subtitleText)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 10) {
                Group {
                    if tgManager.currentScreen == .enterPhone {
                        TextField("+380...", text: $phoneNumber)
                            .onChange(of: phoneNumber) { _, _ in tgManager.errorMessage = nil }
                    } else if tgManager.currentScreen == .enterCode {
                        SecureField("Код авторизації", text: $authCode)
                            .onChange(of: authCode) { _, _ in tgManager.errorMessage = nil }
                    } else {
                        SecureField("Хмарний пароль", text: $password)
                            .onChange(of: password) { _, _ in tgManager.errorMessage = nil }
                    }
                }
                .textFieldStyle(.plain)
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                
                // ВІДОБРАЖЕННЯ ПОМИЛОК
                if let error = tgManager.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 40)
            
            Button(action: {
                if tgManager.currentScreen == .enterPhone {
                    tgManager.setPhoneNumber(phoneNumber)
                } else if tgManager.currentScreen == .enterCode {
                    tgManager.checkCode(authCode)
                } else {
                    tgManager.checkPassword(password)
                }
            }) {
                ZStack {
                    if tgManager.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Продовжити")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(tgManager.isLoading)
            .padding(.horizontal, 40)
            
            Spacer()
        }
    }
    
    private var iconName: String {
        switch tgManager.currentScreen {
        case .enterPhone: return "iphone.gen2"
        case .enterCode: return "message.fill"
        case .enterPassword: return "lock.fill"
        default: return "questionmark"
        }
    }
    
    private var titleText: String {
        switch tgManager.currentScreen {
        case .enterPhone: return "Ваш номер телефону"
        case .enterCode: return "Введіть код"
        case .enterPassword: return "Введіть пароль"
        default: return ""
        }
    }
    
    private var subtitleText: String {
        switch tgManager.currentScreen {
        case .enterPhone: return "Введіть номер для авторизації в системі"
        case .enterCode: return "Ми надіслали код у ваш додаток Telegram"
        case .enterPassword: return "У вас встановлено хмарний пароль (2FA)"
        default: return ""
        }
    }
}
