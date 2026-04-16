//
//  UnlimBoxV2App.swift
//  UnlimBoxV2
//
//  Created by Vitos on 13.04.2026.
//

import SwiftUI

@main
struct UnlimBoxV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
 
