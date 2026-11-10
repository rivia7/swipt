#!/bin/sh
# Copies the scripts to the Mac and runs one se3.sh command there.
#
#   SE3_SSH=user@mac SE3_SSH_OPTS="-i $HOME/.ssh/swipt_mac_ed25519 -o IdentitiesOnly=yes" remote.sh COMMAND [ARGS...]
#   SE3_SSH=user@mac SE3_SSH_PASSWORD=... remote.sh COMMAND [ARGS...]
#
# Use a dedicated SSH key. Pass a password only in the command's environment and never write it to a file.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
HOST=${SE3_SSH:?set SE3_SSH to user@mac-address}
# SE3_SSH_OPTS comes first because ssh keeps the first value it sees for each option,
# so StrictHostKeyChecking=yes or a custom UserKnownHostsFile there wins over the defaults.
OPTS="${SE3_SSH_OPTS:-} -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

if [ -n "${SE3_SSH_PASSWORD:-}" ]; then
  ASKPASS=$(mktemp -t se3askpass)
  trap 'rm -f "$ASKPASS"' EXIT
  printf '#!/bin/sh\nprintf "%%s\\n" "$SE3_SSH_PASSWORD"\n' >"$ASKPASS"
  chmod 700 "$ASKPASS"
  SSH_ASKPASS=$ASKPASS
  SSH_ASKPASS_REQUIRE=force
  export SSH_ASKPASS SSH_ASKPASS_REQUIRE
  OPTS="$OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1"
fi

# se3.sh reads these on the Mac. They go into the remote command line, so only plain
# path and ID characters are allowed.
FORWARD=""
for name in SE3_SWIPT_SERVER SWIPT_TEAM; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || continue
  case $value in
    *[!A-Za-z0-9_./:~-]*) echo "remote.sh: $name may only contain letters, digits and _./:~-" >&2; exit 2 ;;
  esac
  FORWARD="$FORWARD $name=$value"
done

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar -C "$DIR" -czf - se3.sh device |
  ssh $OPTS -T "$HOST" 'mkdir -p ~/.swipt-se3 && tar -xzf - -C ~/.swipt-se3'
# shellcheck disable=SC2086
ssh $OPTS -T "$HOST" "$FORWARD zsh ~/.swipt-se3/se3.sh $*"
