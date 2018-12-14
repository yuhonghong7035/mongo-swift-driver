import bson
import Foundation

/// The possible types of BSON values and their corresponding integer values.
public enum BSONType: UInt32 {
    /// An invalid type
    case invalid = 0x00,
    /// 64-bit binary floating point
    double = 0x01,
    /// UTF-8 string
    string = 0x02,
    /// BSON document
    document = 0x03,
    /// Array
    array = 0x04,
    /// Binary data
    binary = 0x05,
    /// Undefined value - deprecated
    undefined = 0x06,
    /// A MongoDB ObjectId.
    /// - SeeAlso: https://docs.mongodb.com/manual/reference/method/ObjectId/
    objectId = 0x07,
    /// A boolean
    boolean = 0x08,
    /// UTC datetime, stored as UTC milliseconds since the Unix epoch
    dateTime = 0x09,
    /// Null value
    null = 0x0a,
    /// A regular expression
    regularExpression = 0x0b,
    /// A database pointer - deprecated
    dbPointer = 0x0c,
    /// Javascript code
    javascript = 0x0d,
    /// A symbol - deprecated
    symbol = 0x0e,
    /// JavaScript code w/ scope
    javascriptWithScope = 0x0f,
    /// 32-bit integer
    int32 = 0x10,
    /// Special internal type used by MongoDB replication and sharding
    timestamp = 0x11,
    /// 64-bit integer
    int64 = 0x12,
    /// 128-bit decimal floating point
    decimal128 = 0x13,
    /// Special type which compares lower than all other possible BSON element values
    minKey = 0xff,
    /// Special type which compares higher than all other possible BSON element values
    maxKey = 0x7f
}

/// A protocol all types representing `BSONType`s must implement.
public protocol BSONValue {
    /// The `BSONType` of this value.
    var bsonType: BSONType { get }

    /**
    * Given the `DocumentStorage` backing a `Document`, appends this `BSONValue` to the end.
    *
    * - Parameters:
    *   - storage: A `DocumentStorage` to write to.
    *   - key: A `String`, the key under which to store the value.
    */
    func encode(to storage: DocumentStorage, forKey key: String) throws

    /**
    * Given a `DocumentIterator` known to have a next value of this type,
    * initializes the value.
    */
    static func from(iterator iter: DocumentIterator) throws -> Self
}

/// An extension of `Array` to represent the BSON array type.
extension Array: BSONValue {

    public var bsonType: BSONType { return .array }

    public static func from(iterator iter: DocumentIterator) throws -> Array {
        var length: UInt32 = 0
        let array = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 1)
        defer {
            array.deinitialize(count: 1)
            array.deallocate()
        }
        bson_iter_array(&iter.iter, &length, array)

        // since an array is a nested object with keys '0', '1', etc.,
        // create a new Document using the array data so we can recursively parse
        guard let arrayData = bson_new_from_data(array.pointee, Int(length)) else {
            throw MongoError.bsonDecodeError(message: "Failed to create a bson_t from array data")
        }

        let arrDoc = Document(fromPointer: arrayData)

        guard let arr = arrDoc.values as? Array else {
            preconditionFailure("Failed to cast values for document \(arrDoc) to array")
        }

       return arr
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        var arr = Document()
        for (i, v) in self.enumerated() {
            guard let val = v as? BSONValue else {
                throw MongoError.invalidArgument(
                    message: "Cannot encode a non-BSONValue array element: \(String(describing: v)) "
                        + "with type: \(type(of: v)) "
                        + "at index: \(i)"
                )
            }
            try arr.setValue(for: String(i), to: val)
        }

        guard bson_append_array(storage.pointer, key, Int32(key.count), arr.data) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }
}

/// A struct to represent the BSON null type.
public struct BSONNull: BSONValue, Codable {
    public var bsonType: BSONType { return .null }

    public static func from(iterator iter: DocumentIterator) throws -> BSONNull { return BSONNull() }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_null(storage.pointer, key, Int32(key.count)) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }
}

/// A struct to represent the BSON Binary type.
public struct Binary: BSONValue, Equatable, Codable {

    public var bsonType: BSONType { return .binary }

    /// The binary data.
    public let data: Data

    /// The binary subtype for this data.
    public let subtype: UInt8

