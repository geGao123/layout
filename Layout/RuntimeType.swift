//  Copyright © 2017 Schibsted. All rights reserved.

import UIKit

func sanitizedStructName(_ objCType: String) -> String {
    guard let equalRange = objCType.range(of: "="),
        let braceRange = objCType.range(of: "{") else {
        return objCType
    }
    let name: String = String(objCType[braceRange.upperBound ..< equalRange.lowerBound])
    switch name {
    case "_NSRange":
        return "NSRange" // Yay! special cases
    default:
        return name
    }
}

public class RuntimeType: NSObject {

    public enum Kind: Equatable, CustomStringConvertible {
        case any(Any.Type)
        case `class`(AnyClass)
        case `struct`(String)
        case pointer(String)
        case `protocol`(Protocol)
        case `enum`(Any.Type, [String: Any])

        public static func ==(lhs: Kind, rhs: Kind) -> Bool {
            return lhs.description == rhs.description
        }

        public var description: String {
            switch self {
            case let .any(type),
                 let .enum(type, _):
                return "\(type)"
            case let .class(type):
                return "\(type).Type"
            case let .struct(type),
                 let .pointer(type):
                return type
            case let .protocol(proto):
                return "<\(NSStringFromProtocol(proto))>"
            }
        }
    }

    public enum Availability: Equatable {
        case available
        case unavailable(reason: String?)

        @available(*, deprecated, message: "Use readWrite instead")
        static var isAvailable = Availability.available

        public static func ==(lhs: Availability, rhs: Availability) -> Bool {
            switch (lhs, rhs) {
            case (.available, .available):
                return true
            case let (.unavailable(lhs), .unavailable(rhs)):
                return lhs == rhs
            case (.available, _), (.unavailable, _):
                return false
            }
        }
    }

    public typealias Getter = (_ target: AnyObject, _ key: String) -> Any?
    public typealias Setter = (_ target: AnyObject, _ key: String, _ value: Any) throws -> Void

    public let type: Kind
    private(set) var availability = Availability.available
    private(set) var getter: Getter?
    private(set) var setter: Setter?

    static func unavailable(_ reason: String? = nil) -> RuntimeType? {
        #if arch(i386) || arch(x86_64)
            return RuntimeType(.any(String.self), .unavailable(reason: reason))
        #else
            return nil
        #endif
    }

