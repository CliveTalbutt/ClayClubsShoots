//
//  ContentView.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var vm = ShootViewModel()

    @State private var workbookToExport: ResultsWorkbook?
    @State private var isExporting = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            // Heading: the shoot name is edited in place by clicking on it, and today's
            // date is appended automatically. The name is remembered between launches.
            HStack(spacing: 8) {
                TextField("Shoot name", text: $vm.shootName)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .help("Click to edit the shoot name")

                Text("- \(Date.now.formatted(date: .long, time: .omitted))")
                    .font(.largeTitle.bold())
            }
            .padding(.top)

            addShooterControls

            ScoreTableView(vm: vm)

            if vm.isComplete {
                podiumView
            }

            statusView

            HStack {
                Button("Start Listening") {
                    vm.startListening()
                }
                .padding()
                .disabled(vm.isListening || vm.isAddingShooter || vm.shooters.isEmpty)

                Button("Stop Listening") {
                    vm.stopListening()
                }
                .padding()
                .disabled(!vm.isListening || vm.isAddingShooter)

                Button("Export to Excel") {
                    workbookToExport = ResultsWorkbook(data: vm.makeWorkbookData())
                    exportMessage = nil
                    isExporting = true
                }
                .padding()
                .disabled(vm.shooters.isEmpty)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
        }
        .frame(minWidth: 1100, minHeight: 400)
        .navigationTitle(vm.title)
        .fileExporter(
            isPresented: $isExporting,
            item: workbookToExport,
            contentTypes: [.xlsx],
            defaultFilename: vm.exportFileName,
            onCompletion: { result in
                switch result {
                case .success(let url):
                    exportMessage = "Saved results to \(url.lastPathComponent)"
                case .failure(let error):
                    exportMessage = "Export failed: \(error.localizedDescription)"
                }
            },
            onCancellation: {}
        )
    }

    // MARK: - Add shooter

    @ViewBuilder
    private var addShooterControls: some View {
        if vm.isAddingShooter {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                Text("Say the shooter's name…")
                    .foregroundStyle(.secondary)

                TextField("Shooter name", text: $vm.pendingShooterName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { vm.confirmPendingShooter() }

                Button("Add") {
                    vm.confirmPendingShooter()
                }
                .disabled(vm.pendingShooterName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Cancel") {
                    vm.cancelAddingShooter()
                }
            }
        } else {
            Button {
                vm.startAddingShooter()
            } label: {
                Label("Add Shooter", systemImage: "person.badge.plus")
            }
            .disabled(vm.isComplete)
        }
    }

    // MARK: - Results

    private var podiumView: some View {
        VStack(spacing: 6) {
            Text("Final Results")
                .font(.title2)
                .bold()

            HStack(spacing: 32) {
                ForEach(vm.podium, id: \.shooter.id) { entry in
                    VStack(spacing: 2) {
                        Text(Placing.medal(entry.place) ?? "")
                            .font(.largeTitle)
                        Text(Placing.ordinal(entry.place))
                            .font(.headline)
                        Text(entry.shooter.name.capitalized)
                        Text("\(entry.shooter.grandTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Status

    private var statusView: some View {
        VStack(spacing: 4) {
            // Listening status and the latest words heard, so the user can see
            // that the microphone is live and what the recogniser understood.
            HStack(spacing: 8) {
                Image(systemName: vm.isListening ? "mic.fill" : "mic.slash")
                    .foregroundStyle(vm.isListening ? .red : .secondary)
                Text(vm.isListening ? "Listening…" : "Not listening")
                    .foregroundStyle(.secondary)
            }

            if !vm.transcript.isEmpty {
                Text("Heard: \(vm.transcript)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal)
            }

            if let error = vm.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }
}

#Preview {
    ContentView()
}
