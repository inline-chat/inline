import Foundation
import Testing

@testable import InlineKit

@Suite("Rich media URL policy")
struct RichMediaURLPolicyTests {
  @Test("accepts trimmed public HTTPS URLs")
  func acceptsPublicHTTPS() {
    let url = RichMediaURLPolicy.safeRemoteMediaURL(from: " https://cdn.inline.test/media/photo.jpg?size=large ")

    #expect(url?.absoluteString == "https://cdn.inline.test/media/photo.jpg?size=large")
  }

  @Test("rejects insecure HTTP URLs")
  func rejectsHTTP() {
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "http://cdn.inline.test/media/photo.jpg") == nil)
  }

  @Test("rejects URLs with embedded credentials")
  func rejectsCredentials() {
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://user:pass@cdn.inline.test/photo.jpg") == nil)
  }

  @Test("rejects localhost and .local hosts")
  func rejectsLocalHosts() {
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://localhost/photo.jpg") == nil)
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://inline.local/photo.jpg") == nil)
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://[::1]/photo.jpg") == nil)
  }

  @Test("rejects private and reserved IPv4 hosts")
  func rejectsPrivateIPv4Hosts() {
    for host in [
      "0.0.0.0",
      "10.0.0.8",
      "127.0.0.1",
      "169.254.1.2",
      "172.16.1.2",
      "172.31.1.2",
      "192.168.1.2",
      "100.64.1.2",
      "100.127.1.2",
      "198.18.1.2",
      "198.19.1.2",
    ] {
      #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://\(host)/photo.jpg") == nil)
    }
  }

  @Test("accepts public IPv4 hosts outside blocked ranges")
  func acceptsPublicIPv4Hosts() {
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://8.8.8.8/photo.jpg") != nil)
    #expect(RichMediaURLPolicy.safeRemoteMediaURL(from: "https://1.1.1.1/photo.jpg") != nil)
  }
}
