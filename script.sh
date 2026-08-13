#!/usr/bin/env bash
# =============================================================================
#  Hadoop + Hive Single-Node Installation Script for Ubuntu
#  Stable, battle-tested stack:
#    - Hadoop 2.8.5
#    - Hive  3.1.3
#    - OpenJDK 8 (Temurin)
#  Installs everything, starts services and runs end-to-end tests.
#
#  Usage:
#    sudo bash script.sh
#    or via curl:
#    curl -fsSL <RAW_URL> | sudo bash
# =============================================================================

set -euo pipefail

# ---------------------------- Configurable ----------------------------------
HADOOP_VERSION="2.8.5"
HIVE_VERSION="3.1.3"
HADOOP_USER="hadoop"
HADOOP_GROUP="hadoop"

INSTALL_DIR="/opt"
HADOOP_HOME="${INSTALL_DIR}/hadoop"
HIVE_HOME="${INSTALL_DIR}/hive"

HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz"
HIVE_URL="https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz"

NAMENODE_UI="http://localhost:50070"
YARN_UI="http://localhost:8088"

# ---------------------------- Helpers ----------------------------------------
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Please run as root:  sudo bash $0"
  fi
}

check_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This script is designed for Ubuntu (detected: ${ID:-unknown})."
  fi
  log "Detected ${PRETTY_NAME:-Ubuntu} (${VERSION_CODENAME:-})"
}

# ---------------------------- Installation -----------------------------------
install_packages() {
  log "Installing system packages..."
  export DEBIAN_FRONTEND=noninteractive

  # Remove any stale Adoptium repo from a previous failed run
  rm -f /etc/apt/sources.list.d/adoptium.list

  # Wait for any running apt/dpkg processes (e.g. unattended-upgrades) to finish
  local wait_count=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if (( wait_count == 0 )); then
      warn "Waiting for another package manager to finish (unattended-upgrades?)..."
    fi
    sleep 5
    (( wait_count++ ))
    if (( wait_count >= 60 )); then
      die "Timed out waiting for dpkg lock after 5 minutes. Kill unattended-upgrades and retry."
    fi
  done

  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg apt-transport-https lsb-release \
    openssh-server openssh-client ssh vim net-tools \
    pdsh || warn "pdsh not available on this release, will use plain ssh"

  # sshd must be running so Hadoop daemons can connect to localhost
  systemctl enable --now ssh 2>/dev/null || service ssh start 2>/dev/null || true
}

install_java8() {
  if java -version 2>&1 | grep -q '1\.8'; then
    log "Java 8 already installed: $(java -version 2>&1 | head -1)"
    return
  fi

  log "Installing Temurin OpenJDK 8 (Adoptium repo)..."
  mkdir -p /etc/apt/keyrings
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg

  # Determine a codename that Adoptium actually supports
  local codename
  codename="$(lsb_release -cs 2>/dev/null || echo jammy)"
  local repo_url="https://packages.adoptium.net/artifactory/deb/dists/${codename}/Release"
  if ! wget -q --spider "${repo_url}" 2>/dev/null; then
    warn "Adoptium repo has no packages for '${codename}', falling back to 'jammy' (22.04 LTS)."
    codename="jammy"
  fi

  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${codename} main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -y
  apt-get install -y temurin-8-jdk

  # Make Java 8 the system default (high priority to beat any pre-installed JDK)
  local jdkdir
  jdkdir="$(ls -d /usr/lib/jvm/temurin-8-jdk-* 2>/dev/null | head -1)"
  if [[ -n "${jdkdir}" ]]; then
    update-alternatives --install /usr/bin/java java "${jdkdir}/bin/java" 1081 || true
    update-alternatives --install /usr/bin/javac javac "${jdkdir}/bin/javac" 1081 || true
    update-alternatives --set java "${jdkdir}/bin/java" 2>/dev/null || true
    update-alternatives --set javac "${jdkdir}/bin/javac" 2>/dev/null || true
  fi
  java -version 2>&1 | head -1 || die "Java 8 installation failed."
  # Verify we actually got Java 8 (not 9+)
  if ! java -version 2>&1 | grep -q '"1\.8'; then
    die "Java 8 is not the default. Found: $(java -version 2>&1 | head -1). Remove other JDKs or fix alternatives."
  fi
}

