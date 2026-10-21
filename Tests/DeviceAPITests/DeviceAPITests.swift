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

@Suite struct CameraClientAppsTests {
    @Test func looksUpKnownAppsByBundleID() {
        #expect(CameraClientApps.app(forBundleID: "com.google.drivefs")?.displayName == "Google Drive")
        #expect(CameraClientApps.app(forBundleID: "COM.GETDROPBOX.DROPBOX")?.displayName == "Dropbox")
        #expect(CameraClientApps.app(forBundleID: "com.apple.Photos")?.displayName == "Photos")
        #expect(CameraClientApps.app(forBundleID: "com.apple.Image_Capture")?.displayName == "Image Capture")
        #expect(CameraClientApps.app(forBundleID: "com.apple.Preview")?.displayName == "Preview")
        #expect(CameraClientApps.app(forBundleID: "com.adobe.LightroomClassicCC7")?.displayName == "Lightroom Classic")
        #expect(CameraClientApps.app(forBundleID: "com.adobe.mas.lightroomCC")?.displayName == "Lightroom")
        #expect(CameraClientApps.app(forBundleID: "com.adobe.lightroomCC")?.displayName == "Lightroom")
        #expect(CameraClientApps.app(forBundleID: "com.samsung.SmartSwitch")?.displayName == "Samsung Smart Switch")
        #expect(CameraClientApps.app(forBundleID: "com.google.android.mtpviewer")?.displayName == "Android File Transfer")
        #expect(CameraClientApps.app(forBundleID: "io.ganeshrvel.openmtp")?.displayName == "OpenMTP")
    }

    @Test func returnsNilForUnknownBundleIDs() {
        #expect(CameraClientApps.app(forBundleID: "com.unknown.app") == nil)
        #expect(CameraClientApps.app(forBundleID: "") == nil)
    }

    @Test func preservesOrderWhenSeveralAppsRun() {
        // When both Dropbox and Google Drive run, Google Drive has priority in declared order.
        let running1 = ["com.getdropbox.dropbox", "com.google.drivefs"]
        #expect(CameraClientApps.firstRunning(in: running1)?.displayName == "Google Drive")

        // When Photos, OpenMTP and Preview run, Photos comes first, then Preview, then OpenMTP.
        let running2 = ["io.ganeshrvel.openmtp", "com.apple.Preview", "com.apple.Photos"]
        let matching = CameraClientApps.matching(runningBundleIDs: running2).map(\.displayName)
        #expect(matching == ["Photos", "Preview", "OpenMTP"])
        #expect(CameraClientApps.firstRunning(in: running2)?.displayName == "Photos")

        // Unknown bundle IDs among running apps are ignored.
        let running3 = ["org.mozilla.firefox", "com.google.chrome"]
        #expect(CameraClientApps.firstRunning(in: running3) == nil)
        #expect(CameraClientApps.matching(runningBundleIDs: running3).isEmpty)
    }

    @Test func sanitizesSystemDaemonNames() {
        #expect(CameraClientApps.sanitizedHolderName("ptpcamerad") == "macOS's photo service")
        #expect(CameraClientApps.sanitizedHolderName("mscamerad") == "macOS's photo service")
        #expect(CameraClientApps.sanitizedHolderName("mscamerad-xpc") == "macOS's photo service")
        #expect(CameraClientApps.sanitizedHolderName("macOS's photo service") == "macOS's photo service")
        #expect(CameraClientApps.sanitizedHolderName("Google Drive") == "Google Drive")
        #expect(CameraClientApps.sanitizedHolderName("Photos") == "Photos")
    }
}

