//
//  ContentView.swift
//  Podcast
//
//  Created by Shane Reid on 2/7/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            // Colorful glassy ellipses background
            Ellipse()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 300, height: 300)
                .blur(radius: 50)
                .offset(x: 150, y: -150)
            
            Ellipse()
                .fill(Color.teal.opacity(0.3))
                .frame(width: 350, height: 350)
                .blur(radius: 80)
                .offset(x: -180, y: 200)

            VStack {
                Image("Agora Email Signature")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .padding()
                // You can add a subtitle or remove the text below if not needed
                // Text("The Agora LA Podcast")
            }
        }
    }
}

#Preview {
    ContentView()
}