    /// Subtypes for BSON Binary values.
    public enum Subtype: UInt8 {
        /// Generic binary subtype
        case generic,
        /// A function
        function,
        /// Binary (old)
        binaryDeprecated,
        /// UUID (old)
        uuidDeprecated,
        /// UUID (RFC 4122)
        uuid,
        /// MD5
        md5,
        /// User defined
        userDefined = 0x80
    }

    /// Initializes a `Binary` instance from a `Data` object and a `UInt8` subtype.
    /// Throws an error if the provided data is incompatible with the specified subtype.
    public init(data: Data, subtype: UInt8) throws {
        if [Subtype.uuid.rawValue, Subtype.uuidDeprecated.rawValue].contains(subtype) && data.count != 16 {
            throw MongoError.invalidArgument(message:
                "Binary data with UUID subtype must be 16 bytes, but data has \(data.count) bytes")
        }
        self.subtype = subtype
        self.data = data
    }

    /// Initializes a `Binary` instance from a `Data` object and a `Subtype`.
    /// Throws an error if the provided data is incompatible with the specified subtype.
    public init(data: Data, subtype: Subtype) throws {
        try self.init(data: data, subtype: subtype.rawValue)
    }

    /// Initializes a `Binary` instance from a base64 `String` and a `UInt8` subtype.
    /// Throws an error if the base64 `String` is invalid or if the provided data is
    /// incompatible with the specified subtype.
    public init(base64: String, subtype: UInt8) throws {
        guard let dataObj = Data(base64Encoded: base64) else {
            throw MongoError.invalidArgument(message:
                "failed to create Data object from invalid base64 string \(base64)")
        }
        try self.init(data: dataObj, subtype: subtype)
    }

    /// Initializes a `Binary` instance from a base64 `String` and a `Subtype`.
    /// Throws an error if the base64 `String` is invalid or if the provided data is
    /// incompatible with the specified subtype.
    public init(base64: String, subtype: Subtype) throws {
        try self.init(base64: base64, subtype: subtype.rawValue)
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        let subtype = bson_subtype_t(UInt32(self.subtype))
        let length = self.data.count
        let byteArray = [UInt8](self.data)
        guard bson_append_binary(storage.pointer, key, Int32(key.count), subtype, byteArray, UInt32(length)) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Binary {
        var subtype = bson_subtype_t(rawValue: 0)
        var length: UInt32 = 0
        let dataPointer = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 1)
        defer {
            dataPointer.deinitialize(count: 1)
            dataPointer.deallocate()
        }
        bson_iter_binary(&iter.iter, &subtype, &length, dataPointer)

        guard let data = dataPointer.pointee else {
            throw MongoError.bsonDecodeError(message: "failed to retrieve data stored for binary BSON value")
        }

        let dataObj = Data(bytes: data, count: Int(length))
        return try self.init(data: dataObj, subtype: UInt8(subtype.rawValue))
    }

    public static func == (lhs: Binary, rhs: Binary) -> Bool {
        return lhs.data == rhs.data && lhs.subtype == rhs.subtype
    }
}

/// An extension of `Bool` to represent the BSON Boolean type.
extension Bool: BSONValue {

    public var bsonType: BSONType { return .boolean }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_bool(storage.pointer, key, Int32(key.count), self) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Bool {
        return self.init(bson_iter_bool(&iter.iter))
    }
}

/// An extension of `Date` to represent the BSON Datetime type. Supports millisecond level precision.
extension Date: BSONValue {

    public var bsonType: BSONType { return .dateTime }

    /// Initializes a new `Date` representing the instance `msSinceEpoch` milliseconds
    /// since the Unix epoch.
    public init(msSinceEpoch: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(msSinceEpoch) / 1000.0)
    }

    /// The number of milliseconds after the Unix epoch that this `Date` occurs.
    public var msSinceEpoch: Int64 { return Int64((self.timeIntervalSince1970 * 1000.0).rounded()) }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_date_time(storage.pointer, key, Int32(key.count), self.msSinceEpoch) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Date {
        return self.init(msSinceEpoch: bson_iter_date_time(&iter.iter))
    }
}

/// An internal struct to represent the deprecated DBPointer type. While DBPointers cannot
/// be created, we may need to parse them into `Document`s, and this provides a place for that logic.
internal struct DBPointer: BSONValue {

