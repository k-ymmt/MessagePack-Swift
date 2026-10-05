import Foundation

// MARK: - Decimal

extension MessagePackDecoding {
    /// Decodes a `Decimal` from the formats
    /// ``MessagePackDecoder/decimalDecodingStrategy`` accepts: the map of
    /// fields that `Decimal`'s own `Codable` conformance writes (through that
    /// conformance), a string of decimal digits, an integer (exactly), or a
    /// float (through its shortest decimal text, so a float 64 of 0.35
    /// decodes as 0.35 rather than 0.34999999999999997952).
    static func decodeDecimal(
        parser: inout Parser,
        context: MessagePackDecodingContext,
        codingPath: () -> [CodingKey]
    ) throws -> Decimal {
        let strategy = context.decimalDecodingStrategy
        if strategy.contains(.deferredToDecimal), let format = try? parser.peekFormat(), isMapFormat(format) {
            return try decodeWithContainers(Decimal.self, parser: &parser, context: context, codingPath: codingPath())
        }

        return try readScalarOrRewind(Decimal.self, &parser, parser.offset, codingPath) {
            (parser: inout Parser) throws(MessagePackDecodeFailure) -> Decimal in
            try readDecimal(&parser, strategy: strategy)
        }
    }

    /// Reads a string, integer, or float `Decimal` that `strategy` accepts;
    /// anything else is the wrong type.
    private static func readDecimal(
        _ parser: inout Parser, strategy: MessagePackDecoder.DecimalDecodingStrategy
    ) throws(MessagePackDecodeFailure) -> Decimal {
        if strategy.contains(.convertFromString) {
            let string: String?
            do throws(MessagePackError) {
                string = try parser.readRawString()
            } catch {
                throw .corrupted(error)
            }

            if let string {
                guard let decimal = decimal(from: string) else {
                    throw .invalid("String \"\(string)\" is not a decimal number")
                }
                return decimal
            }
        }

        if strategy.contains(.convertFromInteger) {
            let integer: MessagePackRawInteger?
            do throws(MessagePackError) {
                integer = try parser.readRawInteger()
            } catch {
                throw .corrupted(error)
            }

            switch integer {
            case .signed(let value):
                return Decimal(value)
            case .unsigned(let value):
                return Decimal(value)
            case nil:
                break
            }
        }

        if strategy.contains(.convertFromFloat) {
            // A float converts through its shortest text in the width it was
            // written in: widened to a Double first, a float 32 of 0.35 would
            // come out as 0.3499999940395355.
            let isFloat32 = (try? parser.peekFormat()) == 0xca
            let float: Double?
            do throws(MessagePackError) {
                float = try parser.readRawFloat()
            } catch {
                throw .corrupted(error)
            }

            if let float {
                let text = isFloat32 ? "\(Float(float))" : "\(float)"
                guard float.isFinite, let decimal = Decimal(string: text) else {
                    throw .invalid("Number \(float) does not fit in Decimal")
                }
                return decimal
            }
        }

        throw .wrongType
    }

    /// Parses the whole string as a decimal number in the POSIX format that
    /// `Decimal.description` produces. `Decimal(string:)` alone would accept
    /// a numeric prefix and ignore the rest ("1.5abc", "1,5").
    private static func decimal(from string: String) -> Decimal? {
        if string == "NaN" {
            return .nan
        }

        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = nil

        guard let decimal = scanner.scanDecimal(), scanner.isAtEnd else {
            return nil
        }

        return decimal
    }

    @inline(__always)
    private static func isMapFormat(_ format: UInt8) -> Bool {
        (0x80...0x8f).contains(format) || format == 0xde || format == 0xdf
    }
}
