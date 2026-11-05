import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor struct ImageAttachmentTests {
    private func fixture(width: Int = 32) throws -> Data {
        let context = CGContext(data: nil, width: width, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func normalizesAndRejectsInvalidDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Screenshot.png")
        try fixture(width: 3_000).write(to: url)
        let image = try ImageDrop.loadFile(url)
        let source = CGImageSourceCreateWithData(image.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        try expect(properties[kCGImagePropertyPixelWidth] as? Int == 2_048)
        try expect(image.mediaType == "image/jpeg" && image.name == "Screenshot.png")
        let fileProvider = NSItemProvider(contentsOf: url)!
        let fileImages = try await ImageDrop.load([fileProvider])
        try expect(fileImages.count == 1 && fileImages[0].data == image.data)
        let provider = NSItemProvider(item: try fixture() as NSData, typeIdentifier: UTType.png.identifier)
        let rawImages = try await ImageDrop.load([provider])
        try expect(rawImages.count == 1)
        try expectFailure { _ = try ImageDrop.normalize(Data("not an image".utf8), name: "fake.png") }
        try expectFailure { _ = try ImageDrop.loadFile(root) }
        try expectFailure { _ = try ImageDrop.normalize(Data(count: ImageDrop.maximumSourceBytes + 1), name: "huge") }
        try expectFailure { try ImageAttachment.validate(Array(repeating: image, count: 5)) }
    }

    func wireFormatAndLegacyDecoding() throws {
        let image = try ImageDrop.normalize(fixture(), name: "Example.png")
        let message = Message(role: .user, text: "What is this?", images: [image])
        let input = try CodexConversationState().input([message])
        let content = input[0]["content"] as! [[String: Any]]
        try expect(content[0]["type"] as? String == "input_text")
        try expect(content[1]["type"] as? String == "input_image")
        try expect(content[1]["image_url"] as? String == "data:\(image.mediaType);base64,\(image.data.base64EncodedString())")
        let onlyImage = try CodexConversationState().input([Message(role: .user, text: "", images: [image])])
        try expect((onlyImage[0]["content"] as? [[String: Any]])?.count == 1)
        try expect(try CodexConversationState.estimate(input) >= 4_096)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        legacy.removeValue(forKey: "images")
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(decoded.images.isEmpty && decoded.text == message.text)
        let large = ImageAttachment(name: "Large", mediaType: "image/jpeg", data: Data(count: 1_000_000))
        let largeInput = try CodexConversationState().input([Message(role: .user, text: "", images: [large])])
        try expect(try CodexConversationState.estimate(largeInput) < 5_000)
    }

    func sendsPersistsAndExcludesFailedImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        store.selectedModel = "test"
        let image = try ImageDrop.normalize(fixture(), name: "Example.png")
        store.draftImages = [image]
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && store.draftImages.isEmpty)
        try expect(provider.inputs[0][0].text.isEmpty && provider.inputs[0][0].images == [image])
        let saved = try await sessions.load(id: store.currentSessionID)
        try expect(saved?.messages[0].images == [image] && saved?.history[0].images == [image])
        let restoredProvider = FakeProvider()
        let restored = ChatStore(provider: restoredProvider, sessions: sessions)
        restored.restore()
        await restored.waitUntilIdle()
        restored.draft = "Describe it again"
        restored.send()
        await restored.waitUntilIdle()
        try expect(restoredProvider.inputs.last?.first?.images == [image])
        provider.shouldFail = true
        store.draftImages = [image]
        store.send()
        await store.waitUntilIdle()
        let failedID = store.messages.last(where: { $0.role == .user })!.id
        provider.shouldFail = false
        store.draft = "Continue"
        store.send()
        await store.waitUntilIdle()
        try expect(provider.inputs.last?.contains(where: { $0.id == failedID }) == false)
    }

    func pendingDropsStayWithOriginalConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root))
        library.restore()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstID = first.currentSessionID!
        let image = try ImageDrop.normalize(fixture(), name: "Example.png")
        var finish: CheckedContinuation<[ImageAttachment], Never>?
        let importing = first.importImages {
            await withCheckedContinuation { finish = $0 }
        }!
        try await wait { finish != nil }
        try expect(library.hasUnsentDrafts)
        first.draft = "Wait for image"
        first.send()
        try expect(!first.busy && provider.children[0].inputs.isEmpty)
        first.draft = ""
        library.newConversation()
        try await wait { !library.navigating }
        finish?.resume(returning: [image])
        await importing.value
        try expect(library.current.draftImages.isEmpty && first.draftImages == [image])
        library.openSession(firstID)
        try await wait { !library.navigating }
        try expect(library.current === first && library.hasUnsentDrafts)
        let rejected = first.importImages { Array(repeating: image, count: 4) }!
        await rejected.value
        try expect(first.draftImages == [image] && first.error != nil)
        first.draftImages.removeAll()
        try expect(!library.hasUnsentDrafts)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Image operation did not settle")
    }
}
