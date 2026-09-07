import SwiftUI

struct ImageStudioView: View {
    @ObservedObject var generator: ImageGenerator
    @ObservedObject var modelStore: ModelStore
    @State private var prompt = "A cute baby dinosaur in a lush green meadow, soft lighting, adorable, high detail"
    @State private var negative = ""
    @State private var steps = 20
    @State private var width = 768
    @State private var height = 768
    @State private var remixPrompt = ""
    @State private var preview: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 16) {
                    composer
                    previewPanel
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Image Studio")
                    .font(.title2.bold())
                Text("Generate, remix, and remake images with the local Stable Diffusion backend.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            imageModelPicker
        }
    }

    /// A menu that switches the active image checkpoint used by the generator.
    private var imageModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image model")
                .font(.subheadline.bold())
            HStack(spacing: 8) {
                Picker("Image model", selection: Binding(
                    get: { modelStore.selectedImageModelPath ?? "" },
                    set: { newValue in
                        if !newValue.isEmpty { modelStore.selectImageModel(newValue) }
                    }
                )) {
                    Text("None selected").tag("")
                    ForEach(modelStore.installedImageModels, id: \.self) { path in
                        Text((path as NSString).lastPathComponent).tag(path)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)

                Button {
                    modelStore.addImageModelFromFile()
                } label: {
                    Image(systemName: "plus.circle").help("Add an image model from disk")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $prompt)
                .frame(height: 90)
                .padding(6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))

            Text("Negative prompt")
                .font(.headline)
            TextField("Things to avoid…", text: $negative)
                .textFieldStyle(.roundedBorder)

            HStack {
                Stepper("Steps: \(steps)", value: $steps, in: 4...60)
                Spacer()
                Picker("Size", selection: Binding(
                    get: { "\(width)×\(height)" },
                    set: { v in
                        let parts = v.split(separator: "×")
                        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                            width = w; height = h
                        }
                    }
                )) {
                    Text("512×512").tag("512×512")
                    Text("768×768").tag("768×768")
                    Text("1024×1024").tag("1024×1024")
                }
                .pickerStyle(.menu)
            }

            Button {
                generator.generate(modelPath: modelStore.selectedImageModelPath,
                                   prompt: prompt, negative: negative,
                                   width: width, height: height, steps: steps)
            } label: {
                Label("Generate image", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(generator.isGenerating)

            if generator.isGenerating {
                Button {
                    generator.cancel()
                } label: {
                    Label("Stop generating", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(!generator.isGenerating)
            }

            if generator.isGenerating {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView(value: generator.progress)
                            .progressViewStyle(.linear)
                        Text("\(Int((generator.progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    Text(generator.stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Remix / Remake on the last generated image.
            if let last = generator.lastImageURL {
                Divider()
                Text("Remix / Remake")
                    .font(.headline)
                TextField("Describe the change…", text: $remixPrompt)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Remix (img2img)") {
                        generator.remix(modelPath: modelStore.selectedImageModelPath,
                                        source: last, prompt: remixPrompt)
                    }
                    Button("Save image…") {
                        saveImage(from: last)
                    }
                }
                if !remixPrompt.isEmpty {
                    Button("Remake") {
                        generator.remix(modelPath: modelStore.selectedImageModelPath,
                                        source: last, prompt: remixPrompt)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)
            Group {
            if let url = generator.lastImageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let data = try? Data(contentsOf: url) {
                    Button("Save image…") { saveImageData(data) }
                        .buttonStyle(.bordered)
                }
            } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Generated image appears here")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        )
                }
            }
            if let err = generator.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Opt-in save of a generated image to a user-chosen location.
    private func saveImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        saveImageData(data)
    }

    private func saveImageData(_ data: Data) {
        let panel = NSSavePanel()
        panel.title = "Save generated image"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "NexusAI-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
