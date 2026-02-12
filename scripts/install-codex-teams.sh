#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="jaycho46/codex-teams"
DEFAULT_VERSION="latest"
DEFAULT_INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/codex-teams"
DEFAULT_BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DEFAULT_VERIFY_CHECKSUM="1"
DEFAULT_VERIFY_SIGNATURE="0"

REPO="${CODEX_TEAMS_REPO:-$DEFAULT_REPO}"
VERSION="${CODEX_TEAMS_VERSION:-$DEFAULT_VERSION}"
INSTALL_ROOT="${CODEX_TEAMS_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
BIN_DIR="${CODEX_TEAMS_BIN_DIR:-$DEFAULT_BIN_DIR}"
VERIFY_CHECKSUM="${CODEX_TEAMS_VERIFY_CHECKSUM:-$DEFAULT_VERIFY_CHECKSUM}"
VERIFY_SIGNATURE="${CODEX_TEAMS_VERIFY_SIGNATURE:-$DEFAULT_VERIFY_SIGNATURE}"
FORCE=0

usage() {
  cat <<'USAGE'
Install codex-teams from GitHub releases.

Usage:
  install-codex-teams.sh [--repo <owner/repo>] [--version <vX.Y.Z|latest>] [--install-root <path>] [--bin-dir <path>] [--force] [--skip-checksum] [--verify-signature]

Examples:
  install-codex-teams.sh
  install-codex-teams.sh --version v0.1.1
  install-codex-teams.sh --version v0.1.1 --verify-signature
  install-codex-teams.sh --repo acme/codex-teams --bin-dir "$HOME/.local/bin"

Environment overrides:
  CODEX_TEAMS_REPO
  CODEX_TEAMS_VERSION
  CODEX_TEAMS_INSTALL_ROOT
  CODEX_TEAMS_BIN_DIR
  CODEX_TEAMS_VERIFY_CHECKSUM (1/0, true/false)
  CODEX_TEAMS_VERIFY_SIGNATURE (1/0, true/false)
USAGE
}

log() {
  echo "[install] $*"
}

die() {
  echo "[install] ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

to_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

normalize_bool() {
  local raw="${1:-}"
  local lower
  lower="$(to_lower "$raw")"
  case "$lower" in
    1|true|yes|on) echo 1 ;;
    0|false|no|off) echo 0 ;;
    *)
      die "Invalid boolean value: ${raw}"
      ;;
  esac
}

is_semver_tag() {
  [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*$ ]]
}

sha256_of_file() {
  local file_path="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file_path" | awk '{print $2}'
    return 0
  fi
  die "Unable to compute sha256. Install sha256sum, shasum, or openssl."
}

resolve_latest_tag() {
  local repo="${1:-}"
  local latest_url tag

  latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest")" \
    || die "Unable to resolve latest release for ${repo}"

  tag="${latest_url##*/}"
  is_semver_tag "$tag" || die "Invalid latest release tag: ${tag}"
  echo "$tag"
}

download_file() {
  local url="${1:-}"
  local output_path="${2:-}"
  log "Downloading ${url}"
  curl -fsSL "$url" -o "$output_path" || die "Failed to download: ${url}"
}

release_asset_url() {
  local repo="${1:-}"
  local tag="${2:-}"
  local asset="${3:-}"
  echo "https://github.com/${repo}/releases/download/${tag}/${asset}"
}

verify_tarball_checksum() {
  local checksum_file="${1:-}"
  local tarball_url="${2:-}"
  local archive_path="${3:-}"
  local expected actual

  expected="$(awk -v target="$tarball_url" '$2 == target {print $1; exit}' "$checksum_file")"
  if [[ -z "$expected" ]]; then
    expected="$(awk '$2 == "source.tar.gz" {print $1; exit}' "$checksum_file")"
  fi
  [[ -n "$expected" ]] || die "No matching checksum entry found for source tarball."

  actual="$(sha256_of_file "$archive_path")"
  [[ "$actual" == "$expected" ]] || die "Checksum mismatch for source tarball. expected=${expected} actual=${actual}"
}

verify_checksums_signature() {
  local repo="${1:-}"
  local checksum_file="${2:-}"
  local sig_file="${3:-}"
  local cert_file="${4:-}"
  local identity_regex

  need_cmd cosign
  identity_regex="^https://github.com/${repo}/\\.github/workflows/release\\.yml@.*$"

  cosign verify-blob \
    --certificate "$cert_file" \
    --signature "$sig_file" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    --certificate-identity-regexp "$identity_regex" \
    "$checksum_file" >/dev/null \
    || die "Cosign signature verification failed for SHA256SUMS."
}

