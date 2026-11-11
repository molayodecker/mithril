#!/usr/bin/env bash
# Installs psql and pg_isready for schema apply.
# GitHub-hosted runners sometimes cannot resolve the Ubuntu package mirrors.
# When apt cannot reach them, this installs a checksum-pinned client build
# that was already fetched from GitHub in the same way as flyctl.
set -euo pipefail

version="18.6.1"
asset="postgresql-${version}-x86_64-unknown-linux-gnu.tar.gz"
expected_sha="e84b02dd8d0ce5879fb697330a789231c8b8f8d958dae3ad4d90fecc710b1315"
download_url="https://github.com/theseus-rs/postgresql-binaries/releases/download/${version}/${asset}"

client_ready() {
  command -v psql >/dev/null && command -v pg_isready >/dev/null
}

mirror_resolves() {
  timeout 5 getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1
}

use_public_dns() {
  echo "Default DNS cannot resolve archive.ubuntu.com; switching to public resolvers." >&2
  if [[ -L /etc/resolv.conf ]]; then
    sudo rm -f /etc/resolv.conf
  fi
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null
}

install_with_apt() {
  local apt_opts=(-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2)
  sudo apt-get "${apt_opts[@]}" update
  sudo apt-get "${apt_opts[@]}" install -y postgresql-client
}

publish_client_path() {
  local bindir="$1"
  local libdir="$2"
  export PATH="${bindir}:${PATH}"
  export LD_LIBRARY_PATH="${libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$bindir" >>"$GITHUB_PATH"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >>"$GITHUB_ENV"
  fi
}

install_pinned_client() {
  local dest archive prefix bindir libdir
  dest="${RUNNER_TEMP:-/tmp}/postgresql-client"
  archive="${dest}/${asset}"
  prefix="${dest}/postgresql-${version}-x86_64-unknown-linux-gnu"
  bindir="${prefix}/bin"
  libdir="${prefix}/lib"
  mkdir -p "$dest"
  echo "Installing pinned PostgreSQL ${version} client from GitHub." >&2
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$archive" "$download_url"
  echo "${expected_sha}  ${archive}" | sha256sum -c -
  tar -xzf "$archive" -C "$dest" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/bin/psql" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/bin/pg_isready" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libpq.so" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libpq.so.5" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libpq.so.5.18" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libssl.so.3" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libcrypto.so.3" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libgssapi_krb5.so.2" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libkrb5.so.3" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libk5crypto.so.3" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libcom_err.so.2" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libkrb5support.so.0" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libreadline.so.8" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libtinfo.so.6" \
    "postgresql-${version}-x86_64-unknown-linux-gnu/lib/libz.so.1"
  publish_client_path "$bindir" "$libdir"
}

if client_ready; then
  psql --version
  pg_isready --version
  exit 0
fi

if ! mirror_resolves; then
  use_public_dns || true
fi

if mirror_resolves && install_with_apt; then
  hash -r
  psql --version
  pg_isready --version
  exit 0
fi

echo "Ubuntu package mirrors are unreachable; using the pinned client." >&2
install_pinned_client
psql --version
pg_isready --version