    var bsonType: BSONType { return .dbPointer }

    func encode(to storage: DocumentStorage, forKey key: String) throws {
        throw MongoError.bsonEncodeError(message: "`DBPointer`s are deprecated; use a DBRef document instead")
    }

    public static func from(iterator iter: DocumentIterator) throws -> DBPointer {
        throw MongoError.bsonDecodeError(message:
            "`DBPointer`s are deprecated; use `DBPointer.asDocument` to create a DBRef document instead")
    }

    /// Reads DBPointer data from `iter` and converts it to DBRef format
    static func asDocument(from iter: DocumentIterator) throws -> Document {
        var length: UInt32 = 0
        let collectionPP = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(capacity: 1)
        defer {
            collectionPP.deinitialize(count: 1)
            collectionPP.deallocate()
        }

        let oidPP = UnsafeMutablePointer<UnsafePointer<bson_oid_t>?>.allocate(capacity: 1)
        defer {
            oidPP.deinitialize(count: 1)
            oidPP.deallocate()
        }

        bson_iter_dbpointer(&iter.iter, &length, collectionPP, oidPP)

        guard let oidP = oidPP.pointee else {
            throw MongoError.bsonDecodeError(message:
                retrieveErrorMsg(type: "DBPointer ObjectId", key: iter.currentKey))
        }
        guard let collectionP = collectionPP.pointee else {
            throw MongoError.bsonDecodeError(message:
                retrieveErrorMsg(type: "DBPointer collection name", key: iter.currentKey))
        }

        return [
            "$ref": String(cString: collectionP),
            "$id": ObjectId(fromPointer: oidP)
        ]
    }
}

/// A struct to represent the BSON Decimal128 type.
public struct Decimal128: BSONValue, Equatable, Codable {
    /// This number, represented as a `String`.
    public let data: String

    public var bsonType: BSONType { return .decimal128 }

    /// Initializes a `Decimal128` value from the provided `String`. Assumes that the input string is correctly
    /// formatted.
    /// - SeeAlso: https://github.com/mongodb/specifications/blob/master/source/bson-decimal128/decimal128.rst
    public init(_ data: String) {
        self.data = data
    }

    /// Initializes a `Decimal128` value from the provided `String`. Returns `nil` if the input is not a valid
    /// Decimal128 string. Note that this initializer is less performant than the non-failable initializer `init(_:)`.
    /// - SeeAlso: https://github.com/mongodb/specifications/blob/master/source/bson-decimal128/decimal128.rst
    public init?(ifValid data: String) {
        do {
            _ = try Decimal128.toLibBSONType(data)
            self.init(data)
        } catch {
            return nil
        }
    }

    /// Returns the provided string as a `bson_decimal128_t`, or throws an error if initialization fails due an
    /// invalid string.
    internal static func toLibBSONType(_ str: String) throws -> bson_decimal128_t {
        var value = bson_decimal128_t()
        guard bson_decimal128_from_string(str, &value) else {
            throw MongoError.bsonEncodeError(message: "Invalid Decimal128 string \(str)")
        }
        return value
    }

    public static func == (lhs: Decimal128, rhs: Decimal128) -> Bool {
        return lhs.data == rhs.data
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        var value = try Decimal128.toLibBSONType(self.data)
        guard bson_append_decimal128(storage.pointer, key, Int32(key.count), &value) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Decimal128 {
        var value = bson_decimal128_t()
        guard bson_iter_decimal128(&iter.iter, &value) else {
            throw MongoError.bsonDecodeError(message: "Failed to retrieve Decimal128 value from iterator")
        }

        var str = Data(count: Int(BSON_DECIMAL128_STRING))
        return self.init(str.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) in
            bson_decimal128_to_string(&value, bytes)
            return String(cString: bytes)
        })
     }

}

/// An extension of `Double` to represent the BSON Double type.
extension Double: BSONValue {

    public var bsonType: BSONType { return .double }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_double(storage.pointer, key, Int32(key.count), self) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Double {
        return self.init(bson_iter_double(&iter.iter))
    }
}

/// An extension of `Int` to represent the BSON Int32 or Int64 type.
/// The `Int` will be encoded as an Int32 if possible, or an Int64 if necessary.
extension Int: BSONValue {

    public var bsonType: BSONType { return self.int32Value != nil ? .int32 : .int64 }