write_launcher() {
  local launcher="${1:-}"
  local install_root="${2:-}"

  mkdir -p "$(dirname "$launcher")"
  {
    echo "#!/usr/bin/env bash"
    echo "set -euo pipefail"
    printf "INSTALL_ROOT=%q\n" "$install_root"
    echo 'exec "${INSTALL_ROOT}/current/scripts/codex-teams" "$@"'
  } > "$launcher"
  chmod +x "$launcher"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      shift || true
      [[ $# -gt 0 ]] || die "Missing value for --repo"
      REPO="$1"
      ;;
    --version)
      shift || true
      [[ $# -gt 0 ]] || die "Missing value for --version"
      VERSION="$1"
      ;;
    --install-root)
      shift || true
      [[ $# -gt 0 ]] || die "Missing value for --install-root"
      INSTALL_ROOT="$1"
      ;;
    --bin-dir)
      shift || true
      [[ $# -gt 0 ]] || die "Missing value for --bin-dir"
      BIN_DIR="$1"
      ;;
    --force)
      FORCE=1
      ;;
    --skip-checksum)
      VERIFY_CHECKSUM=0
      ;;
    --verify-signature)
      VERIFY_SIGNATURE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift || true
done

[[ "$REPO" == */* ]] || die "--repo must be in owner/repo format"
VERIFY_CHECKSUM="$(normalize_bool "$VERIFY_CHECKSUM")"
VERIFY_SIGNATURE="$(normalize_bool "$VERIFY_SIGNATURE")"

if [[ "$VERIFY_SIGNATURE" -eq 1 ]]; then
  VERIFY_CHECKSUM=1
fi

need_cmd curl
need_cmd tar
need_cmd mktemp

if [[ "$VERSION" == "latest" ]]; then
  VERSION="$(resolve_latest_tag "$REPO")"
elif [[ "$VERSION" != v* ]]; then
  VERSION="v${VERSION}"
fi

is_semver_tag "$VERSION" || die "Invalid --version value: ${VERSION}"

target_dir="${INSTALL_ROOT}/${VERSION}"
if [[ -e "$target_dir" && "$FORCE" -ne 1 ]]; then
  die "Version already installed at ${target_dir}. Use --force to overwrite."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

archive_path="${tmp_dir}/source.tar.gz"
tarball_url="https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz"
download_file "$tarball_url" "$archive_path"

if [[ "$VERIFY_CHECKSUM" -eq 1 ]]; then
  checksums_path="${tmp_dir}/SHA256SUMS"
  download_file "$(release_asset_url "$REPO" "$VERSION" "SHA256SUMS")" "$checksums_path"

  if [[ "$VERIFY_SIGNATURE" -eq 1 ]]; then
    checksum_sig_path="${tmp_dir}/SHA256SUMS.sig"
    checksum_cert_path="${tmp_dir}/SHA256SUMS.pem"
    download_file "$(release_asset_url "$REPO" "$VERSION" "SHA256SUMS.sig")" "$checksum_sig_path"
    download_file "$(release_asset_url "$REPO" "$VERSION" "SHA256SUMS.pem")" "$checksum_cert_path"
    verify_checksums_signature "$REPO" "$checksums_path" "$checksum_sig_path" "$checksum_cert_path"
    log "Signature verification passed."
  fi

  verify_tarball_checksum "$checksums_path" "$tarball_url" "$archive_path"
  log "Checksum verification passed."
fi

tar -xzf "$archive_path" -C "$tmp_dir" || die "Failed to extract tarball"
source_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$source_dir" ]] || die "Unable to resolve extracted source directory"
[[ -x "${source_dir}/scripts/codex-teams" ]] || die "Release payload missing scripts/codex-teams"

mkdir -p "$INSTALL_ROOT"
rm -rf "${target_dir}.tmp"
mkdir -p "${target_dir}.tmp"
cp -R "${source_dir}/scripts" "${target_dir}.tmp/" || die "Failed to copy scripts payload"
rm -rf "$target_dir"
mv "${target_dir}.tmp" "$target_dir"
ln -sfn "$target_dir" "${INSTALL_ROOT}/current"

launcher_path="${BIN_DIR}/codex-teams"
write_launcher "$launcher_path" "$INSTALL_ROOT"

log "Installed version: ${VERSION}"
log "Install root: ${target_dir}"
log "Launcher: ${launcher_path}"

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
  log "PATH does not include ${BIN_DIR}"
  log "Add this line to your shell profile:"
  log "  export PATH=\"${BIN_DIR}:\$PATH\""
fi

log "Run: codex-teams --help"
