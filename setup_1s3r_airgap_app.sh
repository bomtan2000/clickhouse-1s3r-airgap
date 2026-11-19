#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# BASE
#   Usage: setup_1s3r_airgap_app.sh [inventory.txt]
###############################################################################
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_DIR="${BASE_DIR}/rpm"
LOG_DIR="${BASE_DIR}/logs"
INVENTORY_FILE="${1:-${BASE_DIR}/inventory.txt}"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/setup_clickhouse_1s3r_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

die() {
  echo "ERROR: $*" >&2
  exit 1
}

###############################################################################
# INVENTORY (IP, hostname, directories) - read from the .txt file
###############################################################################
APP_BASE=""
REMOTE_RPM_DIR=""
CH_USER=""
CH_PASSWORD=""
CH_NODES=()
CH_HOSTS=()
K_NODES=()
K_HOSTS=()

IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
PATH_RE='^/[A-Za-z0-9._/-]+$'
USER_RE='^[A-Za-z_][A-Za-z0-9_]*$'

check_dir() {
  local name="$1" val="$2"
  [[ -n "${val}" ]] || die "${INVENTORY_FILE}: missing ${name}=..."
  [[ "${val}" =~ ${PATH_RE} ]] || die "${name}='${val}' must be an absolute path made of [A-Za-z0-9._/-] only"
  case "${val}/" in
    */./*|*/../*) die "${name}='${val}' must not contain '.' or '..' components" ;;
  esac
}

load_inventory() {
  local raw line lineno=0 key val role ip hn extra i j
  [[ -f "${INVENTORY_FILE}" ]] || die "Inventory not found: ${INVENTORY_FILE}"

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    lineno=$((lineno + 1))
    raw="${raw//$'\r'/}"
    line="${raw%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue

    # KEY=VALUE
    if [[ "${line}" == *=* ]]; then
      read -r key <<< "${line%%=*}"
      read -r val <<< "${line#*=}"
      case "${key}" in
        APP_BASE) APP_BASE="${val%/}" ;;
        REMOTE_RPM_DIR) REMOTE_RPM_DIR="${val%/}" ;;
        CH_USER) CH_USER="${val}" ;;
        # password is taken from the raw line: it may contain '#'
        CH_PASSWORD) read -r CH_PASSWORD <<< "${raw#*=}" ;;
        *) die "${INVENTORY_FILE}:${lineno}: unsupported key '${key}'" ;;
      esac
      continue
    fi

    # <role> <ip> <hostname>
    read -r role ip hn extra <<< "${line}"
    [[ -n "${hn}" && -z "${extra}" ]] \
      || die "${INVENTORY_FILE}:${lineno}: need exactly 3 columns '<server|keeper> <ip> <hostname>'"
    [[ "${ip}" =~ ${IP_RE} ]] || die "${INVENTORY_FILE}:${lineno}: invalid IP '${ip}'"
    [[ "${hn}" =~ ${HOST_RE} ]] || die "${INVENTORY_FILE}:${lineno}: invalid hostname '${hn}'"
    case "${role}" in
      server) CH_NODES+=("${ip}"); CH_HOSTS+=("${hn}") ;;
      keeper) K_NODES+=("${ip}"); K_HOSTS+=("${hn}") ;;
      *) die "${INVENTORY_FILE}:${lineno}: role must be server or keeper, got '${role}'" ;;
    esac
  done < "${INVENTORY_FILE}"

  check_dir APP_BASE "${APP_BASE}"
  check_dir REMOTE_RPM_DIR "${REMOTE_RPM_DIR}"
  [[ "${CH_USER}" =~ ${USER_RE} ]] || die "${INVENTORY_FILE}: CH_USER='${CH_USER}' is invalid (letters, digits, underscore)"
  [[ "${CH_USER}" != "default" ]] || die "${INVENTORY_FILE}: CH_USER must not be 'default' (already defined in users.xml)"
  [[ -n "${CH_PASSWORD}" ]] || die "${INVENTORY_FILE}: missing CH_PASSWORD=..."
  (( ${#CH_NODES[@]} >= 1 )) || die "${INVENTORY_FILE}: need at least 1 server line"
  (( ${#K_NODES[@]} % 2 == 1 )) || die "${INVENTORY_FILE}: keeper count must be odd (1, 3, 5...), got ${#K_NODES[@]}"

  ALL_NODES=("${CH_NODES[@]}" "${K_NODES[@]}")
  ALL_HOSTS=("${CH_HOSTS[@]}" "${K_HOSTS[@]}")
  for ((i = 0; i < ${#ALL_NODES[@]}; i++)); do
    for ((j = i + 1; j < ${#ALL_NODES[@]}; j++)); do
      [[ "${ALL_NODES[i]}" != "${ALL_NODES[j]}" ]] || die "${INVENTORY_FILE}: duplicate IP ${ALL_NODES[i]}"
      [[ "${ALL_HOSTS[i]}" != "${ALL_HOSTS[j]}" ]] || die "${INVENTORY_FILE}: duplicate hostname ${ALL_HOSTS[i]}"
    done
  done
}

host_of() {
  local i
  for ((i = 0; i < ${#ALL_NODES[@]}; i++)); do
    if [[ "${ALL_NODES[i]}" == "$1" ]]; then
      echo "${ALL_HOSTS[i]}"
      return 0
    fi
  done
  return 1
}

load_inventory

echo "==> Inventory: ${INVENTORY_FILE}"
echo "    APP_BASE=${APP_BASE}"
echo "    REMOTE_RPM_DIR=${REMOTE_RPM_DIR}"
echo "    CH_USER=${CH_USER} (CH_PASSWORD=***)"
for ((i = 0; i < ${#CH_NODES[@]}; i++)); do
  echo "    server ${CH_NODES[i]} ${CH_HOSTS[i]} (replica $((i + 1)))"
done
for ((i = 0; i < ${#K_NODES[@]}; i++)); do
  echo "    keeper ${K_NODES[i]} ${K_HOSTS[i]} (server_id $((i + 1)))"
done

# Nodes only store the sha256 of the password (password_sha256_hex)
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}
CH_PASSWORD_SHA256="$(sha256_hex "${CH_PASSWORD}")"
[[ "${CH_PASSWORD_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "Cannot compute sha256 of CH_PASSWORD"
unset CH_PASSWORD

###############################################################################
# APP PATH
###############################################################################
CH_ETC="${APP_BASE}/clickhouse-server"
CH_CFGD="${CH_ETC}/config.d"
CH_DATA="${APP_BASE}/data"
CH_LOG="${APP_BASE}/log"
CH_RUN="${APP_BASE}/run"
CH_TMP="${APP_BASE}/tmp"

KEEPER_ETC="${APP_BASE}/clickhouse-keeper"
KEEPER_DATA="${APP_BASE}/keeper/data"
KEEPER_LOG="${APP_BASE}/keeper/log"

###############################################################################
# SSH
###############################################################################
SSH_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# SSH_OPTS is word-split on purpose; remote commands are built on this side on purpose
# shellcheck disable=SC2086,SC2029
ssh_run() {
  ssh ${SSH_OPTS} "${SSH_USER}@${1}" "${@:2}"
}

# shellcheck disable=SC2086
scp_rpm() {
  scp ${SSH_OPTS} "${RPM_DIR}"/*.rpm "${SSH_USER}@${1}:${2}"
}

###############################################################################
# HOSTNAME + /etc/hosts
###############################################################################
HOSTS_BLOCK="$(for ((i = 0; i < ${#ALL_NODES[@]}; i++)); do echo "${ALL_NODES[i]} ${ALL_HOSTS[i]}"; done)"

# regex matching every cluster hostname (dots escaped) to drop old entries from /etc/hosts
HOSTS_RE="$(printf '%s\n' "${ALL_HOSTS[@]}" | sed 's/\./\\./g' | paste -sd'|' -)"

setup_hostname_and_hosts() {
  local ip="$1"
  local hn
  hn="$(host_of "$ip")"

  # Set hostname + fix /etc/hosts (remove old entries of cluster hostnames + add correct block)
  ssh_run "$ip" "
    set -euo pipefail

    echo '==> [${ip}] set hostname: ${hn}'
    hostnamectl set-hostname '${hn}' || true

    # remove old entries of cluster hostnames, keep loopback lines (idempotent)
    sed -i -E '/^[[:space:]]*(127\\.|::1)/!{/[[:space:]](${HOSTS_RE})([[:space:]]|\$)/d;}' /etc/hosts

    cat >> /etc/hosts <<'EOF'
${HOSTS_BLOCK}
EOF

    echo '==> [${ip}] verify hosts resolve'
    getent hosts ${ALL_HOSTS[*]} >/dev/null
  "
}

###############################################################################
# PORTS
###############################################################################
CH_NATIVE_PORT=9000
CH_HTTP_PORT=8123
KEEPER_CLIENT_PORT=9181
KEEPER_RAFT_PORT=9234

CLUSTER_NAME="cluster_1S_3R"

###############################################################################
# KEEPER ID (order of the keeper lines in the inventory)
###############################################################################
keeper_id() {
  local i
  for ((i = 0; i < ${#K_NODES[@]}; i++)); do
    if [[ "${K_NODES[i]}" == "$1" ]]; then
      echo $((i + 1))
      return 0
    fi
  done
  echo 0
}

###############################################################################
# XML TEMPLATES
###############################################################################
LISTEN_XML="
<clickhouse>
  <listen_host>0.0.0.0</listen_host>
</clickhouse>"

# Use hostnames instead of IPs to avoid DNS_ERROR in replication
CLUSTER_XML="$(
  echo "<clickhouse>"
  echo "  <remote_servers>"
  echo "    <${CLUSTER_NAME}>"
  echo "      <shard>"
  echo "        <internal_replication>true</internal_replication>"
  for hn in "${CH_HOSTS[@]}"; do
    echo "        <replica><host>${hn}</host><port>${CH_NATIVE_PORT}</port></replica>"
  done
  echo "      </shard>"
  echo "    </${CLUSTER_NAME}>"
  echo "  </remote_servers>"
  echo "</clickhouse>"
)"

# Use hostnames for keeper nodes
KEEPER_XML="$(
  echo "<clickhouse>"
  echo "  <zookeeper>"
  for hn in "${K_HOSTS[@]}"; do
    echo "    <node><host>${hn}</host><port>${KEEPER_CLIENT_PORT}</port></node>"
  done
  echo "  </zookeeper>"
  echo "</clickhouse>"
)"

PATH_XML="
<clickhouse>
  <path>${CH_DATA}/</path>
  <tmp_path>${CH_TMP}/</tmp_path>

  <logger>
    <log>${CH_LOG}/clickhouse-server.log</log>
    <errorlog>${CH_LOG}/clickhouse-server.err.log</errorlog>
  </logger>

  <pid_file>${CH_RUN}/clickhouse-server.pid</pid_file>
</clickhouse>
"

gen_keeper_xml() {
  local ip="$1"
  local sid i
  sid="$(keeper_id "$ip")"

cat <<EOF
<clickhouse>
  <logger>
    <level>information</level>
    <log>${KEEPER_LOG}/clickhouse-keeper.log</log>
    <errorlog>${KEEPER_LOG}/clickhouse-keeper.err.log</errorlog>
  </logger>

  <listen_host>0.0.0.0</listen_host>

  <keeper_server>
    <tcp_port>${KEEPER_CLIENT_PORT}</tcp_port>
    <server_id>${sid}</server_id>

    <log_storage_path>${KEEPER_DATA}/log</log_storage_path>
    <snapshot_storage_path>${KEEPER_DATA}/snapshots</snapshot_storage_path>

    <raft_configuration>
EOF
  for ((i = 0; i < ${#K_HOSTS[@]}; i++)); do
    echo "      <server><id>$((i + 1))</id><hostname>${K_HOSTS[i]}</hostname><port>${KEEPER_RAFT_PORT}</port></server>"
  done
cat <<EOF
    </raft_configuration>
  </keeper_server>
</clickhouse>
EOF
}

###############################################################################
# PRECHECK
###############################################################################
echo "==> Precheck RPM"
ls "${RPM_DIR}"/*.rpm >/dev/null

###############################################################################
# HOSTNAME + /etc/hosts
###############################################################################
echo "==> Setup hostname and /etc/hosts"
for ip in "${ALL_NODES[@]}"; do
  setup_hostname_and_hosts "$ip"
done

###############################################################################
# FIREWALL
###############################################################################
echo "==> Disable firewalld"
for ip in "${ALL_NODES[@]}"; do
  ssh_run "$ip" "systemctl stop firewalld || true; systemctl disable firewalld || true"
done

###############################################################################
# INSTALL RPM
###############################################################################
echo "==> Install RPMs"
for ip in "${ALL_NODES[@]}"; do
  ssh_run "$ip" "mkdir -p ${REMOTE_RPM_DIR}"
  scp_rpm "$ip" "${REMOTE_RPM_DIR}/"
  ssh_run "$ip" "rpm -Uvh --nodeps --force ${REMOTE_RPM_DIR}/*.rpm"
done

###############################################################################
# SETUP KEEPER
###############################################################################
echo "==> Setup Keeper"
for ip in "${K_NODES[@]}"; do
  ssh_run "$ip" "
    systemctl stop clickhouse-keeper || true
    mkdir -p ${KEEPER_ETC} ${KEEPER_DATA}/{log,snapshots} ${KEEPER_LOG}
    mkdir -p /etc/systemd/system/clickhouse-keeper.service.d
    chown -R clickhouse:clickhouse ${APP_BASE}
  "

  ssh_run "$ip" "cat > ${KEEPER_ETC}/keeper.xml <<'EOF'
$(gen_keeper_xml "$ip")
EOF"

  ssh_run "$ip" "
cat > /etc/systemd/system/clickhouse-keeper.service.d/override.conf <<EOF
[Service]
Type=simple
ExecStart=
ExecStart=/usr/bin/clickhouse-keeper --config-file=${KEEPER_ETC}/keeper.xml
Restart=always
RestartSec=5
EOF

systemctl daemon-reload
systemctl restart clickhouse-keeper
"
done

###############################################################################
# SETUP CLICKHOUSE SERVER
###############################################################################
echo "==> Setup ClickHouse Server"
replica_id=1

for ip in "${CH_NODES[@]}"; do
  ssh_run "$ip" "
    systemctl stop clickhouse-server || true
    mkdir -p ${CH_CFGD} ${CH_DATA} ${CH_LOG} ${CH_RUN} ${CH_TMP}
    mkdir -p /etc/systemd/system/clickhouse-server.service.d
    chown -R clickhouse:clickhouse ${APP_BASE}
  "

  ssh_run "$ip" "cp -f /etc/clickhouse-server/config.xml ${CH_ETC}/config.xml"
  ssh_run "$ip" "chown clickhouse:clickhouse ${CH_ETC}/config.xml && chmod 640 ${CH_ETC}/config.xml"
  ssh_run "$ip" "
  set -e
  CFG='${CH_ETC}/config.xml'
  sed -i 's#/var/lib/clickhouse#${APP_BASE}#g' \"\$CFG\"
  "
  ssh_run "$ip" "cat > ${CH_CFGD}/cluster.xml <<EOF
${CLUSTER_XML}
EOF"

  ssh_run "$ip" "cat > ${CH_CFGD}/keeper.xml <<EOF
${KEEPER_XML}
EOF"
  ssh_run "$ip" "cat > ${CH_CFGD}/zookeeper.xml <<EOF
${KEEPER_XML}
EOF"
  ssh_run "$ip" "mkdir -p ${CH_DATA} ${CH_TMP} ${CH_LOG} ${CH_RUN} && chown -R clickhouse:clickhouse ${APP_BASE}"
  ssh_run "$ip" "cat > '${CH_CFGD}/path.xml' <<'EOF'
${PATH_XML}
EOF"
  ssh_run "$ip" "cat > ${CH_CFGD}/listen.xml <<EOF
${LISTEN_XML}
EOF"

  ssh_run "$ip" "cat > ${CH_CFGD}/macros.xml <<EOF
<clickhouse>
  <macros>
    <shard>1</shard>
    <replica>${replica_id}</replica>
  </macros>
</clickhouse>
EOF"

  # users.xml
  ssh_run "$ip" "cat > ${CH_ETC}/users.xml <<'EOF'
<clickhouse>

  <users>
    <default>
      <password></password>
      <networks>
        <ip>::/0</ip>
      </networks>
      <profile>default</profile>
      <quota>default</quota>
    </default>
  </users>

  <profiles>
    <default>
      <max_memory_usage>0</max_memory_usage>
      <use_uncompressed_cache>0</use_uncompressed_cache>
      <load_balancing>random</load_balancing>
    </default>
  </profiles>

  <quotas>
    <default>
      <interval>
        <duration>3600</duration>
        <queries>0</queries>
        <errors>0</errors>
        <result_rows>0</result_rows>
        <read_rows>0</read_rows>
        <execution_time>0</execution_time>
      </interval>
    </default>
  </quotas>

</clickhouse>
EOF"
  ssh_run "$ip" "chown clickhouse:clickhouse ${CH_ETC}/users.xml && chmod 640 ${CH_ETC}/users.xml"

  # app user (CH_USER / CH_PASSWORD from inventory)
  ssh_run "$ip" "mkdir -p ${CH_ETC}/users.d"
  ssh_run "$ip" "cat > ${CH_ETC}/users.d/${CH_USER}.xml <<'EOF'
<clickhouse>
  <users>
    <${CH_USER}>
      <password_sha256_hex>${CH_PASSWORD_SHA256}</password_sha256_hex>
      <networks>
        <ip>::/0</ip>
      </networks>
      <profile>default</profile>
      <quota>default</quota>
      <access_management>1</access_management>
    </${CH_USER}>
  </users>
</clickhouse>
EOF"
  ssh_run "$ip" "chown clickhouse:clickhouse ${CH_ETC}/users.d/${CH_USER}.xml && chmod 640 ${CH_ETC}/users.d/${CH_USER}.xml"

  # systemd override
  ssh_run "$ip" "
cat > /etc/systemd/system/clickhouse-server.service.d/override.conf <<EOF
[Service]
Type=simple
ExecStart=
ExecStart=/usr/bin/clickhouse-server --config-file=${CH_ETC}/config.xml
Restart=always
RestartSec=5
EOF
systemctl daemon-reload
systemctl restart clickhouse-server
"

  ((replica_id++))
done

###############################################################################
# VERIFY
###############################################################################
echo "==> Verify listen"
ssh_run "${CH_NODES[0]}" "ss -lntp | egrep ':(${CH_NATIVE_PORT}|${CH_HTTP_PORT})\b'"

echo "==> Verify DNS from CH nodes"
for ip in "${CH_NODES[@]}"; do
  ssh_run "$ip" "hostname; getent hosts ${ALL_HOSTS[*]}"
done

echo "==> Verify cluster"
ssh_run "${CH_NODES[0]}" "clickhouse-client -q \"
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters
WHERE cluster='${CLUSTER_NAME}'
ORDER BY replica_num;
\""

###############################################################################
# DONE
###############################################################################
cat <<EOF

CLICKHOUSE 1S${#CH_NODES[@]}R + ${#K_NODES[@]} KEEPER READY
=================================
ALL PATH: ${APP_BASE}
INVENTORY: ${INVENTORY_FILE}
LOG FILE: ${LOG_FILE}

EOF
