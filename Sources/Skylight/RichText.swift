import AppKit
import SwiftUI

/// Renders assistant output the way the ChatGPT app does: markdown prose with
/// fenced code blocks lifted into monospaced cards that carry a language tag
/// and a copy button.
struct RichMessageText: View {
    let text: String

    private enum Segment: Identifiable {
        case prose(String, UUID = UUID())
        case code(language: String, body: String, id: UUID = UUID())

        var id: UUID {
            switch self {
            case let .prose(_, id): id
            case let .code(_, _, id): id
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var prose = ""
        var inCode = false
        var codeLanguage = ""
        var code = ""

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLanguage,
                                        body: code.trimmingCharacters(in: .newlines)))
                    code = ""
                    inCode = false
                } else {
                    if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(.prose(prose.trimmingCharacters(in: .newlines)))
                    }
                    prose = ""
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                code += line + "\n"
            } else {
                prose += line + "\n"
            }
        }
        if inCode, !code.isEmpty {
            // Unterminated fence mid-stream: show it as code anyway.
            result.append(.code(language: codeLanguage, body: code.trimmingCharacters(in: .newlines)))
        } else if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.prose(prose.trimmingCharacters(in: .newlines)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                switch segment {
                case let .prose(text, _):
                    Text(LocalizedStringKey(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(language, body, _):
                    CodeBlock(language: language, code: body)
                }
            }
        }
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.pressable(scale: 0.94))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }
}