setup_hadoop_user() {
  if ! id -u "${HADOOP_USER}" &>/dev/null; then
    log "Creating user '${HADOOP_USER}'..."
    useradd -m -s /bin/bash -U "${HADOOP_USER}"
  fi
  echo "${HADOOP_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${HADOOP_USER}
  chmod 440 /etc/sudoers.d/${HADOOP_USER}
}

download_and_extract() {
  local name="$1" url="$2" dest="$3" tmpdir
  if [[ -d "${dest}" ]]; then
    log "${name} already present at ${dest}, skipping download."
    return
  fi
  tmpdir="$(mktemp -d)"
  log "Downloading ${name} from ${url} ..."
  wget -q --show-progress -O "${tmpdir}/archive.tar.gz" "${url}" \
    || wget -q -O "${tmpdir}/archive.tar.gz" "${url}" \
    || die "Failed to download ${name}. Check network access to archive.apache.org."
  log "Extracting ${name} ..."
  tar -xzf "${tmpdir}/archive.tar.gz" -C "${INSTALL_DIR}"
  rm -rf "${tmpdir}"

  local extracted
  case "${name}" in
    hadoop) extracted="${INSTALL_DIR}/hadoop-${HADOOP_VERSION}" ;;
    hive)   extracted="${INSTALL_DIR}/apache-hive-${HIVE_VERSION}-bin" ;;
  esac
  mv "${extracted}" "${dest}"
  chown -R "${HADOOP_USER}:${HADOOP_GROUP}" "${dest}"
}

# ---------------------------- Configuration ----------------------------------
setup_env() {
  log "Writing environment to /etc/profile.d/bigdata.sh ..."

  # Resolve JAVA_HOME: prefer known Temurin path, fall back to dynamic lookup
  local resolved_java_home
  resolved_java_home="$(ls -d /usr/lib/jvm/temurin-8-jdk-* 2>/dev/null | head -1)"
  if [[ -z "${resolved_java_home}" ]]; then
    resolved_java_home="\$(dirname \$(dirname \$(readlink -f \$(which java))))"
  fi

  cat > /etc/profile.d/bigdata.sh <<EOF
export JAVA_HOME="${resolved_java_home}"
export HADOOP_HOME="${HADOOP_HOME}"
export HADOOP_CONF_DIR="${HADOOP_HOME}/etc/hadoop"
export HADOOP_MAPRED_HOME="${HADOOP_HOME}"
export HIVE_HOME="${HIVE_HOME}"
export PATH="\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${HIVE_HOME}/bin:\${PATH}"
export PDSH_RCMD_TYPE=ssh
EOF
  # shellcheck source=/dev/null
  . /etc/profile.d/bigdata.sh
  grep -q 'bigdata.sh' /home/${HADOOP_USER}/.bashrc \
    || echo ". /etc/profile.d/bigdata.sh" >> /home/${HADOOP_USER}/.bashrc
}

