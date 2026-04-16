import SwiftUI
import FileProvider

class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Слухаємо подію закриття ВІКНА (на хрестик)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    // 🚨 ДОПОМІЖНА ФУНКЦІЯ: Робить бекап усіх активних дисків перед закриттям
    private func backupAllMountedDrives(completion: @escaping () -> Void) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            
            guard !domains.isEmpty else {
                completion() // Якщо немає підключених дисків — йдемо далі
                return
            }

            let group = DispatchGroup() // Чекаємо на всі відвантаження
            let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider")

            for domain in domains {
                let storageName = domain.identifier.rawValue
                let chatIdStr = sharedDefaults?.string(forKey: "ChatId_\(storageName)") ?? "0"
                
                if let chatId = Int64(chatIdStr), chatId != 0 {
                    group.enter() // Реєструємо початок завдання
                    
                    // 1. Очищаємо базу перед відправкою
                    StorageEngine.shared.switchDatabase(name: storageName)
                    StorageEngine.shared.cleanUpOrphanedFiles()
                    
                    // 2. Відправляємо в Telegram
                    print("⏳ [AppDelegate] Запуск бекапу для \(storageName)...")
                    TelegramManager.shared.performDatabaseBackup(storageName: storageName, chatId: chatId) {
                        group.leave() // Завдання завершено
                    }
                }
            }

            // Коли всі диски успішно відправлять свої бекапи
            group.notify(queue: .main) {
                completion()
            }
        }
    }

    // 1. 🚨 ЦЕ ПРАЦЮЄ КОЛИ ТИ ТИСНЕШ ХРЕСТИК (Програма залишається в Dock)
    @objc func windowWillClose(notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isKeyWindow else { return }
        print("🛑 Вікно закрито. Робимо бекап і демонтуємо диски у фоні...")
        
        backupAllMountedDrives {
            NSFileProviderManager.removeAllDomains { _ in
                DispatchQueue.global(qos: .background).async {
                    SettingsTabView.clearCacheFiles()
                }
                
                // ❌ ШКІДЛИВИЙ БЛОК З ВИДАЛЕННЯМ CHAT_ID ВИДАЛЕНО ЗВІДСИ!
                
                print("✅ Всі диски успішно демонтовано після закриття вікна.")
            }
        }
    }
    
    // Якщо ти знову клікнеш на іконку в Dock — вікно повернеться
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
    
    // 2. 🚨 ЦЕ ПРАЦЮЄ КОЛИ ТИ ТИСНЕШ "ЗАВЕРШИТИ ПОВНІСТЮ" (Cmd + Q)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("💀 Запит на повне закриття (Cmd + Q). Відправляємо фінальні бекапи...")
        
        backupAllMountedDrives {
            // Після того як файли завантажено — знімаємо диски
            NSFileProviderManager.removeAllDomains { _ in
                print("🛑 Диски знято. Зупиняємо TDLib...")
                TelegramManager.shared.shutDownSafely()
                
                DispatchQueue.main.async {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        
        return .terminateLater
    }
}