    internal var int32Value: Int32? { return Int32(exactly: self) }
    internal var int64Value: Int64? { return Int64(exactly: self) }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        if let int32 = self.int32Value {
            return try int32.encode(to: storage, forKey: key)
        }
        if let int64 = self.int64Value {
            return try int64.encode(to: storage, forKey: key)
        }

        throw MongoError.bsonEncodeError(message: "`Int` value \(self) could not be encoded as `Int32` or `Int64`")
    }

    public static func from(iterator iter: DocumentIterator) throws -> Int {
        return self.init(Int(bson_iter_int32(&iter.iter)))
    }
}

/// An extension of `Int32` to represent the BSON Int32 type.
extension Int32: BSONValue {

    public var bsonType: BSONType { return .int32 }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_int32(storage.pointer, key, Int32(key.count), self) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Int32 {
        return self.init(bson_iter_int32(&iter.iter))
    }
}

/// An extension of `Int64` to represent the BSON Int64 type.
extension Int64: BSONValue {

    public var bsonType: BSONType { return .int64 }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_int64(storage.pointer, key, Int32(key.count), self) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Int64 {
        return self.init(bson_iter_int64(&iter.iter))
    }
}

/// A struct to represent the BSON Code and CodeWithScope types.
public struct CodeWithScope: BSONValue, Equatable, Codable {
    /// A string containing Javascript code.
    public let code: String
    /// An optional scope `Document` containing a mapping of identifiers to values,
    /// representing the context in which `code` should be evaluated.
    public let scope: Document?

    public var bsonType: BSONType {
        return self.scope == nil ? .javascript : .javascriptWithScope
    }

    /// Initializes a `CodeWithScope` with an optional scope value.
    public init(code: String, scope: Document? = nil) {
        self.code = code
        self.scope = scope
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        if let s = self.scope {
            guard bson_append_code_with_scope(storage.pointer, key, Int32(key.count), self.code, s.data) else {
                throw bsonEncodeError(value: self, forKey: key)
            }
        } else {
            guard bson_append_code(storage.pointer, key, Int32(key.count), self.code) else {
                throw bsonEncodeError(value: self, forKey: key)
            }
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> CodeWithScope {

        var length: UInt32 = 0

        if iter.currentType.rawValue == BSONType.javascript.rawValue {
            let code = String(cString: bson_iter_code(&iter.iter, &length))
            return self.init(code: code)
        }

        var scopeLength: UInt32 = 0
        let scopePointer = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 1)
        defer {
            scopePointer.deinitialize(count: 1)
            scopePointer.deallocate()
        }

        let code = String(cString: bson_iter_codewscope(&iter.iter, &length, &scopeLength, scopePointer))
        guard let scopeData = bson_new_from_data(scopePointer.pointee, Int(scopeLength)) else {
            throw MongoError.bsonDecodeError(message: "Failed to create a bson_t from scope data")
        }
        let scopeDoc = Document(fromPointer: scopeData)

        return self.init(code: code, scope: scopeDoc)
    }

    public static func == (lhs: CodeWithScope, rhs: CodeWithScope) -> Bool {
        return lhs.code == rhs.code && lhs.scope == rhs.scope
    }
}

/// A struct to represent the BSON MaxKey type.
public struct MaxKey: BSONValue, Equatable, Codable {

    private var maxKey = 1

    public var bsonType: BSONType { return .maxKey }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_maxkey(storage.pointer, key, Int32(key.count)) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    /// Initializes a new `MaxKey` instance.
    public init() {}

    public static func from(iterator iter: DocumentIterator) -> MaxKey { return self.init() }

    public static func == (lhs: MaxKey, rhs: MaxKey) -> Bool { return true }
}

/// A struct to represent the BSON MinKey type.
public struct MinKey: BSONValue, Equatable, Codable {

    private var minKey = 1

    public var bsonType: BSONType { return .minKey }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_minkey(storage.pointer, key, Int32(key.count)) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    /// Initializes a new `MinKey` instance.
    public init() {}

    public static func from(iterator iter: DocumentIterator) -> MinKey { return self.init() }

    public static func == (lhs: MinKey, rhs: MinKey) -> Bool { return true }
}

/// A struct to represent the BSON ObjectId type.
public struct ObjectId: BSONValue, Equatable, CustomStringConvertible, Codable {

