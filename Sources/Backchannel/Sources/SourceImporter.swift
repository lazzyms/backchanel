import Foundation
import PDFKit
import Vision
import AppKit
import UniformTypeIdentifiers

/// Reads a file from disk into plain text. Markdown/text directly, PDF via PDFKit (OCR when a page has no text),
/// images via Vision OCR. Everything stays on device.
enum SourceImporter {
    static let supportedTypes: [UTType] = [.plainText, .pdf, .image, UTType("net.daringfireball.markdown") ?? .plainText]

    /// Lower-case extensions `extract` reads without guessing; watched folders import only these.
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text", "pdf", "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"]

    struct Extracted { let kind: SourceKind; let text: String }

    static func extract(from url: URL) async throws -> Extracted {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            return Extracted(kind: .markdown, text: try String(contentsOf: url, encoding: .utf8))
        case "txt", "text":
            return Extracted(kind: .text, text: try String(contentsOf: url, encoding: .utf8))
        case "pdf":
            return Extracted(kind: .pdf, text: try await pdfText(url))
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp":
            return Extracted(kind: .image, text: try await ocr(imageURL: url))
        default:
            if let s = try? String(contentsOf: url, encoding: .utf8) { return Extracted(kind: .text, text: s) }
            throw ImportError.unsupported(ext)
        }
    }

    private static func pdfText(_ url: URL) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count > 20 {
                pages.append(text)
            } else {
                let image = page.thumbnail(of: CGSize(width: 1600, height: 2000), for: .mediaBox)
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    pages.append(try await ocr(cgImage: cg))
                }
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func ocr(imageURL: URL) async throws -> String {
        guard let image = NSImage(contentsOf: imageURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ImportError.unreadable }
        let text = try await ocr(cgImage: cg)
        // Images with no readable text still get a description so they can be embedded and labelled.
        return text.isEmpty ? "Image \(imageURL.lastPathComponent) with no readable text." : text
    }

    private static func ocr(cgImage: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: cgImage)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Paragraph-aware chunks of roughly `size` characters.
    static func chunk(_ text: String, size: Int = 1200) -> [String] {
        var chunks: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if current.count + p.count > size, !current.isEmpty { chunks.append(current); current = "" }
            if p.count > size * 2 {
                // Very long paragraph: hard split.
                var rest = Substring(p)
                while !rest.isEmpty { chunks.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + p
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [String(text.prefix(size))] : chunks
    }
}

enum ImportError: Error, LocalizedError {
    case unsupported(String), unreadable
    var errorDescription: String? {
        switch self {
        case .unsupported(let e): "Unsupported file type .\(e)"
        case .unreadable: "The file could not be read."
        }
    }
}
