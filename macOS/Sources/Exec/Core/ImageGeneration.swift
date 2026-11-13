import Foundation

enum ImageGenerationTool {
    static let interrupted = "Image generation did not complete locally. The provider may have generated an image and charged subscription quota. No completed image result was durably recorded; a managed image file may remain if local saving was interrupted. No automatic retry was made. Do not retry without a new user request."
}
