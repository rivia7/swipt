#!/bin/zsh
# Sets up an iPhone SE 3 for wireless agent control through the Swipt app and LocalDevVPN.
# Runs on the Mac the phone is plugged into. SKILL.md gives the order of the steps.
#
#   se3.sh preflight    [UDID]              checks the Mac and the phone; without a UDID, lists the phones
#   se3.sh fix-wwdr                         installs Apple's WWDR G3 certificate (desktop only)
#   se3.sh prepare      UDID                Auto-Lock Never, StandBy off, VPN off, disk image mounted
#   se3.sh install      UDID [TYPE]         signs and installs Swipt, asks for the passcode (desktop only)
#   se3.sh post         UDID                VPN on, API token on, saves the Wi-Fi endpoint
#   se3.sh verify       UDID [--lock-test]  checks the phone over Wi-Fi
#   se3.sh vpn          UDID on|off         connects or disconnects LocalDevVPN over USB
#   se3.sh renew        UDID                renews the signing (desktop only)
#   se3.sh auto-renew   [--check]           renews every saved phone that is due (desktop only; --check only reports)
#   se3.sh schedule     on|off|status       runs auto-renew twice a day from a LaunchAgent (on: desktop only)
#   se3.sh status       [UDID]              network, API port and signing for one or every saved phone

