# Functions embedded before bootstrap.sh in rendered user data.
retry() {
  local attempt
  for attempt in $(seq 1 24); do
    if "$@"; then return 0; fi
    sleep 10
  done
  return 1
}
prepare_data_directories() {
  local root=$1 directory
  test ! -L "$root" || return 1
  for directory in postgres redis files tls fixture backups; do
    test ! -L "$root/$directory" || return 1
    mkdir -p -- "$root/$directory" || return 1
    chmod 0700 "$root/$directory" || return 1
  done
}
