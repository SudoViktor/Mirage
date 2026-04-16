import SwiftUI
import TDLibKit

struct WelcomeView: View {
    @StateObject private var tgManager = TelegramManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // 📦 ІКОНКА
            Image("MirageIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Color.black.opacity(0.06), radius: 24, x: 0, y: 12)
                .padding(.bottom, 14)
            
            // 📝 ГОЛОВНИЙ ЗАГОЛОВОК (Тепер тут тільки назва)
            Text("Mirage")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            
            Spacer()
            
            // 🔘 НИЖНІЙ БЛОК (Кнопка + Маленький текст)
            VStack(spacing: 16) {
                Button(action: {
                    tgManager.startAuthFlow()
                }) {
                    ZStack {
                        if tgManager.isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text("Почати використання")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 360, height: 44)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(tgManager.isLoading)
                
                // 📝 МАЛЕНЬКИЙ ОПИС ПІД КНОПКОЮ
                Text("Файлове сховище Telegram для вашого Mac")
                    .font(.caption) // Зробили меншим (приблизно 11-12pt)
                    .lineSpacing(1)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary.opacity(0.8)) // Трохи приглушили колір
            }
            .padding(.bottom, 54) // Відступ від нижнього краю вікна
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
