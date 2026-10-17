import RemoteFiles
import Testing

@Suite struct RemotePathTests {
    @Test func normalisesAndJoins() {
        #expect(RemotePath.normalize("a//b/") == "/a/b")
        #expect(RemotePath.parent(of: "/a/b") == "/a")
        #expect(RemotePath.parent(of: "/a") == "/")
        #expect(RemotePath.join("/a", "b c") == "/a/b c")
        #expect(RemoteItem(path: "/DCIM/x.jpg", isFolder: false).name == "x.jpg")
    }
}
