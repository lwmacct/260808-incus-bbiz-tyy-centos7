#!/usr/bin/env bash

__ipv4_to_int() {
  local _address=$1
  local _a
  local _b
  local _c
  local _d

  IFS=. read -r _a _b _c _d <<< "${_address}"
  printf '%u\n' "$((
    (10#${_a} << 24)
    | (10#${_b} << 16)
    | (10#${_c} << 8)
    | 10#${_d}
  ))"
}

__int_to_ipv4() {
  local _value=$1

  printf '%d.%d.%d.%d\n' \
    "$(((_value >> 24) & 255))" \
    "$(((_value >> 16) & 255))" \
    "$(((_value >> 8) & 255))" \
    "$((_value & 255))"
}

__main() {
  set -euo pipefail

  _docker_json=$(docker network inspect bridge)
  _docker_driver=$(jq -r '.[0].Driver' <<< "${_docker_json}")
  _docker_bridge=$(jq -r \
    '.[0].Options["com.docker.network.bridge.name"] // "docker0"' \
    <<< "${_docker_json}")
  _docker_subnet=$(jq -r '.[0].IPAM.Config[0].Subnet' <<< "${_docker_json}")
  _docker_gateway=$(jq -r '.[0].IPAM.Config[0].Gateway' <<< "${_docker_json}")
  test "${_docker_driver}" = bridge
  test -n "${_docker_subnet}" && test "${_docker_subnet}" != null
  test -n "${_docker_gateway}" && test "${_docker_gateway}" != null
  ip link show dev "${_docker_bridge}"

  _subnet_address=${_docker_subnet%/*}
  _prefix=${_docker_subnet#*/}
  if [ "${_prefix}" -lt 8 ] || [ "${_prefix}" -gt 30 ]; then
    echo "Unsupported Docker bridge prefix: ${_prefix}" >&2
    return 1
  fi
  _host_bits=$((32 - _prefix))
  _mask_int=$(((0xFFFFFFFF << _host_bits) & 0xFFFFFFFF))
  _subnet_int=$(__ipv4_to_int "${_subnet_address}")
  _network_int=$((_subnet_int & _mask_int))
  _broadcast_int=$((_network_int | ((1 << _host_bits) - 1)))
  _netmask=$(__int_to_ipv4 "${_mask_int}")

  _run_number=$((GITHUB_RUN_ID + GITHUB_RUN_ATTEMPT))
  _mac_number=$((_run_number % 16777215))
  _guest_mac=$(printf '02:16:3e:%02x:%02x:%02x' \
    "$((_mac_number >> 16 & 255))" \
    "$((_mac_number >> 8 & 255))" \
    "$((_mac_number & 255))")
  _start_offset=$((_run_number % 64 + 1))
  _guest_ip=
  for _index in $(seq 0 63); do
    _offset=$(((_start_offset + _index) % 64 + 1))
    _candidate=$(__int_to_ipv4 "$((_broadcast_int - _offset))")
    if [ "${_candidate}" = "${_docker_gateway}" ]; then
      continue
    fi
    if jq -e --arg _ip "${_candidate}" '
      ([((.[0].Containers // {}) | .[] |
        (.IPv4Address // "") | split("/")[0])] | index($_ip)) == null
    ' <<< "${_docker_json}" >/dev/null; then
      _guest_ip=${_candidate}
      break
    fi
  done
  test -n "${_guest_ip}"

  _route_device=$(ip -4 route get "${_guest_ip}" \
    | awk '{for (_field = 1; _field <= NF; _field++) {
        if ($(_field) == "dev") {print $(_field + 1); exit}
      }}')
  test "${_route_device}" = "${_docker_bridge}"
  _docker_dns=$(awk '
    /^nameserver / && $2 !~ /^127\./ {print $2; exit}
  ' /run/systemd/resolve/resolv.conf 2>/dev/null || true)
  if [ -z "${_docker_dns}" ]; then
    _docker_dns=1.1.1.1
  fi

  {
    echo "DOCKER_BRIDGE=${_docker_bridge}"
    echo "DOCKER_SUBNET=${_docker_subnet}"
    echo "DOCKER_NETMASK=${_netmask}"
    echo "DOCKER_GATEWAY=${_docker_gateway}"
    echo "DOCKER_DNS=${_docker_dns}"
    echo "DOCKER_GUEST_IP=${_guest_ip}"
    echo "DOCKER_GUEST_ADDRESS=${_guest_ip}/${_prefix}"
    echo "DOCKER_GUEST_MAC=${_guest_mac}"
  } >> "${GITHUB_ENV}"
  docker network inspect bridge
}

__main "$@"
