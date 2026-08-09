#!/usr/bin/env bash

__diagnose() {
  sudo incus list "${TEST_INSTANCE}" --format=yaml || true
  sudo incus info "${TEST_INSTANCE}" --show-log || true
  sudo incus exec "${TEST_INSTANCE}" -- ip -4 address show || true
  sudo incus exec "${TEST_INSTANCE}" -- ip -4 route show || true
  sudo incus exec "${TEST_INSTANCE}" -- cat /etc/resolv.conf || true
  sudo incus exec "${TEST_INSTANCE}" -- \
    systemctl --no-pager --full status NetworkManager network || true
  sudo incus console "${TEST_INSTANCE}" --show-log || true
  sudo incus network show incusbr0 || true
  if [ -n "${DHCP_LEASE_FILE:-}" ]; then
    sudo cat "${DHCP_LEASE_FILE}" || true
  fi
  if [ -n "${NETWORK_PARENT:-}" ]; then
    bridge link show master "${NETWORK_PARENT}" || true
  fi
  sudo sysctl net.ipv4.ip_forward || true
  sudo iptables --numeric --verbose --list FORWARD || true
  sudo iptables --numeric --verbose --list DOCKER-USER || true
  sudo nft list ruleset || true
  ip -4 address show || true
  ip -4 route show || true
  sudo journalctl --no-pager --unit=incus -n 200 || true
}

__fail() {
  _failure_stage=$1
  echo "::error title=Incus VM network check failed::${_failure_stage}" >&2
  __diagnose
  exit 1
}

__probe_runner_https() {
  _url=$1
  printf 'origin=runner url=%s\n' "${_url}"
  curl -4 -fsSL \
    --retry 2 \
    --connect-timeout 10 \
    --max-time 60 \
    --output /dev/null \
    --write-out 'status=%{http_code} remote_ip=%{remote_ip} total=%{time_total}s\n' \
    "${_url}"
}

__probe_guest_https() {
  _url=$1
  printf 'origin=guest url=%s\n' "${_url}"
  sudo incus exec "${TEST_INSTANCE}" -- \
    curl -4 -fsSL \
      --retry 2 \
      --connect-timeout 10 \
      --max-time 60 \
      --output /dev/null \
      --write-out 'status=%{http_code} remote_ip=%{remote_ip} total=%{time_total}s\n' \
      "${_url}"
}

