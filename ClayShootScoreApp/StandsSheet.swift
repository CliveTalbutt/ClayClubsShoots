import SwiftUI

/// Numeric input for the number of stands (1-25). The count is remembered per shoot by the view model.
struct StandsSheet: View {
    @Bindable var vm: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var range: ClosedRange<Int> { ShootViewModel.standOptions.first!...ShootViewModel.standOptions.last! }

    var body: some View {
        VStack(spacing: 18) {
            Text("Number of stands")
                .font(.headline)
            HStack(spacing: 16) {
                Stepper("", value: $vm.numberOfStands, in: range)
                    .labelsHidden()
                TextField("Stands", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title.bold())
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: text) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(2))
                        if digits != new { text = digits }
                        if let n = Int(digits), range.contains(n), n != vm.numberOfStands { vm.numberOfStands = n }
                    }
            }
            Text("\(range.lowerBound) to \(range.upperBound). Remembered for \(vm.shootName).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Done") { commit(); dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { text = String(vm.numberOfStands) }
        .onChange(of: vm.numberOfStands) { _, new in if text != String(new) && Int(text) != nil || text.isEmpty { text = String(new) } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let n = Int(text).map { min(max($0, range.lowerBound), range.upperBound) } ?? vm.numberOfStands
        vm.numberOfStands = n
        text = String(n)
    }
}