    public var bsonType: BSONType { return .objectId }

    /// This `ObjectId`'s data represented as a `String`.
    public let oid: String

    /// The timestamp used to create this `ObjectId`
    public let timestamp: UInt32

    /// Initializes a new `ObjectId`.
    public init() {
        var oid_t = bson_oid_t()
        bson_oid_init(&oid_t, nil)
        self.init(fromPointer: &oid_t)
    }

    /// Initializes an `ObjectId` from the provided `String`. Assumes that the given string is a valid ObjectId.
    /// - SeeAlso: https://github.com/mongodb/specifications/blob/master/source/objectid.rst
    public init(fromString oid: String) {
        self.oid = oid
        var oid_t = bson_oid_t()
        bson_oid_init_from_string(&oid_t, oid)
        self.timestamp = UInt32(bson_oid_get_time_t(&oid_t))
    }

    /// Initializes an `ObjectId` from the provided `String`. Returns `nil` if the string is not a valid
    /// ObjectId.
    /// - SeeAlso: https://github.com/mongodb/specifications/blob/master/source/objectid.rst
    public init?(ifValid oid: String) {
        if !bson_oid_is_valid(oid, oid.count) {
            return nil
        } else {
            self.init(fromString: oid)
        }
    }

    /// Initializes an `ObjectId` from an `UnsafePointer<bson_oid_t>` by copying the data
    /// from it to a `String`
    internal init(fromPointer oid_t: UnsafePointer<bson_oid_t>) {
        var str = Data(count: 25)
        self.oid = str.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) in
            bson_oid_to_string(oid_t, bytes)
            return String(cString: bytes)
        }
        self.timestamp = UInt32(bson_oid_get_time_t(oid_t))
    }

    /// Returns the provided string as a `bson_oid_t`.
    internal static func toLibBSONType(_ str: String) throws -> bson_oid_t {
        var value = bson_oid_t()
        if !bson_oid_is_valid(str, str.count) {
            throw MongoError.invalidArgument(message: "ObjectId string is invalid")
        }
        bson_oid_init_from_string(&value, str)
        return value
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        // create a new bson_oid_t with self.oid
        var oid = try ObjectId.toLibBSONType(self.oid)
        // encode the bson_oid_t to the bson_t
        guard bson_append_oid(storage.pointer, key, Int32(key.count), &oid) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> ObjectId {
        guard let oid = bson_iter_oid(&iter.iter) else {
            throw MongoError.bsonDecodeError(message: "Failed to retrieve ObjectID value")
        }
        return self.init(fromPointer: oid)
    }

    public var description: String {
        return self.oid
    }

    public static func == (lhs: ObjectId, rhs: ObjectId) -> Bool {
        return lhs.oid == rhs.oid
    }

}

// A mapping of regex option characters to their equivalent `NSRegularExpression` option.
// note that there is a BSON regexp option 'l' that `NSRegularExpression`
// doesn't support. The flag will be dropped if BSON containing it is parsed,
// and it will be ignored if passed into `optionsFromString`.
let regexOptsMap: [Character: NSRegularExpression.Options] = [
    "i": .caseInsensitive,
    "m": .anchorsMatchLines,
    "s": .dotMatchesLineSeparators,
    "u": .useUnicodeWordBoundaries,
    "x": .allowCommentsAndWhitespace
]

/// An extension of `NSRegularExpression` to support converting options to and from strings.
extension NSRegularExpression {

    /// Convert a string of options flags into an equivalent `NSRegularExpression.Options`
    static func optionsFromString(_ stringOptions: String) -> NSRegularExpression.Options {
        var optsObj: NSRegularExpression.Options = []
        for o in stringOptions {
            if let value = regexOptsMap[o] {
                 optsObj.update(with: value)
            }
        }
        return optsObj
    }

    /// Convert this instance's options object into an alphabetically-sorted string of characters
    public var stringOptions: String {
        var optsString = ""
        for (char, o) in regexOptsMap { if options.contains(o) { optsString += String(char) } }
        return String(optsString.sorted())
    }
}

/// A struct to represent a BSON regular expression.
public struct RegularExpression: BSONValue, Equatable, Codable {

    public var bsonType: BSONType { return .regularExpression }