[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
SCRIPT_DIR=${0:A:h}
CFG=${SE3_CONFIG_DIR:-$HOME/.config/swipt-se3}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
team=(${SWIPT_TEAM:+--team} $SWIPT_TEAM)
AGENT=io.swipt.se3.auto-renew
umask 077
mkdir -p $CFG/devices $CFG/logs $CFG/cli

ok()   { print -- "OK    $*" }
warn() { print -- "WARN  $*" }
info() { print -- "      $*" }
die()  { print -u2 -- "FAIL  $*"; exit 1 }
bounded() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@" }
mask() { sed -E 's#http://[^@ "]*@#http://<token>@#g' }
json_field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2" }

server_binary() {
  local c
  for c in "$SE3_SWIPT_SERVER" "$HOME/swipt-dev/swipt-lb/build/swipt-server" "$HOME/swipt-dev/swipt/build/swipt-server"; do
    [[ -n $c && -x $c ]] && { print -- $c; return 0 }
  done
  c=$(print -l "$(npm root -g)"/@swipt/cli/node_modules/@swipt/server-darwin-*/swipt-server(N) | head -1)
  [[ -n $c && -x $c ]] && { print -- $c; return 0 }
  return 1
}

SERVER_PID=""
SERVER_URL=""
stop_server() {
  [[ -z $SERVER_PID ]] && return
  kill $SERVER_PID 2>/dev/null
  local i
  for i in {1..80}; do
    kill -0 $SERVER_PID 2>/dev/null || { SERVER_PID=""; return }
    sleep 0.25
  done
  kill -9 $SERVER_PID 2>/dev/null
  SERVER_PID=""
}
trap stop_server EXIT

# The server talks to the phone over usbmuxd. It runs under its own HOME so that
# these short sessions leave nothing in the user's Swipt state.
start_server() {
  local udid=$1 bin out=$CFG/logs/$udid.out err=$CFG/logs/$udid.err port="" i code
  bin=$(server_binary) || die "no swipt-server found; install it with: npm install -g @swipt/cli --include=optional"
  mkdir -p $CFG/server-home
  : >$out; : >$err
  env HOME=$CFG/server-home $bin -d $udid >$out 2>$err &
  SERVER_PID=$!
  for i in {1..120}; do
    port=$(sed -n 's/^Swipt API: .*:\([0-9]*\)$/\1/p' $out)
    [[ -n $port ]] && break
    if ! kill -0 $SERVER_PID 2>/dev/null; then
      wait $SERVER_PID; code=$?; SERVER_PID=""
      if (( code == 3 )); then
        die "usbmuxd does not list $udid. Re-plug its cable; if that fails, see references/troubleshooting.md"
      fi
      die "swipt-server exited with $code: $(tail -1 $err | cut -c1-200)"
    fi
    sleep 0.25
  done
  [[ -n $port ]] || die "swipt-server printed no address within 30 s"
  SERVER_URL=http://127.0.0.1:$port
  sleep 6
}

# Runs scripts/device/NAME.js on the phone; a final "RESULT {json}" line lands in $RESULT.
RESULT=""
run_js() {
  local name=$1 out code
  shift
  out=$(bounded ${JS_TIMEOUT:-180} swipt repl run -d "${JS_TARGET:-$SERVER_URL}" "$SCRIPT_DIR/device/$name.js" "$@" 2>&1)
  code=$?
  print -r -- "$out" | grep -v '^RESULT ' | mask
  RESULT=$(print -r -- "$out" | grep '^RESULT ' | tail -1 | cut -c8-)
  return $code
}

# Typed by hand and never written to disk. Swipt keeps its own copy on the phone for automatic unlocking.
prompt_passcode() {
  local kind=${1:-pin} again
  [[ -t 0 ]] || die "run this in a terminal; the passcode has to be typed by hand"
  [[ $kind == (pin|numeric|alphanumeric) ]] || die "the passcode type is pin, numeric or alphanumeric"
  print -n "Passcode of the phone ($kind): "; read -rs PASSCODE; print
  print -n "Again: "; read -rs again; print
  [[ $PASSCODE == $again ]] || die "the two entries differ"
  [[ -n $PASSCODE ]] || die "empty passcode"
  if [[ $kind == pin ]] && ! [[ $PASSCODE =~ '^([0-9]{4}|[0-9]{6})$' ]]; then
    die "a pin must be 4 or 6 digits; pass numeric or alphanumeric as the second argument otherwise"
  fi
  PASSCODE_TYPE=$kind
}

need_desktop() {
  [[ -z $SSH_CONNECTION ]] && return 0
  die "$1 has to run in Terminal on the Mac's desktop. Over SSH, codesign cannot ask for permission to use the signing key and fails with errSecInternalComponent."
}

wwdr_g3_present() {
  local tmp=$(mktemp -d) f found=1
  security find-certificate -a -c "Apple Worldwide Developer Relations" -p >$tmp/all 2>/dev/null
  awk -v d=$tmp/c. '/BEGIN CERT/{i++} {print > (d i)}' $tmp/all
  for f in $tmp/c.*(N); do
    openssl x509 -in $f -noout -subject 2>/dev/null | grep -q 'OU *= *G3' && found=0
  done
  rm -rf $tmp
  return $found
}

# CoreDevice's view of the phone: paired, unpaired, or nothing when it does not know the phone.
pairing_state() {
  local tmp=$(mktemp -t se3dc)
  xcrun devicectl list devices --json-output $tmp >/dev/null 2>&1
  python3 -I - $tmp $1 <<'PY'
import json, sys
for x in json.load(open(sys.argv[1]))["result"]["devices"]:
    if x.get("hardwareProperties", {}).get("udid") == sys.argv[2]:
        print(x.get("connectionProperties", {}).get("pairingState", ""))
PY
  rm -f $tmp
}

# The Mac can lose its CoreDevice pairing while the USB trust still works. swipt then fails with
# "The device must be paired before it can be connected". Pairing again may ask for Trust on the phone.
ensure_paired() {
  local udid=$1
  [[ $(pairing_state $udid) == paired ]] && return 0
  info "CoreDevice on this Mac is not paired with $udid; pairing again. If the phone asks, tap Trust and enter the passcode"
  bounded 120 xcrun devicectl manage pair --device $udid 2>&1 | tail -3 | sed 's/^/      /'
  if [[ $(pairing_state $udid) == paired ]]; then
    ok "paired with this Mac again"
    return 0
  fi
  warn "pairing failed; unlock the phone, then run: DEVELOPER_DIR=$DEVELOPER_DIR xcrun devicectl manage pair --device $udid"
  return 1
}

sign_test() {
  local t=$(mktemp -t se3signtest)
  cp /usr/bin/true $t
  bounded 60 codesign --force --sign "Apple Development" $t 2>&1 | tail -1
  local code=${pipestatus[1]}
  rm -f $t
  return $code
}

# The phones CoreDevice knows, with the UDID the other commands take. The Identifier
# column that `devicectl list devices` prints is a CoreDevice UUID, not the UDID.
list_phones() {
  local tmp=$(mktemp -t se3dc)
  xcrun devicectl list devices --json-output $tmp >/dev/null 2>&1
  print -- "\nPhones this Mac knows (UDID, name, model, iOS, connection, pairing):"
  python3 -I - $tmp $CFG/devices <<'PY'
import json, os, sys
saved = {f[:-5] for f in os.listdir(sys.argv[2]) if f.endswith(".json")}
found = False
for x in json.load(open(sys.argv[1]))["result"]["devices"]:
    h, p, c = x.get("hardwareProperties", {}), x.get("deviceProperties", {}), x.get("connectionProperties", {})
    if h.get("platform") != "iOS":
        continue
    found = True
    udid = h.get("udid", "?")
    print("      " + "  ".join([
        udid, str(p.get("name")), str(h.get("productType")), "iOS " + str(p.get("osVersionNumber")),
        c.get("transportType") or "not connected", str(c.get("pairingState")),
    ]) + ("  (registered)" if udid in saved else ""))
if not found:
    print("      none; connect a phone by USB, unlock it and tap Trust")
PY
  rm -f $tmp
}

cmd_preflight() {
  local udid=$1 fails=0 line
  bad() { print -- "FAIL  $*"; (( fails++ )) }

  xcodebuild -version >/dev/null 2>&1 && ok "Xcode: $(xcodebuild -version | head -1)" || bad "Xcode is not usable at $DEVELOPER_DIR"
  xcrun -f devicectl >/dev/null 2>&1 && ok "devicectl found" || bad "devicectl not found under $DEVELOPER_DIR"
  command -v swipt >/dev/null && ok "swipt CLI: $(swipt version 2>/dev/null | head -1)" || bad "swipt CLI missing; run: npm install -g @swipt/cli --include=optional"
  if line=$(server_binary); then
    case $line in
      */swipt-dev/*) ok "swipt-server: $line" ;;
      *) warn "using the published swipt-server. A phone that has never mounted the disk image may hang on upload; see references/troubleshooting.md" ;;
    esac
  else
    bad "no swipt-server found"
  fi
  if (( $(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Apple Development:') > 0 )); then
    ok "valid Apple Development identity"
  else
    bad "no valid Apple Development identity. Add one in Xcode › Settings › Apple Accounts › Manage Certificates, then run se3.sh fix-wwdr on the desktop"
  fi
  wwdr_g3_present && ok "WWDR G3 intermediate present" || bad "WWDR G3 intermediate missing; run se3.sh fix-wwdr on the desktop"
  [[ -n $SSH_CONNECTION ]] && info "this is an SSH session; se3.sh install must still run on the Mac's desktop"
  local sleepValue=$(pmset -g | awk '$1=="sleep"{print $2; exit}')
  [[ $sleepValue == 0 ]] && ok "Mac system sleep is off" || warn "Mac system sleep is $sleepValue minutes; a sleeping Mac stalls every phone. Turn it off with: sudo pmset -a sleep 0"

  if [[ -z $udid ]]; then
    list_phones
    if (( fails > 0 )); then
      print -- "\n$fails check(s) failed."
      exit 1
    fi
    print -- "\nThe Mac checks passed. Run preflight again with a UDID from the list to check that phone."
    return 0
  fi

  local tmp=$(mktemp -t se3dc)
  xcrun devicectl list devices --json-output $tmp >/dev/null 2>&1
  local facts=$(python3 -I - $tmp $udid <<'PY'
import json, sys
for x in json.load(open(sys.argv[1]))["result"]["devices"]:
    h = x.get("hardwareProperties", {})
    if h.get("udid") != sys.argv[2]:
        continue
    p = x.get("deviceProperties", {})
    c = x.get("connectionProperties", {})
    print("|".join(str(v) for v in [p.get("name"), h.get("productType"), p.get("osVersionNumber"), p.get("developerModeStatus"), c.get("pairingState")]))
PY
  )
  rm -f $tmp
  if [[ -z $facts ]]; then
    bad "CoreDevice does not know $udid. Connect it by USB, unlock it and tap Trust"
  else
    local -a f=("${(@s:|:)facts}")
    ok "phone: $f[1], $f[2], iOS $f[3]"
    [[ $f[2] == iPhone14,6 ]] || warn "this SOP was written for iPhone14,6 (iPhone SE 3)"
    (( ${f[3]%%.*} >= 27 )) && ok "iOS is 27 or later" || bad "Swipt needs iOS 27 or later"
    [[ $f[4] == enabled ]] && ok "Developer Mode is on" || bad "Developer Mode is $f[4]. Turn it on in Settings › Privacy & Security, restart, and confirm"
    [[ $f[5] == paired ]] && ok "paired with this Mac" || bad "not paired ($f[5]); unlock the phone and tap Trust. If no prompt appears, run on the desktop: xcrun devicectl manage pair --device $udid"
  fi

  if (( fails > 0 )); then
    print -- "\n$fails check(s) failed."
    exit 1
  fi
  print -- "\nAll checks passed."
}

cmd_fix_wwdr() {
  need_desktop "fix-wwdr"
  if wwdr_g3_present; then
    ok "WWDR G3 is already installed"
  else
    local cer=$(mktemp -t se3wwdr)
    curl -fsSL -o $cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer || die "could not download the certificate"
    security add-certificates -k ~/Library/Keychains/login.keychain-db $cer || die "could not add the certificate"
    rm -f $cer
    ok "installed WWDR G3"
  fi
  print -- "$(security find-identity -v -p codesigning | tail -1 | sed 's/^ *//')"
  sign_test && ok "signing works" || die "signing failed. If a window asked about the key, enter the login password and choose Always Allow, then run this again"
}

cmd_prepare() {
  local udid=${1:?usage: prepare UDID}
  start_server $udid
  JS_TIMEOUT=240 run_js prepare || die "preparing the phone failed"
  print -r -- "$RESULT"
  if [[ $(json_field "$RESULT" vpnInstalled) != True ]]; then
    die "LocalDevVPN is not installed. The App Store page is open on the phone: tap Get, then open the app, tap Connect, allow the VPN configuration, and run this again"
  fi
  run_js vpn off || die "could not disconnect LocalDevVPN; turn it off on the phone"
  ok "LocalDevVPN is $(json_field "$RESULT" state); the phone is ready for install"
}

cmd_install() {
  local udid=${1:?usage: install UDID [pin|numeric|alphanumeric]}
  need_desktop "install"
  sign_test || die "signing failed. If a window asked about the key, enter the login password and choose Always Allow, then run this again"
  prompt_passcode ${2:-pin}
  swipt sideload install -d $udid --passcode "$PASSCODE" --passcode-type $PASSCODE_TYPE $team
}

cmd_post() {
  local udid=${1:?usage: post UDID}
  start_server $udid
  run_js vpn on || die "could not connect LocalDevVPN"
  local needs=$(json_field "$RESULT" needsUser)
  [[ -z $needs ]] || die "LocalDevVPN needs someone at the phone: $needs. Allow it, then run this again"
  ok "VPN: $(json_field "$RESULT" state)"
  JS_TIMEOUT=120 run_js enable-token || die "could not read the API settings from Swipt"
  local url=$(json_field "$RESULT" url) wifi=$(json_field "$RESULT" wifi) port=$(json_field "$RESULT" port) name=$(json_field "$RESULT" name)
  [[ -n $url && -n $port ]] || die "Swipt showed no API URL"
  [[ -n $wifi ]] || die "Swipt listed no Wi-Fi address; is the phone on Wi-Fi?"
  local token=${${url#http://}%%@*}
  [[ -n $token && $token != ${url#http://} ]] || die "the API URL has no token"
  python3 -I - $CFG/devices/$udid.json "$udid" "$name" "$wifi" "$port" "$token" <<'PY'
import json, os, sys
path, udid, name, wifi, port, token = sys.argv[1:7]
data = {"udid": udid, "name": name, "wifi": wifi, "port": int(port), "token": token, "url": f"http://{token}@{wifi}:{port}"}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f)
PY
  ok "saved the endpoint for $name: http://<token>@$wifi:$port"
  info "file: $CFG/devices/$udid.json (readable only by you)"
}

load_endpoint() {
  local file=$CFG/devices/$1.json
  [[ -f $file ]] || die "no saved endpoint for $1; run se3.sh post $1"
  EP_URL=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' $file)
  EP_WIFI=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["wifi"])' $file)
  EP_PORT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' $file)
}

# The CLI keeps the token in its own store, so it stays out of process arguments during a run.
use_cli_store() {
  local udid=$1
  export XDG_CONFIG_HOME=$CFG/cli/$udid
  mkdir -p $XDG_CONFIG_HOME
  bounded 30 swipt device add "$EP_URL" 2>&1 | mask | sed 's/^/      /'
  (( ${pipestatus[1]} == 0 )) || die "the API did not accept the saved token"
  CLI_NAME=$(python3 -I -c 'import json,sys,os; print(next(iter(json.load(open(os.environ["XDG_CONFIG_HOME"]+"/swipt/devices.json")))))')
}

cmd_verify() {
  local udid=${1:?usage: verify UDID [--lock-test]} extra=$2
  load_endpoint $udid
  nc -z -G 5 $EP_WIFI $EP_PORT >/dev/null 2>&1 || die "the API at $EP_WIFI:$EP_PORT does not answer. If ping works, Swipt is not running: open it on the phone"
  ok "API port answers at $EP_WIFI:$EP_PORT"
  local anonymous=$(bounded 30 swipt repl run -d "http://$EP_WIFI:$EP_PORT" 'console.log("reached")' 2>&1 | mask)
  [[ $anonymous == *"requires a token"* ]] && ok "rejects calls without a token" || die "the API accepted a call without a token: $anonymous"
  use_cli_store $udid
  JS_TARGET=$CLI_NAME JS_TIMEOUT=90 run_js verify ${extra:+lock-test} || die "the checks on the phone failed"
  print -r -- "$RESULT"
  ok "$udid is ready for wireless control"
}

cmd_vpn() {
  local udid=${1:?usage: vpn UDID on|off} want=${2:?usage: vpn UDID on|off}
  start_server $udid
  run_js vpn $want || die "could not switch LocalDevVPN $want"
  print -r -- "$RESULT"
}

# Sets SIGN_LEFT to the seconds of signing left on the phone and SIGN_HALF to the seconds until
# the half point, after which swipt sideload update re-signs. Sets SIGN_ERROR and fails when
# CoreDevice cannot reach the phone. CoreDevice reaches it with the VPN on over USB, and over
# Wi-Fi when the Mac is on the phone's subnet.
signing_left() {
  local tmp=$(mktemp -t se3pp) out
  SIGN_LEFT="" SIGN_HALF="" SIGN_ERROR=""
  if ! bounded 60 xcrun devicectl device profile list --type provisioning --device $1 --json-output $tmp >/dev/null 2>$tmp.err; then
    SIGN_ERROR=$(grep -m1 -i 'error' $tmp.err | sed 's/^ *//' | cut -c1-160)
    rm -f $tmp $tmp.err
    : ${SIGN_ERROR:=devicectl gave no answer}
    return 1
  fi
  out=$(python3 -I - $tmp <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
when = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
profiles = [
    (when(p["expirationDate"]), when(p["creationDate"]))
    for p in json.load(open(sys.argv[1]))["result"]["provisioningProfiles"]
    if p.get("name", "").startswith("iOS Team Provisioning Profile: io.nekohasekai.swipt")
    or p.get("name") == "iOS Team Provisioning Profile: *"
]
if profiles:
    expiration, creation = max(profiles)
    print(int((expiration - now).total_seconds()), int((creation + (expiration - creation) / 2 - now).total_seconds()))
PY
  )
  rm -f $tmp $tmp.err
  if [[ -z $out ]]; then
    SIGN_ERROR="the phone has no Swipt provisioning profile"
    return 1
  fi
  SIGN_LEFT=${out%% *} SIGN_HALF=${out##* }
}

days_left() { printf %.1f $(( SIGN_LEFT / 86400.0 )) }
due_text() {
  if (( SIGN_HALF > 0 )); then
    print -- "renews after $(date -r $(( $(date +%s) + SIGN_HALF )) '+%F %H:%M')"
  else
    print -- "due now"
  fi
}

# Runs swipt sideload update once. On a terminal it goes through script(1), so the CLI behaves
# as when run directly and a copy of its output is kept. Otherwise (auto-renew) the CLI runs
# non-interactively and fails instead of waiting for input.
update_once() {
  local udid=$1 log=$2
  shift 2
  if [[ -t 0 && -t 1 ]]; then
    script -q $log swipt sideload update -d $udid $team "$@"
  else
    swipt sideload update -d $udid $team "$@" </dev/null >$log 2>&1
  fi
}

# Renews through swipt sideload update; RENEW_LOG names its output.
run_update() {
  local udid=$1 code
  RENEW_LOG=$CFG/logs/$udid.renew.log
  update_once $udid $RENEW_LOG
  code=$?
  if (( code != 0 )) && grep -q -- '--nightly' $RENEW_LOG; then
    # The phone runs a nightly that is newer than the latest release, so only the nightly channel can renew it.
    info "the installed build is a nightly newer than the latest release; renewing from the nightly channel"
    update_once $udid $RENEW_LOG --nightly
    code=$?
  fi
  mask <$RENEW_LOG >$RENEW_LOG.masked && mv $RENEW_LOG.masked $RENEW_LOG
  return $code
}

# Waits up to 30 s for Swipt's API port; an update relaunches the app.
api_answers() {
  load_endpoint $1
  local i
  for i in {1..10}; do
    nc -z -G 3 $EP_WIFI $EP_PORT >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# swipt sideload update re-signs only when less than half of the signing period is left or a
# newer build exists; otherwise it just prints the expiry. When CoreDevice reaches the phone
# with its VPN on, that is all renewing takes. Otherwise the VPN goes off over USB for the
# update and comes back on afterwards.
cmd_renew() {
  local udid=${1:?usage: renew UDID} failure=""
  need_desktop "renew"
  if signing_left $udid; then
    info "CoreDevice reaches the phone; renewing without turning off the VPN"
    run_update $udid || die "renewing failed (output: $RENEW_LOG). The old signing works until it expires"
    api_answers $udid || warn "Swipt's API does not answer yet; if that lasts, open Swipt on the phone"
    if signing_left $udid; then
      ok "renewed; signing has $(days_left) days left, $(due_text)"
    else
      ok "renewed"
    fi
    info "check it once: se3.sh verify $udid --lock-test"
    return 0
  fi
  info "CoreDevice cannot reach the phone with its VPN on ($SIGN_ERROR); renewing over USB"
  start_server $udid
  run_js vpn off || die "could not disconnect LocalDevVPN"
  stop_server
  if ensure_paired $udid; then
    run_update $udid || failure="renewing failed (output: $RENEW_LOG)"
  else
    failure="this Mac is not paired with the phone"
  fi
  # Reconnect the VPN even after a failure: the old signing keeps the phone usable until it expires.
  start_server $udid
  run_js vpn on || die "could not reconnect LocalDevVPN; connect it on the phone"
  [[ -z $failure ]] || die "$failure. The VPN is back on, and the old signing works until it expires"
  ok "renewed; VPN: $(json_field "$RESULT" state)"
  info "check it once: se3.sh verify $udid --lock-test"
}

notify() {
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# Renews every saved phone that is past its half point, without the USB fallback. "schedule on"
# runs it twice a day from a LaunchAgent in the desktop session, where codesign can use the key.
# --check only reports, which also works over SSH.
cmd_auto_renew() {
  local check=$1 f udid name failures=0
  local -a lines
  if [[ $check != --check ]]; then
    need_desktop "auto-renew"
    if ! sign_test >/dev/null; then
      lines+=("$(date '+%F %T') signing does not work in this session, so renewals would fail")
      (( failures++ ))
    fi
  fi
  for f in $CFG/devices/*.json(N); do
    udid=${f:t:r}
    name=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name") or sys.argv[2])' $f $udid)
    if ! signing_left $udid; then
      lines+=("$(date '+%F %T') $name: CoreDevice cannot reach it ($SIGN_ERROR)")
      (( failures++ ))
      continue
    fi
    if (( SIGN_HALF > 0 )) || [[ $check == --check ]]; then
      lines+=("$(date '+%F %T') $name: $(days_left) days left; $(due_text)")
      continue
    fi
    if run_update $udid && api_answers $udid && signing_left $udid; then
      lines+=("$(date '+%F %T') $name: renewed; $(days_left) days left")
    else
      lines+=("$(date '+%F %T') $name: renewing failed; see $RENEW_LOG")
      (( failures++ ))
    fi
  done
  print -l -- $lines | tee -a $CFG/logs/auto-renew.log
  [[ $check == --check ]] && return 0
  print -l -- $lines >$CFG/auto-renew.status
  if (( failures > 0 )); then
    notify "Swipt renewal needs attention" "$failures problem(s); see ~/.config/swipt-se3/auto-renew.status"
    return 1
  fi
}

cmd_schedule() {
  local plist=$HOME/Library/LaunchAgents/$AGENT.plist domain=gui/$(id -u)
  case ${1:-status} in
    on)
      need_desktop "schedule on"
      mkdir -p ${plist:h}
      python3 -I - $plist $SCRIPT_DIR/se3.sh $CFG/logs/auto-renew.out $AGENT <<'PY'
import plistlib, sys
plist, script, out, label = sys.argv[1:5]
with open(plist, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": ["/bin/zsh", script, "auto-renew"],
        "StartCalendarInterval": [{"Hour": 9, "Minute": 30}, {"Hour": 21, "Minute": 30}],
        "StandardOutPath": out,
        "StandardErrorPath": out,
    }, f)
PY
      launchctl bootout $domain/$AGENT 2>/dev/null
      launchctl bootstrap $domain $plist || die "launchctl could not load $plist"
      ok "auto-renew runs at 09:30 and 21:30 every day; results: $CFG/auto-renew.status"
      info "run it once now: launchctl kickstart $domain/$AGENT"
      ;;
    off)
      launchctl bootout $domain/$AGENT 2>/dev/null
      rm -f $plist
      ok "auto-renew is off"
      ;;
    status)
      [[ -f $plist ]] && ok "auto-renew is installed: $plist" || warn "auto-renew is not installed"
      [[ -f $CFG/auto-renew.status ]] && { info "last run:"; sed 's/^/      /' $CFG/auto-renew.status }
      ;;
    *) die "usage: schedule on|off|status" ;;
  esac
}

status_one() {
  local udid=$1
  load_endpoint $udid
  print -- "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name") or "")' $CFG/devices/$udid.json) ($udid)"
  info "endpoint: http://<token>@$EP_WIFI:$EP_PORT"
  ping -c 1 -t 3 $EP_WIFI >/dev/null 2>&1 && ok "network reaches the phone" || warn "the phone does not answer ping"
  nc -z -G 4 $EP_WIFI $EP_PORT >/dev/null 2>&1 && ok "Swipt API port is open" || warn "Swipt API port is closed; Swipt is not running or its IP changed"
  if signing_left $udid; then
    ok "signing: $(days_left) days left; $(due_text)"
  else
    warn "signing unknown; CoreDevice cannot reach the phone ($SIGN_ERROR)"
  fi
}

# One phone, or every saved phone when no UDID is given. Works over SSH.
cmd_status() {
  local f
  if [[ -n $1 ]]; then
    status_one $1
    return
  fi
  local -a saved=($CFG/devices/*.json(N))
  (( $#saved > 0 )) || die "no saved phones in $CFG/devices; run se3.sh post UDID first"
  for f in $saved; do
    status_one ${f:t:r}
  done
}

command=${1:-}
[[ -n $command ]] || { sed -n '5,15p' $0 | sed 's/^# *//'; exit 2 }
shift
case $command in
  preflight) cmd_preflight "$@" ;;
  fix-wwdr) cmd_fix_wwdr "$@" ;;
  prepare) cmd_prepare "$@" ;;
  install) cmd_install "$@" ;;
  post) cmd_post "$@" ;;
  verify) cmd_verify "$@" ;;
  vpn) cmd_vpn "$@" ;;
  renew) cmd_renew "$@" ;;
  auto-renew) cmd_auto_renew "$@" ;;
  schedule) cmd_schedule "$@" ;;
  status) cmd_status "$@" ;;
  *) die "unknown command $command" ;;
esac
