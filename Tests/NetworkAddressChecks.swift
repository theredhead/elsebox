import Foundation

@main
struct NetworkAddressChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        let dhcp = """
            {
              hw_address=1,a:b:c:d:e:f
              ip_address=192.168.64.7
              lease=0x44c
            }
            {
              hw_address=1,a:b:c:d:e:f
              ip_address=192.168.64.8
              lease=0x384
            }
            {
              hw_address=1,ff:ff:ff:ff:ff:ff
              ip_address=192.168.64.9
              lease=0xffffffff
            }
            """
        let arp =
            "? (192.168.64.7) at a:b:c:d:e:f on bridge100 ifscope [ethernet]\n? () at a:b:c:d:e:f on bridge100\n? (192.168.64.1) at (incomplete) on bridge100"
        let ndp =
            "Neighbor Linklayer Address Netif Expire\nfe80::1234%bridge100 a:b:c:d:e:f bridge100 10m\nnot-an-ip a:b:c:d:e:f bridge100 10m"
        let parsed = VMNetworkAddressParser.parse(dhcp: dhcp, arp: arp, ndp: ndp, now: now)
        precondition(parsed["0a:0b:0c:0d:0e:0f"] == ["192.168.64.7", "fe80::1234%bridge100"])
        precondition(parsed["ff:ff:ff:ff:ff:ff"] == ["192.168.64.9"])
        precondition(VMNetworkAddressParser.mac("not-a-mac") == nil)
        precondition(VMNetworkAddressParser.mac("1,AA:0:B:01:02:03") == "aa:00:0b:01:02:03")
        precondition(VMNetworkAddressParser.parse(dhcp: "", arp: "", ndp: "").isEmpty)
        print(
            "Passed: guest MAC matching, expired DHCP exclusion, IPv4/IPv6 neighbors, duplicate and malformed records"
        )
    }
}
