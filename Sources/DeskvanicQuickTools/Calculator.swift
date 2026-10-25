import Foundation
import DeskvanicCore

/// 表达式计算器：递归下降解析为 AST 后求值（无 eval）。
/// 支持 + - * / % ^ 括号、一元负号、常量 pi/e、函数、科学计数法。
public enum Calculator {

    // MARK: - AST

    indirect enum Node {
        case number(Double)
        case unary(op: String, operand: Node)
        case binary(op: String, lhs: Node, rhs: Node)
        case call(name: String, argument: Node)
    }

    // MARK: - 公开接口

    /// 双精度求值。除零、溢出、非有限结果报错。
    public static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(tokens: tokenize(expression))
        let node = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw DeskvanicError(.invalidInput, "表达式存在多余内容：\(parser.peekDescription)")
        }
        let value = try evaluateNode(node)
        guard value.isFinite else {
            throw DeskvanicError(.invalidInput, "结果不是有限数（溢出或除零）")
        }
        return value
    }

    /// Decimal 精确四则（适合金额）。不支持函数与幂运算。
    public static func evaluateDecimal(_ expression: String) throws -> Decimal {
        var parser = Parser(tokens: tokenize(expression))
        let node = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw DeskvanicError(.invalidInput, "表达式存在多余内容：\(parser.peekDescription)")
        }
        let value = try decimalEval(node)
        return value
    }

    // MARK: - 词法

    enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(String)
        case lparen, rparen
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var numberText = ""
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "."
                      || (characters[index] == "e" || characters[index] == "E") {
                    // 科学计数法：e 后可带符号
                    if characters[index] == "e" || characters[index] == "E" {
                        let next = index + 1
                        guard next < characters.count,
                              characters[next].isNumber
                              || characters[next] == "+"
                              || characters[next] == "-",
                              numberText.contains(where: { $0.isNumber }) else { break }
                        numberText.append(characters[index])
                        index += 1
                        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                            numberText.append(characters[index])
                            index += 1
                        }
                        continue
                    }
                    numberText.append(characters[index])
                    index += 1
                }
                if let value = Double(numberText) {
                    tokens.append(.number(value))
                }
                continue
            }
            if character.isLetter {
                var name = ""
                // 标识符可含数字：log2、log10 等
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber {
                    name.append(characters[index])
                    index += 1
                }
                tokens.append(.identifier(name.lowercased()))
                continue
            }
            switch character {
            case "+", "-", "*", "/", "%", "^": tokens.append(.op(String(character)))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: break  // 忽略未知字符（由解析阶段报错兜底）
            }
            index += 1
        }
        return tokens
    }

    // MARK: - 解析（优先级：unary > ^ > * / % > + -）

    struct Parser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        var peekDescription: String {
            if let token = peek() { return "\(token)" }
            return "表达式结尾"
        }

        mutating func advance() -> Token? {
            guard position < tokens.count else { return nil }
            let token = tokens[position]
            position += 1
            return token
        }

        mutating func parseExpression() throws -> Node {
            try parseAdditive()
        }

        mutating func parseAdditive() throws -> Node {
            var lhs = try parseMultiplicative()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                _ = advance()
                let rhs = try parseMultiplicative()
                lhs = .binary(op: op, lhs: lhs, rhs: rhs)
            }
            return lhs
        }

        mutating func parseMultiplicative() throws -> Node {
            var lhs = try parsePower()
            while case .op(let op)? = peek(), op == "*" || op == "/" || op == "%" {
                _ = advance()
                let rhs = try parsePower()
                lhs = .binary(op: op, lhs: lhs, rhs: rhs)
            }
            return lhs
        }

        mutating func parsePower() throws -> Node {
            let base = try parseUnary()
            if case .op("^")? = peek() {
                _ = advance()
                let exponent = try parsePower()  // 右结合
                return .binary(op: "^", lhs: base, rhs: exponent)
            }
            return base
        }

        mutating func parseUnary() throws -> Node {
            if case .op(let op)? = peek(), op == "-" || op == "+" {
                _ = advance()
                let operand = try parseUnary()
                return .unary(op: op, operand: operand)
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Node {
            guard let token = advance() else {
                throw DeskvanicError(.invalidInput, "表达式意外结束")
            }
            switch token {
            case .number(let value):
                return .number(value)
            case .identifier(let name):
                if name == "pi" { return .number(Double.pi) }
                if name == "e" { return .number(M_E) }
                guard Self.functions.keys.contains(name) else {
                    throw DeskvanicError(.invalidInput, "未知函数或常量：\(name)")
                }
                guard case .lparen? = advance() else {
                    throw DeskvanicError(.invalidInput, "函数 \(name) 后必须是左括号")
                }
                let argument = try parseExpression()
                guard case .rparen? = advance() else {
                    throw DeskvanicError(.invalidInput, "函数 \(name) 缺少右括号")
                }
                return .call(name: name, argument: argument)
            case .lparen:
                let inner = try parseExpression()
                guard case .rparen? = advance() else {
                    throw DeskvanicError(.invalidInput, "缺少右括号")
                }
                return inner
            case .op, .rparen:
                throw DeskvanicError(.invalidInput, "意外的符号：\(token)")
            }
        }

        static let functions: [String: @Sendable (Double) throws -> Double] = [
            "sqrt": { value in
                guard value >= 0 else {
                    throw DeskvanicError(.invalidInput, "sqrt 的参数必须非负")
                }
                return sqrt(value)
            },
            "sin": { sin($0) },
            "cos": { cos($0) },
            "tan": { tan($0) },
            "log": { value in
                guard value > 0 else {
                    throw DeskvanicError(.invalidInput, "log 的参数必须为正")
                }
                return log(value)
            },
            "log2": { value in
                guard value > 0 else {
                    throw DeskvanicError(.invalidInput, "log2 的参数必须为正")
                }
                return log2(value)
            },
            "log10": { value in
                guard value > 0 else {
                    throw DeskvanicError(.invalidInput, "log10 的参数必须为正")
                }
                return log10(value)
            },
            "abs": { abs($0) },
            "exp": { exp($0) },
        ]
    }

    // MARK: - 求值

    static func evaluateNode(_ node: Node) throws -> Double {
        switch node {
        case .number(let value):
            return value
        case .unary(let op, let operand):
            let value = try evaluateNode(operand)
            return op == "-" ? -value : value
        case .binary(let op, let lhs, let rhs):
            let l = try evaluateNode(lhs)
            let r = try evaluateNode(rhs)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/":
                guard r != 0 else {
                    throw DeskvanicError(.invalidInput, "除数不能为零")
                }
                return l / r
            case "%":
                guard r != 0 else {
                    throw DeskvanicError(.invalidInput, "取模的除数不能为零")
                }
                return l.truncatingRemainder(dividingBy: r)
            case "^": return pow(l, r)
            default: throw DeskvanicError(.invalidInput, "未知运算符：\(op)")
            }
        case .call(let name, let argument):
            let function = Parser.functions[name]
            guard let function else {
                throw DeskvanicError(.invalidInput, "未知函数：\(name)")
            }
            return try function(try evaluateNode(argument))
        }
    }

    static func decimalEval(_ node: Node) throws -> Decimal {
        switch node {
        case .number(let value):
            return Decimal(string: "\(value)") ?? Decimal(value)
        case .unary(let op, let operand):
            let value = try decimalEval(operand)
            return op == "-" ? -value : value
        case .binary(let op, let lhs, let rhs):
            let l = try decimalEval(lhs)
            let r = try decimalEval(rhs)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/":
                guard r != 0 else {
                    throw DeskvanicError(.invalidInput, "除数不能为零")
                }
                return l / r
            case "%", "^":
                throw DeskvanicError(.invalidInput, "Decimal 模式不支持 \(op) 运算")
            default: throw DeskvanicError(.invalidInput, "未知运算符：\(op)")
            }
        case .call:
            throw DeskvanicError(.invalidInput, "Decimal 模式不支持函数")
        }
    }
}