configure_hadoop() {
  log "Configuring Hadoop (${HADOOP_VERSION}) ..."
  local ETC="${HADOOP_HOME}/etc/hadoop"
  mkdir -p /home/${HADOOP_USER}/hadoop-data/{namenode,datanode,tmp}
  chown -R "${HADOOP_USER}:${HADOOP_GROUP}" /home/${HADOOP_USER}/hadoop-data

  cat > "${ETC}/core-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
  <property><name>hadoop.tmp.dir</name><value>/home/${HADOOP_USER}/hadoop-data/tmp</value></property>
</configuration>
EOF

  cat > "${ETC}/hdfs-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>dfs.replication</name><value>1</value></property>
  <property><name>dfs.namenode.name.dir</name><value>/home/${HADOOP_USER}/hadoop-data/namenode</value></property>
  <property><name>dfs.datanode.data.dir</name><value>/home/${HADOOP_USER}/hadoop-data/datanode</value></property>
  <property><name>dfs.permissions.enabled</name><value>false</value></property>
</configuration>
EOF

  cat > "${ETC}/mapred-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>mapreduce.framework.name</name><value>yarn</value></property>
  <property><name>mapreduce.application.classpath</name><value>\$HADOOP_HOME/share/hadoop/mapreduce/*:\$HADOOP_HOME/share/hadoop/mapreduce/lib/*</value></property>
</configuration>
EOF

  cat > "${ETC}/yarn-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
  <property><name>yarn.nodemanager.aux-services.mapreduce_shuffle.class</name><value>org.apache.hadoop.mapred.ShuffleHandler</value></property>
  <property><name>yarn.nodemanager.resource.memory-mb</name><value>2048</value></property>
</configuration>
EOF

  echo "localhost" > "${ETC}/slaves"
  echo "localhost" > "${ETC}/masters"

  # Point Hadoop at Java 8 explicitly
  local jh
  jh="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=${jh}|" "${ETC}/hadoop-env.sh" 2>/dev/null || true
  grep -q '^export JAVA_HOME=' "${ETC}/hadoop-env.sh" \
    || echo "export JAVA_HOME=${jh}" >> "${ETC}/hadoop-env.sh"
}

configure_hive() {
  log "Configuring Hive (${HIVE_VERSION}) ..."

  # Classic guava conflict fix between Hive 3.x and Hadoop 2.x
  # Remove Hive's bundled guava and copy Hadoop's version (filename varies by build)
  rm -f "${HIVE_HOME}"/lib/guava-*.jar
  local hadoop_guava
  hadoop_guava="$(ls "${HADOOP_HOME}"/share/hadoop/common/lib/guava-*.jar 2>/dev/null | head -1)"
  if [[ -n "${hadoop_guava}" ]]; then
    cp "${hadoop_guava}" "${HIVE_HOME}/lib/"
    log "Copied $(basename "${hadoop_guava}") to Hive lib."
  else
    warn "Could not find Hadoop's guava jar — Hive may have classpath issues."
  fi

  mkdir -p /home/${HADOOP_USER}/hive-metastore
  chown -R "${HADOOP_USER}:${HADOOP_GROUP}" /home/${HADOOP_USER}/hive-metastore

  # Force Hive to use Java 8 explicitly (prevents Java 9+ ClassLoader crash)
  local jdkdir
  jdkdir="$(ls -d /usr/lib/jvm/temurin-8-jdk-* 2>/dev/null | head -1)"
  cat > "${HIVE_HOME}/conf/hive-env.sh" <<EOF
export JAVA_HOME="${jdkdir}"
export HADOOP_HOME="${HADOOP_HOME}"
EOF

  cat > "${HIVE_HOME}/conf/hive-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:derby:;databaseName=/home/${HADOOP_USER}/hive-metastore/metastore_db;create=true</value></property>
  <property><name>javax.jdo.option.ConnectionDriverName</name><value>org.apache.derby.jdbc.EmbeddedDriver</value></property>
  <property><name>hive.metastore.warehouse.dir</name><value>hdfs://localhost:9000/user/hive/warehouse</value></property>
  <property><name>hive.metastore.schema.verification</name><value>false</value></property>
  <property><name>datanucleus.schema.autoCreateAll</name><value>true</value></property>
</configuration>
EOF
}

setup_ssh() {
  log "Setting up passwordless SSH for user '${HADOOP_USER}' ..."
  local key=/home/${HADOOP_USER}/.ssh/id_rsa
  local auth=/home/${HADOOP_USER}/.ssh/authorized_keys
  mkdir -p /home/${HADOOP_USER}/.ssh
  chown "${HADOOP_USER}:${HADOOP_GROUP}" /home/${HADOOP_USER}/.ssh
  chmod 700 /home/${HADOOP_USER}/.ssh
  if [[ ! -f "${key}" ]]; then
    su - "${HADOOP_USER}" -c "ssh-keygen -t rsa -P '' -f ${key}"
  fi

  # Append public key only if not already present (idempotent)
  if ! grep -qF "$(cat "${key}.pub")" "${auth}" 2>/dev/null; then
    cat "${key}.pub" >> "${auth}"
  fi

  chown -R "${HADOOP_USER}:${HADOOP_GROUP}" /home/${HADOOP_USER}/.ssh
  chmod 700 /home/${HADOOP_USER}/.ssh
  chmod 600 "${auth}"

  su - "${HADOOP_USER}" -c "ssh-keyscan -H localhost >> /home/${HADOOP_USER}/.ssh/known_hosts 2>/dev/null || true"
  su - "${HADOOP_USER}" -c "ssh-keyscan -H 0.0.0.0 >> /home/${HADOOP_USER}/.ssh/known_hosts 2>/dev/null || true"

  # Verify passwordless ssh works
  su - "${HADOOP_USER}" -c "ssh -o StrictHostKeyChecking=no -o BatchMode=yes localhost 'echo ssh-ok'" \
    >/dev/null 2>&1 || die "Passwordless SSH to localhost failed for ${HADOOP_USER}."
  log "Passwordless SSH verified."
}

# ---------------------------- Services ----------------------------------------
format_namenode() {
  if [[ -d /home/${HADOOP_USER}/hadoop-data/namenode/current ]]; then
    log "NameNode already formatted, skipping."
    return
  fi
  log "Formatting NameNode ..."
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && hdfs namenode -format -force" \
    >/dev/null || die "NameNode format failed."
}

start_services() {
  log "Starting HDFS and YARN daemons ..."
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && ${HADOOP_HOME}/sbin/start-dfs.sh && ${HADOOP_HOME}/sbin/start-yarn.sh"

  # Wait for NameNode to leave safe mode (up to 60 seconds)
  log "Waiting for NameNode to leave safe mode ..."
  local retries=0
  while (( retries < 12 )); do
    if su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && hdfs dfsadmin -safemode get 2>/dev/null" \
         | grep -q 'OFF'; then
      break
    fi
    sleep 5
    (( retries++ ))
  done
  if (( retries >= 12 )); then
    warn "NameNode did not leave safe mode within 60s — continuing anyway."
  fi

  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && jps"
}

create_hive_hdfs_dirs() {
  log "Creating HDFS directories for Hive ..."
  su - "${HADOOP_USER}" -c "
    . /etc/profile.d/bigdata.sh
    hdfs dfs -mkdir -p /tmp
    hdfs dfs -chmod 1777 /tmp
    hdfs dfs -mkdir -p /user/hive/warehouse
    hdfs dfs -chmod 775 /user/hive/warehouse
    hdfs dfs -mkdir -p /user/${HADOOP_USER}
  "
}

init_hive_schema() {
  # Skip if Derby metastore already exists
  if [[ -d /home/${HADOOP_USER}/hive-metastore/metastore_db ]]; then
    log "Hive metastore DB already exists, skipping schema init."
    return
  fi
  log "Initializing Hive metastore schema (Derby) ..."
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && schematool -dbType derby -initSchema" \
    >/tmp/schematool.log 2>&1 || { warn "schematool exit code $? (may already be initialized)"; }
}

# ---------------------------- Tests -------------------------------------------
test_hdfs() {
  log "== TEST 1: HDFS basic operations =="
  local sample=/tmp/hadoop-test-data.txt
  {
    echo "hadoop-test-file generated $(date)"
    echo "hostname: $(hostname)"
    seq 1 100
  } > "${sample}"

  su - "${HADOOP_USER}" -c "
    . /etc/profile.d/bigdata.sh
    hdfs dfs -mkdir -p /user/${HADOOP_USER}/test
    hdfs dfs -put -f ${sample} /user/${HADOOP_USER}/test/data.txt
    hdfs dfs -cat /user/${HADOOP_USER}/test/data.txt | diff - ${sample}
    hdfs dfs -ls -R /user/${HADOOP_USER}/test
  " || die "HDFS test FAILED"
  log "HDFS test PASSED (100-line file written, read back and verified identical)."

  log "== TEST 2: HDFS health =="
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && hdfs dfsadmin -report" \
    | grep -E "Name:|Hostname:|Live datanodes" | head -5
}

test_hive() {
  log "== TEST 3: Hive end-to-end (create/load/select) =="

  # Create a small CSV test file to load (avoids ACID/INSERT VALUES issues)
  local testcsv=/tmp/hive_test_data.csv
  printf '1,Alice\n2,Bob\n3,Charlie\n' > "${testcsv}"
  chown "${HADOOP_USER}:${HADOOP_GROUP}" "${testcsv}"

  su - "${HADOOP_USER}" -c "
    . /etc/profile.d/bigdata.sh
    hive --database default -e \"
      DROP TABLE IF EXISTS students;
      CREATE TABLE students(id INT, name STRING) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',';
      LOAD DATA LOCAL INPATH '${testcsv}' INTO TABLE students;
      SELECT id, name FROM students ORDER BY id;
      DROP TABLE students;
    \"
  " > /tmp/hive-test.log 2>&1 || die "Hive test FAILED (see /tmp/hive-test.log)"
  grep -E 'Alice|Bob|Charlie' /tmp/hive-test.log \
    || die "Hive test FAILED: expected rows not found in output."
  log "Hive test PASSED (table created, data loaded, queried, dropped)."
}

verify_all() {
  log "== TEST 4: Daemon processes =="
  local procs
  procs=$(su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && jps")
  echo "$procs"
  for p in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
    echo "$procs" | grep -q "${p}" || warn "Missing process: ${p}"
  done

  log "== TEST 5: Version checks =="
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && hadoop version | head -1"
  su - "${HADOOP_USER}" -c ". /etc/profile.d/bigdata.sh && hive --version 2>/dev/null | head -1"
  java -version 2>&1 | head -1
}

create_helper_scripts() {
  cat > /usr/local/bin/start-hadoop <<'EOF'
#!/usr/bin/env bash
su - hadoop -c ". /etc/profile.d/bigdata.sh && \$HADOOP_HOME/sbin/start-dfs.sh && \$HADOOP_HOME/sbin/start-yarn.sh"
EOF
  cat > /usr/local/bin/stop-hadoop <<'EOF'
#!/usr/bin/env bash
su - hadoop -c ". /etc/profile.d/bigdata.sh && \$HADOOP_HOME/sbin/stop-yarn.sh && \$HADOOP_HOME/sbin/stop-dfs.sh"
EOF
  chmod +x /usr/local/bin/start-hadoop /usr/local/bin/stop-hadoop
  log "Helper scripts: 'start-hadoop' / 'stop-hadoop' (run with sudo)."
}

print_summary() {
  echo
  echo "============================================================"
  echo "  INSTALLATION COMPLETE — everything tested and working"
  echo "============================================================"
  echo "  Hadoop ${HADOOP_VERSION}  ->  ${HADOOP_HOME}"
  echo "  Hive   ${HIVE_VERSION}   ->  ${HIVE_HOME}"
  echo "  Java:   $(java -version 2>&1 | head -1)"
  echo
  echo "  NameNode UI : ${NAMENODE_UI}"
  echo "  YARN UI     : ${YARN_UI}"
  echo
  echo "  Start/stop  : sudo start-hadoop  /  sudo stop-hadoop"
  echo "  HDFS shell  : sudo su - hadoop  ->  hdfs dfs -ls /"
  echo "  Hive shell  : sudo su - hadoop  ->  hive"
  echo "============================================================"
}

# ---------------------------- Main --------------------------------------------
main() {
  need_root
  check_os
  install_packages
  install_java8
  setup_hadoop_user
  download_and_extract "hadoop" "${HADOOP_URL}" "${HADOOP_HOME}"
  download_and_extract "hive" "${HIVE_URL}" "${HIVE_HOME}"
  setup_env
  configure_hadoop
  configure_hive
  setup_ssh
  format_namenode
  start_services
  create_hive_hdfs_dirs
  init_hive_schema
  test_hdfs
  test_hive
  verify_all
  create_helper_scripts
  print_summary
}

main "$@" </dev/null
