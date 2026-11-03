//
//  ContentView.swift
//  kopek_ios
//
//  Created by Leo Teixeira on 03/11/2026.
//

import SwiftUI
import KopekKit

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Kopek, KopekKit \(KopekKit.version)")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
