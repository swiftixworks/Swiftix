/// Value snapshots of TCP flow-control, congestion, and protocol state.
struct TCPWindowSnapshot: Equatable {
    let receiveBufferOccupancy: Int
    let receiveBufferCapacity: Int
    let advertised: UInt32
    let peerAdvertised: UInt32
}

struct TCPSnapshot: Equatable {
    let localPort: UInt16
    let remoteIP: IPv4Address
    let remotePort: UInt16
    let state: String
    let congestion: CongestionSnapshot
    let window: TCPWindowSnapshot

    var cwnd: Int { congestion.cwnd }
    var ssthresh: Int { congestion.ssthresh }
    var srtt: Double { congestion.srtt }
    var rttvar: Double { congestion.rttvar }
    var rto: Double { congestion.rto }
    var rwnd: UInt32 { window.advertised }
    var peerwnd: UInt32 { window.peerAdvertised }
    var receiveBufferOccupancy: Int { window.receiveBufferOccupancy }
    var receiveBufferCapacity: Int { window.receiveBufferCapacity }
}