    /// The pattern for this regular expression.
    public let pattern: String
    /// A string containing options for this regular expression.
    /// - SeeAlso: https://docs.mongodb.com/manual/reference/operator/query/regex/#op
    public let options: String

    /// Initializes a new `RegularExpression` with the provided pattern and options.
    public init(pattern: String, options: String) {
        self.pattern = pattern
        self.options = String(options.sorted())
    }

    /// Initializes a new `RegularExpression` with the pattern and options of the provided `NSRegularExpression`.
    public init(from regex: NSRegularExpression) {
        self.pattern = regex.pattern
        self.options = regex.stringOptions
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_regex(storage.pointer, key, Int32(key.count), self.pattern, self.options) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> RegularExpression {
        let options = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(capacity: 1)
        defer {
            options.deinitialize(count: 1)
            options.deallocate()
        }

        guard let pattern = bson_iter_regex(&iter.iter, options) else {
            throw MongoError.bsonDecodeError(message: "Failed to retrieve regular expression pattern")
        }
        let patternString = String(cString: pattern)

        guard let stringOptions = options.pointee else {
            throw MongoError.bsonDecodeError(message: "Failed to retrieve regular expression options")
        }
        let optionsString = String(cString: stringOptions)

        return self.init(pattern: patternString, options: optionsString)
    }

    /// Creates an `NSRegularExpression` with the pattern and options of this `RegularExpression`.
    /// Note: `NSRegularExpression` does not support the `l` locale dependence option, so it will
    /// be omitted if set on this `RegularExpression`.
    public var nsRegularExpression: NSRegularExpression {
        let opts = NSRegularExpression.optionsFromString(self.options)
        do {
            return try NSRegularExpression(pattern: self.pattern, options: opts)
        } catch {
            preconditionFailure("Failed to initialize NSRegularExpression with " +
                "pattern '\(self.pattern)'' and options '\(self.options)'")
        }
    }

    /// Returns `true` if the two `RegularExpression`s have matching patterns and options, and `false` otherwise.
    public static func == (lhs: RegularExpression, rhs: RegularExpression) -> Bool {
        return lhs.pattern == rhs.pattern && lhs.options == rhs.options
    }
}

/// An extension of String to represent the BSON string type.
extension String: BSONValue {

    public var bsonType: BSONType { return .string }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_utf8(storage.pointer, key, Int32(key.count), self, Int32(self.count)) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> String {
        var length: UInt32 = 0
        guard let strValue = bson_iter_utf8(&iter.iter, &length) else {
           throw MongoError.bsonDecodeError(message: retrieveErrorMsg(type: "UTF-8", key: iter.currentKey))
        }
        return self.init(cString: strValue)
    }
}

/// An internal struct to represent the deprecated Symbol type. While Symbols cannot be
/// created, we may need to parse them into `String`s, and this provides a place for that logic.
internal struct Symbol: BSONValue {

    var bsonType: BSONType { return .symbol }

    func encode(to storage: DocumentStorage, forKey key: String) throws {
        throw MongoError.bsonEncodeError(message: "Symbols are deprecated; use a string instead")
    }

    public static func from(iterator iter: DocumentIterator) throws -> Symbol {
        throw MongoError.bsonDecodeError(message:
            "`Symbol`s are deprecated; use `Symbol.asString` to parse as a string instead")

    }

    static func asString(from iter: DocumentIterator) throws -> String {
        var length: UInt32 = 0
        guard let strValue = bson_iter_symbol(&iter.iter, &length) else {
            throw MongoError.bsonDecodeError(message: retrieveErrorMsg(type: "Symbol", key: iter.currentKey))
        }
        return String(cString: strValue)
    }
}

/// A struct to represent the BSON Timestamp type.
public struct Timestamp: BSONValue, Equatable, Codable {

    public var bsonType: BSONType { return .timestamp }

    /// A timestamp representing seconds since the Unix epoch.
    public let timestamp: UInt32
    /// An incrementing ordinal for operations within a given second.
    public let increment: UInt32

    /// Initializes a new  `Timestamp` with the provided `timestamp` and `increment` values.
    public init(timestamp: UInt32, inc: UInt32) {
        self.timestamp = timestamp
        self.increment = inc
    }

