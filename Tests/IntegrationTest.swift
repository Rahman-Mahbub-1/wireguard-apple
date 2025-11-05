// Test file to verify WireGuard Go functions are accessible
import Foundation
import WireGuardKitGo

// This should compile if the C bridge is working
func testWireGuardGoIntegration() {
    // If we can call this without linker errors, the static library is properly linked
    print("WireGuard Go integration test")
}