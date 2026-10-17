import DeviceAPI
import Testing

@Suite struct InterfaceHolderTests {
    @Test func parsesUserProcess() {
        #expect(InterfaceHolder(ownerString: "pid 812, ptpcamerad") == .process(pid: 812, name: "ptpcamerad"))
        #expect(InterfaceHolder(ownerString: "  pid 44, Google Drive Helper ") == .process(pid: 44, name: "Google Drive Helper"))
    }

    @Test func parsesDriver() {
        #expect(InterfaceHolder(ownerString: "AppleUSBACMControl") == .driver(name: "AppleUSBACMControl"))
        #expect(InterfaceHolder(ownerString: "pid x, weird") == .driver(name: "pid x, weird"))
    }
}

@Suite struct DeviceKeyTests {
    @Test(arguments: ["R58N12ABCDE", "3A221FDH2008ZX", "0123A"])
    func acceptsRealSerials(_ serial: String) {
        #expect(DeviceKey.isUsableSerial(serial))
    }

    @Test(arguments: [nil, "", "   ", "000", "0000000000", "0123456789ABCDEF", "N/A"] as [String?])
    func rejectsJunkSerials(_ serial: String?) {
        #expect(!DeviceKey.isUsableSerial(serial))
    }

    @Test func descriptionIsStable() {
        #expect(DeviceKey(kind: .usb, vendorID: 0x04e8, serial: "R58N").description == "usb:04e8:R58N")
    }
}

@Suite struct RemotePathTests {
    @Test func parsesAndJoins() {
        let path = RemotePath("/DCIM//Camera/IMG_1.jpg")
        #expect(path.components == ["DCIM", "Camera", "IMG_1.jpg"])
        #expect(path.name == "IMG_1.jpg")
        #expect(path.parent == RemotePath("DCIM/Camera"))
        #expect(path.description == "/DCIM/Camera/IMG_1.jpg")
        #expect(RemotePath("/").isRoot)
        #expect(RemotePath.root.appending("DCIM") == RemotePath("DCIM"))
    }
}

@Suite struct LinkAndStrategyTests {
    @Test func classifiesLinkSpeed() {
        #expect(LinkGeneration(bitsPerSecond: 480_000_000) == .usb2)
        #expect(LinkGeneration(bitsPerSecond: 5_000_000_000) == .usb3)
        #expect(LinkGeneration(bitsPerSecond: 12_000_000) == .usb1)
        #expect(LinkGeneration(bitsPerSecond: nil) == .unknown)
    }

    @Test func resumabilityByStrategy() {
        let big: UInt64 = 5 << 30
        #expect(ReadStrategy.partial64.supportsResume(fileSize: big))
        #expect(!ReadStrategy.partial32.supportsResume(fileSize: big))
        #expect(ReadStrategy.partial32.supportsResume(fileSize: 1 << 30))
        #expect(!ReadStrategy.whole.supportsResume(fileSize: 1))
    }
}
