// NAT Gateway + Standard Static IPv4 PIP for deterministic outbound from
// the vm-subnet.
//
// Why this exists:
//   - Without an explicit egress, the vm-subnet relies on Azure's
//     "default outbound access" SNAT. That path is IPv4-only, has no
//     SLA, and is being retired by Microsoft (Sept 2025+). Its SNAT IP
//     can change between stop/start and SNAT port exhaustion shows up
//     as hanging TCP connects — exactly the symptom observed.
//   - A NAT Gateway gives a fixed, allow-listable IPv4 SNAT address,
//     a much larger SNAT port budget, and immunity to the platform
//     default-outbound deprecation.
//
// NAT Gateway is IPv4-only. Hosts that publish AAAA records still
// require an IPv4-preferring resolver (see update-osm.sh:
// RES_OPTIONS=no-aaaa + curl -4).
//
// Zonal placement: the NAT GW and its PIP are pinned to the same
// availability zone as the VM. NAT GW is a zonal resource; pinning it
// to a single zone keeps the SNAT IP stable and avoids cross-zone
// fees. If the zone is unavailable the VM is also unreachable, so
// co-locating is the right tradeoff for this single-VM workload.
@description('Resource name (used for both the NAT GW and its PIP, with -pip suffix).')
param name string

@description('Azure region.')
param location string

@description('Availability zone for the NAT GW + its PIP. Must match the VM zone.')
@allowed([ '1', '2', '3' ])
param availabilityZone string = '1'

@description('TCP idle timeout in minutes for the SNAT flows. 4 (Azure default) is fine for short-lived HTTPS; bump if pyosmium/azcopy ever needs to hold idle connections longer.')
@minValue(4)
@maxValue(120)
param idleTimeoutInMinutes int = 4

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-pip'
  location: location
  sku: { name: 'Standard' }
  zones: [ availabilityZone ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-05-01' = {
  name: name
  location: location
  sku: { name: 'Standard' }
  zones: [ availabilityZone ]
  properties: {
    idleTimeoutInMinutes: idleTimeoutInMinutes
    publicIpAddresses: [
      { id: pip.id }
    ]
  }
}

output natGatewayId string = natGw.id
output natGatewayName string = natGw.name
output snatPublicIp string = pip.properties.ipAddress