    /// Initializes a new  `Timestamp` with the provided `timestamp` and `increment` values. Assumes
    /// the values can successfully be converted to `UInt32`s without loss of precision.
    public init(timestamp: Int, inc: Int) {
        self.timestamp = UInt32(timestamp)
        self.increment = UInt32(inc)
    }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_timestamp(storage.pointer, key, Int32(key.count), self.timestamp, self.increment) else {
            throw bsonEncodeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Timestamp {
        var t: UInt32 = 0
        var i: UInt32 = 0
        bson_iter_timestamp(&iter.iter, &t, &i)
        return self.init(timestamp: t, inc: i)
    }

    public static func == (lhs: Timestamp, rhs: Timestamp) -> Bool {
        return lhs.timestamp == rhs.timestamp && lhs.increment == rhs.increment
    }
}

// See https://github.com/realm/SwiftLint/issues/461
// swiftlint:disable cyclomatic_complexity
/**
 *  A helper function to test equality between two `BSONValue`s. This function tests for exact BSON equality.
 *  This means that differing types with equivalent value are not equivalent.
 *
 *  e.g.
 *      4.0 (Double) != 4 (Int)
 *
 *  NOTE: This function will always return `false` if it is used with two arrays that are not of the type `[BSONValue]`,
 *  because only arrays composed of solely `BSONValue`s are valid BSON arrays.
 *
 *  * - Parameters:
 *   - lhs: The left-hand-side `BSONValue` to compare.
 *   - rhs: The right-hand-side `BSONValue` to compare.
 *
 * - Returns: `true` if `lhs` is equal to `rhs`, `false` otherwise.
 */
func bsonEquals(_ lhs: BSONValue, _ rhs: BSONValue) -> Bool {
    validateBSONTypes(lhs, rhs)

    switch (lhs, rhs) {
    case (let l as Int, let r as Int): return l == r
    case (let l as Int32, let r as Int32): return l == r
    case (let l as Int64, let r as Int64): return l == r
    case (let l as Double, let r as Double): return l == r
    case (let l as Decimal128, let r as Decimal128): return l == r
    case (let l as Bool, let r as Bool): return l == r
    case (let l as String, let r as String): return l == r
    case (let l as RegularExpression, let r as RegularExpression): return l == r
    case (let l as Timestamp, let r as Timestamp): return l == r
    case (let l as Date, let r as Date): return l == r
    case (_ as MinKey, _ as MinKey): return true
    case (_ as MaxKey, _ as MaxKey): return true
    case (let l as ObjectId, let r as ObjectId): return l == r
    case (let l as CodeWithScope, let r as CodeWithScope): return l == r
    case (let l as Binary, let r as Binary): return l == r
    case (_ as BSONNull, _ as BSONNull): return true
    case (let l as Document, let r as Document): return l == r
    case (let l as [BSONValue], let r as [BSONValue]): // TODO: SWIFT-242
        return zip(l, r).reduce(true, {prev, next in bsonEquals(next.0, next.1) && prev})
    case (_ as [Any], _ as [Any]): return false
    default: return false
    }
}

/**
 *  A helper function to test equality between two BSONValue?s. See bsonEquals for BSONValues (non-optional) for more
 *  information.
 *
 *  * - Parameters:
 *   - lhs: The left-hand-side BSONValue? to compare.
 *   - rhs: The right-hand-side BSONValue? to compare.
 *
 * - Returns: True if lhs is equal to rhs, false otherwise.
 */
public func bsonEquals(_ lhs: BSONValue?, _ rhs: BSONValue?) -> Bool {
    guard let left = lhs, let right = rhs else {
        return lhs == nil && rhs == nil
    }

    return bsonEquals(left, right)
}

/// A function for catching invalid BSONTypes that should not ever arise, and triggering a preconditionFailure when it
/// finds such types.
private func validateBSONTypes(_ lhs: BSONValue, _ rhs: BSONValue) {
    let invalidTypes: [BSONType] = [.symbol, .dbPointer, .invalid, .undefined]
    guard !invalidTypes.contains(lhs.bsonType) else {
        preconditionFailure("\(lhs.bsonType) should not be used")
    }
    guard !invalidTypes.contains(rhs.bsonType) else {
        preconditionFailure("\(rhs.bsonType) should not be used")
    }
}

func retrieveErrorMsg(type: String, key: String) -> String {
    return "Failed to retrieve the \(type) value for key '\(key)'"
}
