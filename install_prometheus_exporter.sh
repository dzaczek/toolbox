#!/usr/bin/env bash
set -euo pipefail

EXPORTER_USER="node_exporter"
BIN_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/node_exporter.service"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root or with sudo."
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    ppc64le) ARCH="ppc64le" ;;
    s390x) ARCH="s390x" ;;
    *)
      echo "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl tar
}

get_latest_version() {
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest)"
  VERSION="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"

  if [[ -z "${VERSION}" ]]; then
    echo "Could not detect latest node_exporter version."
    exit 1
  fi

  echo "Latest version: ${VERSION}"
}

create_user() {
  if ! id -u "${EXPORTER_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${EXPORTER_USER}"
  fi
}

download_and_install() {
  TMP_DIR="$(mktemp -d)"
  ARCHIVE="node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
  URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${ARCHIVE}"

  echo "Downloading ${URL}"
  curl -fL "${URL}" -o "${TMP_DIR}/${ARCHIVE}"
  tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"

  install -m 0755 "${TMP_DIR}/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" "${BIN_DIR}/node_exporter"
  rm -rf "${TMP_DIR}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

enable_and_start() {
  systemctl daemon-reload
  systemctl enable --now node_exporter
}

show_status() {
  echo
  echo "Binary version:"
  /usr/local/bin/node_exporter --version || true

  echo
  echo "Service:"
  systemctl --no-pager --full status node_exporter || true

  echo
  echo "Metrics check:"
  curl -fsSL http://127.0.0.1:9100/metrics | sed -n '1,10p'
}

main() {
  require_root
  detect_arch
  install_packages
  get_latest_version
  create_user
  download_and_install
  write_service
  enable_and_start
  show_status
}

main "$@"
