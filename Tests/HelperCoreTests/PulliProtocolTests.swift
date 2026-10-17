import Foundation
import PulliProtocol
import Testing

/// Tests backwards-compatible decoding of PulliProtocol types across protocol versions.
@Suite struct PulliProtocolTests {
    @Test func oldSettingsWithoutChunkOverridesDecodes() throws {
        let oldJSON = """
        {
          "defaultDestination": "/tmp/Pulli",
          "duplicatePolicy": "auto",
          "chunkMiB": 8,
          "releaseSystemCameraService": true,
          "keepMacAwake": true,
          "organize": "year_month",
          "allowDriveChanges": false
        }
        """
        let settings = try JSONDecoder().decode(HelperSettings.self, from: Data(oldJSON.utf8))
        #expect(settings.chunkMiB == 8)
        #expect(settings.chunkMiBByDevice == nil)
        #expect(settings.chunkMiB(for: "usb:18d1:4ee2:PHONE1") == 8)
    }

    @Test func oldDeviceSnapshotWithoutChunkSuggestionDecodes() throws {
        let oldJSON = """
        {
          "id": "usb:18d1:4ee2:PHONE1",
          "name": "Pixel 9 Pro",
          "model": "Pixel 9 Pro",
          "manufacturer": "Google",
          "link": "usb2",
          "linkBitsPerSecond": 480000000,
          "state": {
            "ready": {}
          },
          "storages": [
            {
              "id": 65537,
              "name": "Internal shared storage",
              "capacityBytes": 128000000000,
              "freeBytes": 64000000000
            }
          ],
          "resumable": true
        }
        """
        let snapshot = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(oldJSON.utf8))
        #expect(snapshot.id == "usb:18d1:4ee2:PHONE1")
        #expect(snapshot.chunkSuggestion == nil)
    }

    @Test func newFieldsRoundTripThroughJSON() throws {
        let suggestion = ChunkSuggestion(deviceID: "usb:18d1:4ee2:PHONE1", currentMiB: 8, suggestedMiB: 2, failures: 3)
        let suggestionData = try JSONEncoder().encode(suggestion)
        let decodedSuggestion = try JSONDecoder().decode(ChunkSuggestion.self, from: suggestionData)
        #expect(decodedSuggestion == suggestion)

        let settings = HelperSettings(chunkMiB: 8, chunkMiBByDevice: ["usb:18d1:4ee2:PHONE1": 2])
        let settingsData = try JSONEncoder().encode(settings)
        let decodedSettings = try JSONDecoder().decode(HelperSettings.self, from: settingsData)
        #expect(decodedSettings.chunkMiB(for: "usb:18d1:4ee2:PHONE1") == 2)
        #expect(decodedSettings.chunkMiB(for: "usb:18d1:4ee2:OTHER") == 8)

        let request = ClientRequest.applyChunkSuggestion(deviceID: "usb:18d1:4ee2:PHONE1", accept: true)
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(ClientRequest.self, from: requestData)
        #expect(decodedRequest == request)

        let clearRequest = ClientRequest.clearHistory
        let clearData = try JSONEncoder().encode(clearRequest)
        let decodedClear = try JSONDecoder().decode(ClientRequest.self, from: clearData)
        #expect(decodedClear == clearRequest)
    }
}