    public var isAvailable: Bool {
        switch availability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    @nonobjc private init(_ type: Kind, _ availability: Availability = .available) {
        self.type = type
        self.availability = availability
    }

    @nonobjc public convenience init(_ type: Any.Type, _ availability: Availability = .available) {
        let name = "\(type)"
        switch name {
        case "CGColor", "CGImage", "CGPath":
            self.init(.pointer(name), availability)
        case "NSString":
            self.init(.any(String.self), availability)
        default:
            self.init(.any(type), availability)
        }
    }

    @nonobjc public convenience init(class: AnyClass, _ availability: Availability = .available) {
        self.init(.class(`class`), availability)
    }

    @nonobjc public convenience init(_ type: Protocol, _ availability: Availability = .available) {
        self.init(.protocol(type), availability)
    }

    @nonobjc public convenience init?(_ typeName: String, _ availability: Availability = .available) {
        guard let type = typesByName[typeName] ?? NSClassFromString(typeName) else {
            guard let proto = NSProtocolFromString(typeName) else {
                return nil
            }
            self.init(proto, availability)
            return
        }
        self.init(type, availability)
    }

    @nonobjc public init?(objCType: String, _ availability: Availability = .available) {
        guard let first = objCType.unicodeScalars.first else {
            assertionFailure("Empty objCType")
            return nil
        }
        self.availability = availability
        switch first {
        case "c" where OBJC_BOOL_IS_BOOL == 0, "B":
            type = .any(Bool.self)
        case "c", "i", "s", "l", "q":
            type = .any(Int.self)
        case "C", "I", "S", "L", "Q":
            type = .any(UInt.self)
        case "f":
            type = .any(Float.self)
        case "d":
            type = .any(Double.self)
        case "*":
            type = .any(UnsafePointer<Int8>.self)
        case "@":
            if objCType.hasPrefix("@\"") {
                let range = "@\"".endIndex ..< objCType.index(before: objCType.endIndex)
                let className: String = String(objCType[range])
                if className.hasPrefix("<") {
                    let range = "<".endIndex ..< className.index(before: className.endIndex)
                    let protocolName: String = String(className[range])
                    if let proto = NSProtocolFromString(protocolName) {
                        type = .protocol(proto)
                        return
                    }
                } else if let cls = NSClassFromString(className) {
                    if cls == NSString.self {
                        type = .any(String.self)
                    } else {
                        type = .any(cls)
                    }
                    return
                }
            }
            // Can't infer the object type, so ignore it
            return nil
        case "#":
            // Can't infer the specific subclass, so ignore it
            return nil
        case ":":
            type = .any(Selector.self)
            getter = { target, key in
                let selector = Selector(key)
                let fn = unsafeBitCast(
                    class_getMethodImplementation(Swift.type(of: target), selector),
                    to: (@convention(c) (AnyObject?, Selector) -> Selector?).self
                )
                return fn(target, selector)
            }
            setter = { target, key, value in
                let chars = key.characters
                let selector = Selector(
                    "set\(String(chars.first!).uppercased())\(String(chars.dropFirst())):"
                )
                let fn = unsafeBitCast(
                    class_getMethodImplementation(Swift.type(of: target), selector),
                    to: (@convention(c) (AnyObject?, Selector, Selector?) -> Void).self
                )
                fn(target, selector, value as? Selector)
            }
        case "{":
            type = .struct(sanitizedStructName(objCType))
        case "^" where objCType.hasPrefix("^{"),
             "r" where objCType.hasPrefix("r^{"):
            type = .pointer(sanitizedStructName(objCType))
        default:
            // Unsupported type
            return nil
        }
    }

    @nonobjc public init<T: RawRepresentable>(_ type: T.Type, _ values: [String: T]) {
        self.type = .enum(type, values)
        getter = { target, key in
            (target.value(forKey: key) as? T.RawValue).flatMap { T(rawValue: $0) }
        }
        setter = { target, key, value in
            target.setValue((value as? T)?.rawValue, forKey: key)
        }
        availability = .available
    }

    @nonobjc public init<T: Any>(_ type: T.Type, _ values: [String: T]) {
        self.type = .enum(type, values)
        availability = .available
    }

    public override var description: String {
        switch availability {
        case .available:
            return type.description
        case .unavailable:
            return "<unavailable>"
        }
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? RuntimeType else {
            return false
        }
        if self === object {
            return true
        }
        switch (availability, object.availability) {
        case (.available, .available):
            return type == object.type
        case let (.unavailable(lreason), .unavailable(rreason)):
            return lreason == rreason
        case (.available, _), (.unavailable, _):
            return false
        }
    }

    public override var hash: Int {
        return description.hashValue
    }

    public func cast(_ value: Any) -> Any? {
        guard let value = optionalValue(of: value) else {
            return nil
        }
        func cast(_ value: Any, as type: Any.Type) -> Any? {
            switch type {
            case is NSNumber.Type:
                return value as? NSNumber
            case is CGFloat.Type:
                return value as? CGFloat ??
                    (value as? Double).map { CGFloat($0) } ??
                    (value as? NSNumber).map { CGFloat(truncating: $0) }
            case is Double.Type:
                return value as? Double ??
                    (value as? CGFloat).map { Double($0) } ??
                    (value as? NSNumber).map { Double(truncating: $0) }
            case is Float.Type:
                return value as? Float ??
                    (value as? Double).map { Float($0) } ??
                    (value as? NSNumber).map { Float(truncating: $0) }
            case is Int.Type:
                return value as? Int ??
                    (value as? Double).map { Int($0) } ??
                    (value as? NSNumber).map { Int(truncating: $0) }
            case is UInt.Type:
                return value as? UInt ??
                    (value as? Double).map { UInt($0) } ??
                    (value as? NSNumber).map { UInt(truncating: $0) }
            case is Bool.Type:
                return value as? Bool ??
                    (value as? Double).map { $0 != 0 } ??
                    (value as? NSNumber).map { $0 != 0 }
            case is String.Type,
                 is NSString.Type:
                return value as? String ?? "\(value)"
            case is NSAttributedString.Type:
                return value as? NSAttributedString ?? NSAttributedString(string: "\(value)")
            case let subtype as AnyClass:
                return (value as AnyObject).isKind(of: subtype) ? value : nil
            case _ where type == Any.self:
                return value
            default:
                if let nsValue = value as? NSValue, sanitizedStructName(String(cString: nsValue.objCType)) == "\(type)" {
                    return value
                }
                return type == Swift.type(of: value) || "\(type)" == "\(Swift.type(of: value))" ? value : nil
            }
        }
        switch type {
        case let .any(subtype):
            return cast(value, as: subtype)
        case let .class(type):
            if let value = value as? AnyClass, value.isSubclass(of: type) {
                return value
            }
            return nil
        case let .struct(type):
            if let value = value as? NSValue, sanitizedStructName(String(cString: value.objCType)) == type {
                return value
            }
            return nil
        case let .pointer(type):
            switch type {
            case "CGColor" where value is UIColor:
                return (value as! UIColor).cgColor
            case "CGImage" where value is UIImage:
                return (value as! UIImage).cgImage
            case "CGPath":
                if "\(value)".hasPrefix("Path") {
                    return value
                }
                fallthrough
            case "CGColor", "CGImage":
                if "\(value)".hasPrefix("<\(type)") {
                    return value
                }
                return nil
            default:
                return value // No way to validate
            }
        case let .enum(type, enumValues):
            if let key = value as? String, let value = enumValues[key] {
                return value
            }
            if let value = cast(value, as: type) as? AnyHashable {
                return enumValues.values.first { value == $0 as? AnyHashable }
            }
            if type != Swift.type(of: value) {
                return nil
            }
            return value
        case let .protocol(type):
            return (value as AnyObject).conforms(to: type) ? value : nil
        }
    }

    public func matches(_ type: Any.Type) -> Bool {
        switch self.type {
        case let .any(_type):
            if let lhs = type as? AnyClass, let rhs = _type as? AnyClass {
                return rhs.isSubclass(of: lhs)
            }
            return type == _type || "\(type)" == "\(_type)"
        default:
            return false
        }
    }

    public func matches(_ value: Any) -> Bool {
        return cast(value) != nil
    }
}

private let typesByName: [String: Any.Type] = [
    "Any": Any.self,
    "String": String.self,
    "Bool": Bool.self,
    "Int": Int.self,
    "UInt": UInt.self,
    "Float": Float.self,
    "Double": Double.self,
    "CGFloat": CGFloat.self,
    "CGPoint": CGPoint.self,
    "CGSize": CGSize.self,
    "CGRect": CGRect.self,
    "CGVector": CGVector.self,
    "CGAffineTransform": CGAffineTransform.self,
    "CATransform3D": CATransform3D.self,
    "UIEdgeInsets": UIEdgeInsets.self,
    "UIOffset": UIOffset.self,
    "CGColor": CGColor.self,
    "CGImage": CGImage.self,
    "CGPath": CGPath.self,
    "Selector": Selector.self,
]
