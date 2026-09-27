import Foundation
import IOKit

// Private IOKit API used on Apple Silicon to talk I2C/DDC to external displays.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

enum VCP: UInt8 {
    case volume = 0x62
    case mute = 0x8D
}

final class DDCDisplay {
    let name: String
    private let service: CFTypeRef

    init(name: String, service: CFTypeRef) {
        self.name = name
        self.service = service
    }

    private static let chip: UInt32 = 0x37
    private static let offset: UInt32 = 0x51

    @discardableResult
    func write(_ code: VCP, _ value: UInt16) -> Bool {
        var data: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        data[5] = data[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        for _ in 0..<2 {
            usleep(10_000)
            let r = data.withUnsafeMutableBytes { IOAVServiceWriteI2C(service, Self.chip, Self.offset, $0.baseAddress!, UInt32($0.count)) }
            if r != kIOReturnSuccess { return false }
        }
        return true
    }

    /// Returns (current, max) or nil.
    func read(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        for _ in 0..<4 {
            var req: [UInt8] = [0x82, 0x01, code.rawValue, 0]
            req[3] = req[0..<3].reduce(0x6E ^ 0x51) { $0 ^ $1 }
            usleep(10_000)
            let w = req.withUnsafeMutableBytes { IOAVServiceWriteI2C(service, Self.chip, Self.offset, $0.baseAddress!, UInt32($0.count)) }
            guard w == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let r = reply.withUnsafeMutableBytes { IOAVServiceReadI2C(service, Self.chip, Self.offset, $0.baseAddress!, UInt32($0.count)) }
            guard r == kIOReturnSuccess else { continue }
            // Verify checksum and that the reply is for the requested code.
            let checksum = reply[0..<11].reduce(0x50) { $0 ^ $1 }
            guard checksum == reply[11], reply[4] == code.rawValue, reply[3] == 0 else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (cur, max)
        }
        return nil
    }

    /// Walks the IORegistry pairing each external DCPAVServiceProxy with the preceding framebuffer's product name.
    static func all() -> [DDCDisplay] {
        // The registry iterator becomes invalid if the registry changes mid-walk (common right after app launch), so retry.
        for _ in 0..<10 {
            if let displays = scan() { return displays }
            usleep(200_000)
        }
        return []
    }

    private static func scan() -> [DDCDisplay]? {
        var result: [DDCDisplay] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var lastName: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(cString: nameBuf)

            if name.hasPrefix("AppleCLCD2") || name.hasPrefix("IOMobileFramebufferShim") {
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                   let product = attrs["ProductAttributes"] as? [String: Any] {
                    lastName = product["ProductName"] as? String
                }
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                guard location == "External", let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                result.append(DDCDisplay(name: lastName ?? "Unknown", service: svc))
                lastName = nil
            }
        }
        return IOIteratorIsValid(iterator) != 0 ? result : nil
    }
}