__check_guest_storage() {
  sudo incus exec "${TEST_INSTANCE}" -- \
    env VM_DISK_TOTAL_BYTES="${VM_DISK_TOTAL_BYTES}" sh -c '
      set -eux
      _root_source=$(findmnt -n -o SOURCE --target /)
      test -n "${_root_source}"
      _root_device=$(readlink -f "${_root_source}")
      _root_device_name=${_root_device##*/}
      test "$(cat "/sys/class/block/${_root_device_name}/partition")" = 2
      _parent_name=$(lsblk -n -o PKNAME "${_root_source}" | head -n 1)
      test -n "${_parent_name}"
      _parent_device=/dev/${_parent_name}
      test "$(blockdev --getsize64 "${_parent_device}")" = "${VM_DISK_TOTAL_BYTES}"
      _partition_layout=$(lsblk -nr -o TYPE,PARTN "${_parent_device}" \
        | awk '$1 == "part" {print $2}' | sort -n | xargs)
      test "${_partition_layout}" = "1 2"
      test "$(findmnt -n -o FSTYPE --target /)" = ext4
      _test_file=/root/.incus-network-write-test
      printf "%s\n" root-partition > "${_test_file}"
      grep -qx root-partition "${_test_file}"
      rm -f "${_test_file}"
    '
}

__main() {
  set -euo pipefail

  _network_interface=${NETWORK_INTERFACE:-eth0}
  _network_expected_address=${NETWORK_EXPECTED_ADDRESS:-}
  _network_expected_gateway=${NETWORK_EXPECTED_GATEWAY:-}
  _network_label=${NETWORK_LABEL:-Incus network}
  _require_centos_mirror=${REQUIRE_CENTOS_MIRROR:-true}

  _ready=false
  set +e
  for _attempt in $(seq 1 120); do
    sudo incus exec "${TEST_INSTANCE}" -- true >/dev/null 2>&1
    _agent_status=$?
    if [ "${_agent_status}" -eq 0 ]; then
      _ready=true
      break
    fi
    sleep 5
  done
  set -e
  test "${_ready}" = true || __fail \
    "Incus agent did not become ready within 10 minutes"

  _guest_kernel=$(sudo incus exec "${TEST_INSTANCE}" -- uname -r) \
    || __fail "Could not read guest kernel"
  test "${_guest_kernel}" = "${KERNEL_RELEASE}" || __fail \
    "Guest kernel ${_guest_kernel} does not match ${KERNEL_RELEASE}"
  __check_guest_storage || __fail \
    "Guest two-partition root disk does not match the image contract"
  _guest_cpu_count=$(sudo incus exec "${TEST_INSTANCE}" -- \
    getconf _NPROCESSORS_ONLN) || __fail "Could not read guest CPU count"
  test "${_guest_cpu_count}" = "${VM_CPU_COUNT}" || __fail \
    "Guest has ${_guest_cpu_count} online CPUs; expected ${VM_CPU_COUNT}"
  _configured_memory=$(sudo incus config get \
    "${TEST_INSTANCE}" limits.memory) || __fail "Could not read VM memory limit"
  test "${_configured_memory}" = "${VM_MEMORY_LIMIT}" || __fail \
    "VM memory limit ${_configured_memory} does not match ${VM_MEMORY_LIMIT}"

  _guest_memory_kib=$(sudo incus exec "${TEST_INSTANCE}" -- \
    awk '/^MemTotal:/ {print $2}' /proc/meminfo) || __fail \
    "Could not read guest MemTotal"
  _minimum_guest_memory_kib=$((VM_MEMORY_MIB * 90 * 1024 / 100))
  _maximum_guest_memory_kib=$((VM_MEMORY_MIB * 1024))
  if [ "${_guest_memory_kib}" -lt "${_minimum_guest_memory_kib}" ] || \
    [ "${_guest_memory_kib}" -gt "${_maximum_guest_memory_kib}" ]; then
    __fail "Guest MemTotal is outside 90-100% of the configured limit"
  fi

  _guest_ipv4_cidr=
  _guest_gateway=
  for _attempt in $(seq 1 60); do
    _guest_ipv4_cidr=$(sudo incus exec "${TEST_INSTANCE}" -- \
      ip -4 -o address show dev "${_network_interface}" scope global 2>/dev/null \
      | awk 'NR == 1 {print $4}' || true)
    _guest_gateway=$(sudo incus exec "${TEST_INSTANCE}" -- \
      ip -4 route show default 2>/dev/null \
      | awk 'NR == 1 {print $3}' || true)
    if [ -n "${_guest_ipv4_cidr}" ] && [ -n "${_guest_gateway}" ]; then
      break
    fi
    sleep 2
  done
  test -n "${_guest_ipv4_cidr}" || __fail \
    "DHCP did not provide a global IPv4 address within 2 minutes"
  test -n "${_guest_gateway}" || __fail \
    "No IPv4 default route appeared within 2 minutes"
  if [ -n "${_network_expected_address}" ]; then
    test "${_guest_ipv4_cidr}" = "${_network_expected_address}" || __fail \
      "Guest address ${_guest_ipv4_cidr} does not match ${_network_expected_address}"
  fi
  if [ -n "${_network_expected_gateway}" ]; then
    test "${_guest_gateway}" = "${_network_expected_gateway}" || __fail \
      "Guest gateway ${_guest_gateway} does not match ${_network_expected_gateway}"
  fi
  _guest_ipv4=${_guest_ipv4_cidr%/*}

  sudo incus exec "${TEST_INSTANCE}" -- ip -4 address show || __fail \
    "Could not display guest IPv4 addresses"
  sudo incus exec "${TEST_INSTANCE}" -- ip -4 route show || __fail \
    "Could not display guest IPv4 routes"
  sudo incus exec "${TEST_INSTANCE}" -- cat /etc/resolv.conf || __fail \
    "Could not display guest resolver configuration"
  sudo incus exec "${TEST_INSTANCE}" -- \
    ping -c 3 -W 3 "${_guest_gateway}" || __fail \
    "Guest cannot ping bridge gateway ${_guest_gateway}"
  ping -c 3 -W 3 "${_guest_ipv4}" || __fail \
    "Runner cannot ping guest ${_guest_ipv4}"

  _centos_url=${CENTOS_MIRROR_URL:-https://mirrors.cloud.tencent.com/centos-vault/7.9.2009/os/x86_64/repodata/repomd.xml}
  _centos_runner_ok=false
  _centos_guest_ok=false
  if __probe_runner_https "${_centos_url}"; then
    _centos_runner_ok=true
  fi
  if __probe_guest_https "${_centos_url}"; then
    _centos_guest_ok=true
  fi
  if [ "${_centos_guest_ok}" != true ]; then
    if [ "${_require_centos_mirror}" = true ]; then
      __fail "Guest cannot reach the CentOS 7 mainland mirror HTTPS endpoint"
    fi
    echo "::warning title=CentOS mirror external reachability::The CentOS 7 mainland mirror is unreachable from the guest"
  fi
  {
    echo "## ${_network_label} result"
    echo
    printf -- '- Kernel: %s\n' "${_guest_kernel}"
    printf -- '- VM CPUs: %s\n' "${_guest_cpu_count}"
    printf -- '- VM memory: %s (guest %s MiB)\n' \
      "${_configured_memory}" "$((_guest_memory_kib / 1024))"
    printf -- '- Disk layout: EFI + ext4 root partition\n'
    printf -- '- Guest IPv4: %s\n' "${_guest_ipv4_cidr}"
    printf -- '- Default gateway: %s\n' "${_guest_gateway}"
    printf -- '- CentOS 7 mainland mirror HTTPS (guest): %s\n' \
      "${_centos_guest_ok}"
    echo 'Kernel, storage, resources, DHCP, default route, bidirectional ICMP, DNS and control HTTPS: passed'
  } >> "${GITHUB_STEP_SUMMARY}"
}

__main "$@"
