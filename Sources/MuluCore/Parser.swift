import Foundation

/// Parser for direct objects (§7.3). Indirect-object headers and streams are handled
/// by `PDFFile`, which knows how to resolve /Length.
///
/// The parser is iterative (explicit container stack) so that hostile input such as
/// "[[[[[[..." can never overflow the call stack, even on a 512 KB secondary thread.
///
/// Containers nested deeper than `maxDepth` are skipped (read as `null`) instead of
/// being materialised, and `truncated` is set: deeply nested values would otherwise be
/// released, compared and serialised recursively. A truncated object can still be
/// referenced (a page with a 300-level /PieceInfo), but it must never be rewritten.
struct Parser {
    var lexer: Lexer
    /// Set when some container was deeper than `maxDepth` and was skipped.
    private(set) var truncated = false

    /// Nesting limit for materialised arrays/dictionaries. Real files rarely exceed ~20.
    static let maxDepth = 256

    init(lexer: Lexer) { self.lexer = lexer }

    private struct Frame {
        var isDict: Bool
        var items: [PDFObject] = []
        var dict = PDFDict()
        var key: String? = nil  // dictionaries: the key waiting for its value
    }

    mutating func parseObject(depth: Int = 0) throws -> PDFObject {
        try parseObject(startingWith: lexer.next(), depth: depth)
    }

    mutating func parseObject(startingWith first: Token, depth: Int) throws -> PDFObject {
        var stack: [Frame] = []
        var token = first
        while true {
            var value: PDFObject
            // In a dictionary awaiting a key, a name is the key.
            if let top = stack.last, top.isDict, top.key == nil {
                switch token {
                case .name(let k):
                    stack[stack.count - 1].key = k
                    token = lexer.next()
                    continue
                case .dictEnd:
                    break  // handled below
                default:
                    // A non-name key is invalid; its value is parsed and dropped below
                    // (pdf.js does the same).
                    break
                }
            }
            switch token {
            case .integer(let n):
                // `n g R` is an indirect reference; anything else is a plain integer.
                let save = lexer.pos
                if n >= 0, case .integer(let g) = lexer.next(), g >= 0, case .keyword("R") = lexer.next() {
                    value = .ref(ObjRef(n, g))
                } else {
                    lexer.pos = save
                    value = .int(n)
                }
            case .real(let v, let lexeme):
                value = .real(v, lexeme)
            case .string(let s):
                value = .string(s)
            case .name(let n):
                value = .name(n)
            case .arrayStart, .dictStart:
                if depth + stack.count >= Parser.maxDepth {
                    try skipNested()
                    truncated = true
                    value = .null
                } else {
                    stack.append(Frame(isDict: token == .dictStart))
                    token = lexer.next()
                    continue
                }
            case .arrayEnd:
                guard let top = stack.last, !top.isDict else { throw MuluError.malformed("unbalanced ']'") }
                stack.removeLast()
                value = .array(top.items)
            case .dictEnd:
                guard var top = stack.last, top.isDict else { throw MuluError.malformed("unbalanced '>>'") }
                if let k = top.key { top.dict.appendRaw(k, .null) }  // "/Key >>": key without value
                stack.removeLast()
                value = .dict(top.dict)
            case .keyword(let k):
                switch k {
                case "true": value = .bool(true)
                case "false": value = .bool(false)
                case "null": value = .null
                default:
                    if Parser.isStructural(k) {
                        throw MuluError.malformed(stack.isEmpty ? "unexpected keyword '\(k)'" : "unexpected '\(k)' inside \(stack.last!.isDict ? "dictionary" : "array")")
                    }
                    value = .null  // unknown bare word: tolerated as null
                }
            case .eof:
                throw MuluError.malformed(stack.isEmpty ? "unexpected end of data" : "unterminated array or dictionary")
            }

            // Attach the finished value to the enclosing container, or return it.
            guard !stack.isEmpty else { return value }
            let top = stack.count - 1
            if stack[top].isDict {
                if let k = stack[top].key {
                    stack[top].dict.appendRaw(k, value)
                    stack[top].key = nil
                }
            } else {
                stack[top].items.append(value)
            }
            token = lexer.next()
        }
    }

    /// Consumes the rest of a container whose opening token was just read.
    private mutating func skipNested() throws {
        var level = 1
        while level > 0 {
            switch lexer.next() {
            case .arrayStart, .dictStart: level += 1
            case .arrayEnd, .dictEnd: level -= 1
            case .eof: throw MuluError.malformed("unterminated array or dictionary")
            case .keyword(let k) where k != "R" && Parser.isStructural(k):
                throw MuluError.malformed("unexpected '\(k)' inside a nested array or dictionary")
            default: break
            }
        }
    }

    static func isStructural(_ k: String) -> Bool {
        switch k {
        case "obj", "endobj", "stream", "endstream", "xref", "trailer", "startxref", "R": return true
        default: return false
        }
    }
}
