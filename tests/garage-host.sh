# garage: host-side helper for agent-garage bays (installed by modules/host.nix).
#
#   garage status          bays, units, public URLs
#   garage pair <bay>      print a one-time T3 pairing link for the bay (15 min)
#   garage wake <bay>      start a sleeping bay now and wait until T3 answers
#   garage sleep <bay>     shut a bay with sleep mode down now (it wakes on the
#                          next request to its URL)
#   garage test <bay>      run the acceptance tests (docs/design.md section 11); for a
#                          bay with VPN egress this stops its tunnel for about
#                          half a minute (kill switch test) and restores it
#
# GARAGE_CONFIG (set by the Nix wrapper) points at a JSON file with the bays.
# Talks to a bay only over its vsock socket; output from the bay is treated as
# untrusted text (control characters are stripped before printing).

set -euo pipefail
export LC_ALL=C

cfg() { jq -r "$@" "$GARAGE_CONFIG"; }

die() {
  printf 'garage: %s\n' "$*" >&2
  exit 1
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo garage $*)"; }

bay_field() {
  # bay_field <bay> <field>
  # shellcheck disable=SC2016 # jq variables
  cfg --arg b "$1" --arg f "$2" '.bays[$b][$f] // empty'
}

check_bay() {
  [[ $1 =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "invalid bay name"
  [ -n "$(bay_field "$1" ipv4)" ] || die "unknown bay '$1' (known: $(cfg '.bays | keys | join(" ")'))"
}

sanitize() { tr -d '\000-\010\013-\037\177'; }

# vsock_call <bay> <port>: stdin goes to the bay service, its output to stdout.
vsock_call() {
  local vm sock
  vm=$(bay_field "$1" vm)
  sock="$(cfg .stateDir)/$vm/notify.vsock"
  [ -S "$sock" ] || die "no vsock socket at $sock (is microvm@$vm running?)"
  { printf 'CONNECT %s\n' "$2"; cat; } |
    socat -t 900 -T 900 - "UNIX-CONNECT:$sock" |
    sed -u '1{/^OK [0-9]*$/d}' | sanitize
}

egress_field() {
  # egress_field <bay> <field>: empty for a bay without VPN egress
  # shellcheck disable=SC2016 # jq variables
  cfg --arg b "$1" --arg f "$2" '.bays[$b].egress[$f] // empty'
}

sleep_field() {
  # sleep_field <bay> <field>: empty for a bay without sleep mode
  # shellcheck disable=SC2016 # jq variables
  cfg --arg b "$1" --arg f "$2" '.bays[$b].sleep[$f] // empty'
}

# wake_bay <bay>: make sure the bay runs and T3 answers. A bay with sleep mode
# is started through its wake unit, like a request from outside would.
wake_bay() {
  local b=$1 wake ip
  wake=$(sleep_field "$b" wakeUnit)
  [ -n "$wake" ] || return 0
  ip=$(bay_field "$b" ipv4)
  if ! systemctl is-active --quiet "microvm@$(bay_field "$b" vm).service" || ! tcp_open "$ip" "$(cfg .t3Port)"; then
    echo "waking $b ..." >&2
    systemctl start "$wake" || die "could not wake '$b' (journalctl -u $wake)"
  fi
}

cmd_wake() {
  need_root wake
  local b=${1:-}
  [ -n "$b" ] || die "usage: garage wake <bay>"
  check_bay "$b"
  [ -n "$(sleep_field "$b" wakeUnit)" ] || die "bay '$b' has no sleep mode (it always runs)"
  wake_bay "$b"
  echo "$b is awake; it sleeps again after $(sleep_field "$b" after) idle minutes"
}

cmd_sleep() {
  need_root sleep
  local b=${1:-}
  [ -n "$b" ] || die "usage: garage sleep <bay>"
  check_bay "$b"
  [ -n "$(sleep_field "$b" wakeUnit)" ] || die "bay '$b' has no sleep mode (nothing would wake it again)"
  systemctl stop "microvm@$(bay_field "$b" vm).service"
  echo "$b is asleep; the next request to $(bay_field "$b" publicUrl) wakes it"
}

cmd_status() {
  local b vm eg sl
  for b in $(cfg '.bays | keys[]'); do
    vm=$(bay_field "$b" vm)
    eg=uplink
    [ -z "$(egress_field "$b" tunnel)" ] ||
      eg="$(egress_field "$b" tunnel):$(systemctl is-active "$(egress_field "$b" unit)" || true)"
    sl=off
    if [ -n "$(sleep_field "$b" after)" ]; then
      sl="$(sleep_field "$b" after)min:awake"
      systemctl is-active --quiet "microvm@$vm.service" || sl="$(sleep_field "$b" after)min:asleep"
      systemctl is-active --quiet "$(sleep_field "$b" socketUnit)" || sl="$sl,wake-socket-down"
    fi
    printf '%s  vm=%s  ip=%s  microvm=%s  public=%s  egress=%s  sleep=%s\n' "$b" "$vm" "$(bay_field "$b" ipv4)" \
      "$(systemctl is-active "microvm@$vm.service" || true)" "$(bay_field "$b" publicUrl)" "$eg" "$sl"
  done
  printf 'bridge=%s nftables=%s cloudflared=%s\n' "$(systemctl is-active garage-bridge.service || true)" \
    "$(systemctl is-active garage-nftables.service || true)" \
    "$(systemctl is-active "$(cfg .public.unit)" || true)"
}

cmd_pair() {
  need_root pair
  local b=${1:-} ip t3port url
  [ -n "$b" ] || die "usage: garage pair <bay>"
  check_bay "$b"
  ip=$(bay_field "$b" ipv4)
  t3port=$(cfg .t3Port)
  # The bay prints links for its own (bridge) address; show the public URL
  # (Cloudflare Access, the only way into a bay) instead, plain and
  # URL-encoded. The QR code encodes the bridge address, so it is left out.
  url=$(bay_field "$b" publicUrl)
  [ -n "$url" ] || die "bay '$b' has no public URL (no way in to pair from)"
  local enc_bay enc_url
  enc_bay="http%3A%2F%2F$ip%3A$t3port"
  enc_url=$(printf '%s' "$url" | sed 's#:#%3A#g; s#/#%2F#g')
  wake_bay "$b"
  vsock_call "$b" "$(cfg .vsockPorts.pair)" </dev/null |
    grep -v -e '▀' -e '▄' -e '█' |
    sed "s#http://$ip:$t3port#$url#g; s#$enc_bay#$enc_url#g"
  echo "(QR code omitted; open the Pairing URL or paste the token into T3 within 15 minutes)"
}

# ----------------------------------------------------------------------- test
pass=0
fail=0
result() {
  local status=$1 name=$2
  shift 2
  printf '%s %s %s\n' "$status" "$name" "$*"
  case $status in
    PASS) pass=$((pass + 1)) ;;
    FAIL) fail=$((fail + 1)) ;;
  esac
}

# Ports probed on every other bay from inside the bay under test.
OTHER_BAY_PORTS="1 22 53 80 443 3773 5432 7001 7002 8000 8080 8384 9222 65535"

NB_NS=garage-test-nb
NB_HOST_IF=gtestnb0
NB_IP=10.180.0.250
nb_pid=""

neighbor_up() {
  # A stand-in for another bay: a network namespace on the garage bridge with
  # an isolated port (like a real bay tap) and listeners on 22 and 3773.
  local br
  br=$(cfg .network.bridge)
  ip netns add "$NB_NS"
  ip link add "$NB_HOST_IF" type veth peer name nb0 netns "$NB_NS"
  echo 1 >"/proc/sys/net/ipv6/conf/$NB_HOST_IF/disable_ipv6"
  ip link set "$NB_HOST_IF" master "$br"
  bridge link set dev "$NB_HOST_IF" isolated on
  ip link set "$NB_HOST_IF" up
  ip -n "$NB_NS" link set lo up
  ip -n "$NB_NS" addr add "$NB_IP/24" dev nb0
  ip -n "$NB_NS" link set nb0 up
  ip netns exec "$NB_NS" socat TCP-LISTEN:3773,fork,reuseaddr SYSTEM:'echo neighbor' 2>/dev/null &
  nb_pid=$!
  ip netns exec "$NB_NS" socat TCP-LISTEN:22,fork,reuseaddr SYSTEM:'echo neighbor' 2>/dev/null &
  nb_pid="$nb_pid $!"
  # Wait for the listeners (and the bridge port to forward) before testing.
  for _ in $(seq 1 20); do
    tcp_open "$NB_IP" 3773 && return 0
    sleep 0.5
  done
}

neighbor_down() {
  local p
  for p in $nb_pid; do kill "$p" 2>/dev/null || true; done
  ip link del "$NB_HOST_IF" 2>/dev/null || true
  ip netns del "$NB_NS" 2>/dev/null || true
}

# shellcheck disable=SC2016 # $0/$1 expand in the child shell
tcp_open() { timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; }

counter_of() {
  # counter_of <comment>: packets counted by the inet garage rule with that comment
  nft -j list table inet garage |
    jq -r --arg c "$1" '[.nftables[] | select(.rule? and .rule.comment == $c) | .rule.expr[] | select(.counter?) | .counter.packets] | add // 0'
}

# A JWT-shaped token with this bay's claims but a made-up signature.
forged_jwt() {
  local aud=$1 now hdr pl
  now=$(date +%s)
  b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
  hdr=$(printf '{"alg":"RS256","kid":"garage-test","typ":"JWT"}' | b64url)
  pl=$(printf '{"aud":["%s"],"email":"test@example.invalid","exp":%d,"iat":%d,"iss":"https://%s","sub":"0","type":"app"}' \
    "$aud" "$((now + 3600))" "$now" "$(cfg .public.authDomain)" | b64url)
  printf '%s.%s.%s' "$hdr" "$pl" "$(head -c 256 /dev/urandom | b64url)"
}

# public_probe <name> <url> [curl args...]: the edge must not serve T3. Passes
# on a redirect to the Access login or a 4xx, never on T3's page or a 101.
public_probe() {
  local name=$1 url=$2 body hdrs code loc
  shift 2
  body=$(mktemp)
  hdrs=$(mktemp)
  code=$(curl -sS -o "$body" -D "$hdrs" -w '%{http_code}' --max-time 15 "$@" "$url" 2>/dev/null) || code=000
  loc=$(grep -i '^location:' "$hdrs" | head -n1 | tr -d '\r' | sed 's/^[Ll]ocation: *//')
  if grep -q 'T3 Code' "$body"; then
    result FAIL "$name" "HTTP $code served T3 content"
  elif [ "$code" = 101 ] || [ "$code" = 200 ]; then
    result FAIL "$name" "HTTP $code"
  elif [[ $code =~ ^30[1-8]$ ]] && [[ $loc == "https://$(cfg .public.authDomain)/"* ]]; then
    result PASS "$name" "HTTP $code -> Access login"
  elif [[ $code =~ ^30[1-8]$ ]] && [[ $loc == "https://${url#*://}"* || $loc == https://* && $url == http://* ]]; then
    result PASS "$name" "HTTP $code -> $loc (https upgrade, no content)"
  elif [[ $code =~ ^4[0-9][0-9]$ ]]; then
    result PASS "$name" "HTTP $code"
  else
    result FAIL "$name" "HTTP $code location=${loc:-none}"
  fi
  rm -f "$body" "$hdrs"
}

public_checks() {
  local b=$1 url unit host aud ip t3port conf inv n code
  url=$(bay_field "$b" publicUrl)
  echo "== public access"
  if [ -z "$url" ]; then
    result INFO public "no public URL for $b"
    return 0
  fi
  unit=$(cfg .public.unit)
  conf=$(cfg .public.configFile)
  host=${url#https://}
  ip=$(bay_field "$b" ipv4)
  t3port=$(cfg .t3Port)

  if systemctl is-active --quiet "$unit"; then result PASS unit-active "$unit"; else result FAIL unit-active "$unit $(systemctl is-active "$unit" || true)"; fi

  local cred perm
  cred=$(cfg .public.credentialsFile)
  perm=$(stat -c '%U:%G %a' "$cred" 2>/dev/null || echo missing)
  if [ "$perm" = "root:root 400" ] && [ "$(stat -c '%U:%G %a' "$(dirname "$cred")")" = "root:root 700" ]; then
    result PASS tunnel-credentials "$cred $perm, directory root-only"
  else
    result FAIL tunnel-credentials "$cred $perm"
  fi
  case $cred in /nix/store/*) result FAIL tunnel-credentials "in the Nix store" ;; esac

  # Configuration as cloudflared reads it: the bay's hostname goes to the bay
  # with the Access check for its AUD; anything else to the 404 catch-all.
  if cloudflared tunnel --config "$conf" ingress validate >/dev/null 2>&1; then
    result PASS ingress-valid "$conf"
  else
    result FAIL ingress-valid "$conf"
  fi
  # The bay itself, or for a bay with sleep mode its wake address on the host.
  local origin
  origin=$(bay_field "$b" origin)
  if cloudflared tunnel --config "$conf" ingress rule "https://$host/" 2>&1 | grep -qx "[[:space:]]*service: $origin"; then
    result PASS ingress-bay "$host -> $origin"
  else
    result FAIL ingress-bay "$host does not route to $origin"
  fi
  # shellcheck disable=SC2016 # jq variables
  aud=$(jq -r --arg h "$host" '.ingress[] | select(.hostname == $h) | .originRequest.access | select(.required == true) | .audTag | join(",")' "$conf")
  if [[ $aud =~ ^[0-9a-f]{64}$ ]]; then
    result PASS ingress-access "access.required with AUD ${aud:0:12}..."
  else
    result FAIL ingress-access "no required Access check for $host"
  fi
  local other
  for other in "https://not-a-bay-$RANDOM.$(printf '%s' "$host" | cut -d. -f2-)/" "https://$ip/" "https://example.com/"; do
    if cloudflared tunnel --config "$conf" ingress rule "$other" 2>&1 | grep -q 'service: http_status:404'; then
      result PASS ingress-unknown-404 "$other -> 404"
    else
      result FAIL ingress-unknown-404 "$other does not hit the 404 catch-all"
    fi
  done

  # Access policy as declared (garage-cf plan without drift = the same live):
  # only this bay's own GitLab user ids, none shared with another bay.
  local subs shared
  # shellcheck disable=SC2016 # jq variables
  subs=$(cfg --arg b "$b" '.bays[$b].gitlabSubs | join(" ")')
  # shellcheck disable=SC2016 # jq variables
  shared=$(cfg --arg b "$b" '[.bays[$b].gitlabSubs[] as $s | .bays | to_entries[] | select(.key != $b and any(.value.gitlabSubs[]; . == $s)) | "\(.key):\($s)"] | join(" ")')
  if [[ $subs =~ ^[0-9]+( [0-9]+)*$ ]] && [ -z "$shared" ]; then
    result PASS access-subs "policy allows GitLab sub $subs only, shared with no other bay"
  else
    result FAIL access-subs "subs='$subs' shared='$shared'"
  fi

  inv=$(systemctl show -p InvocationID --value "$unit")
  n=0
  [ -n "$inv" ] && n=$(journalctl -q -o cat "_SYSTEMD_INVOCATION_ID=$inv" | grep -c 'Registered tunnel connection' || true)
  if [ "$n" -ge 1 ]; then result PASS tunnel-connected "$n edge connections registered"; else result FAIL tunnel-connected "no registered edge connection"; fi

  # T3 behind cloudflared: the request as cloudflared forwards it (public Host,
  # X-Forwarded-Proto https) is served; T3 compares Origin with Host.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $host" -H 'X-Forwarded-Proto: https' \
    -H "Origin: https://$host" "http://$ip:$t3port/" 2>/dev/null) || code=000
  if [ "$code" = 200 ]; then result PASS t3-public-host "Host $host HTTP $code"; else result FAIL t3-public-host "Host $host HTTP $code"; fi

  # From the internet side (public DNS, Cloudflare edge).
  local jwt ws_key
  jwt=$(forged_jwt "${aud%%,*}")
  ws_key=$(head -c 16 /dev/urandom | base64)
  public_probe edge-no-login "$url/"
  public_probe edge-no-login-path "$url/api/auth/session"
  public_probe edge-plain-http "http://$host/"
  public_probe edge-garbage-cookie "$url/" -H 'Cookie: CF_Authorization=garbage'
  public_probe edge-forged-cookie "$url/" -H "Cookie: CF_Authorization=$jwt"
  public_probe edge-forged-header "$url/" -H "Cf-Access-Jwt-Assertion: $jwt"
  public_probe edge-forged-both "$url/" -H "Cf-Access-Jwt-Assertion: $jwt" -H "Cookie: CF_Authorization=$jwt"
  public_probe edge-websocket "$url/ws" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $ws_key" -H "Origin: $url"
  public_probe edge-forged-websocket "$url/ws" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $ws_key" -H "Origin: $url" \
    -H "Cookie: CF_Authorization=$jwt" -H "Cf-Access-Jwt-Assertion: $jwt"
}

# Service that answers HTTPS GET with the caller's IPv4 address (plain text).
PUBLIC_IP_HOST=api.ipify.org

host_public_ip() { curl -4 -sS --max-time 15 "https://$PUBLIC_IP_HOST/" 2>/dev/null | head -c 64 | tr -d '\r\n '; }

# route_dev <bay ip>: the interface a packet from the bay to the internet is routed to.
route_dev() { ip -4 route get 1.1.1.1 from "$1" iif "$(cfg .network.bridge)" 2>&1 | grep -o ' dev [^ ]*' | head -n1 | cut -d' ' -f3; }

egress_checks() {
  local b=$1 ip uplink tun unit table prio conf perm dev hs age mtu
  ip=$(bay_field "$b" ipv4)
  uplink=$(cfg .uplink)
  tun=$(egress_field "$b" tunnel)
  echo "== egress (VPN tunnel or uplink)"
  if [ -z "$tun" ]; then
    # No VPN: the bay leaves from the uplink exactly as before.
    dev=$(route_dev "$ip")
    if [ "$dev" = "$uplink" ]; then result PASS egress-route "$ip -> internet via $uplink"; else result FAIL egress-route "$ip -> internet via ${dev:-?}"; fi
    if [ -z "$(ip rule show from "$ip")" ]; then result PASS egress-no-rule "no policy rule for $ip"; else result FAIL egress-no-rule "$(ip rule show from "$ip" | tr '\n' ';')"; fi
    return 0
  fi
  unit=$(egress_field "$b" unit)
  table=$(egress_field "$b" table)
  prio=$(egress_field "$b" rulePriority)
  conf=$(egress_field "$b" wireguardConfig)

  if systemctl is-active --quiet "$unit"; then result PASS unit-active "$unit"; else result FAIL unit-active "$unit $(systemctl is-active "$unit" || true)"; fi
  # The file holds the private key: only its metadata is looked at.
  perm=$(stat -c '%U:%G %a' "$conf" 2>/dev/null || echo missing)
  if [ "$perm" = "root:root 600" ] || [ "$perm" = "root:root 400" ]; then
    if [ "$(stat -c '%U:%G %a' "$(dirname "$conf")")" = "root:root 700" ]; then
      result PASS egress-config "$conf $perm, directory root-only"
    else
      result FAIL egress-config "$(dirname "$conf") is not root:root 700"
    fi
  else
    result FAIL egress-config "$conf $perm"
  fi
  case $(readlink -f "$conf") in /nix/store/*) result FAIL egress-config "in the Nix store" ;; esac
  if systemctl cat "$unit" 2>/dev/null | grep -qxF "LoadCredential=wg.conf:$conf"; then
    result PASS egress-loadcredential "$unit reads $conf at run time (LoadCredential)"
  else
    result FAIL egress-loadcredential "$unit does not load $conf"
  fi

  mtu=$(cat "/sys/class/net/$tun/mtu" 2>/dev/null || echo none)
  if [ "$mtu" = "$(egress_field "$b" mtu)" ]; then result PASS egress-mtu "$tun mtu $mtu, TCP MSS clamped to $(egress_field "$b" mss)"; else result FAIL egress-mtu "$tun mtu $mtu"; fi
  if [ "$(cat "/proc/sys/net/ipv6/conf/$tun/disable_ipv6" 2>/dev/null)" = 1 ]; then result PASS egress-no-ipv6 "IPv6 off on $tun"; else result FAIL egress-no-ipv6 "IPv6 on $tun"; fi
  # shellcheck disable=SC2016 # awk variables
  hs=$(wg show "$tun" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  age=$(($(date +%s) - ${hs:-0}))
  if [ "${hs:-0}" -gt 0 ] && [ "$age" -le 180 ]; then
    result PASS egress-handshake "$tun last handshake ${age}s ago, endpoint $(wg show "$tun" endpoints | awk '{print $2; exit}')"
  else
    result FAIL egress-handshake "$tun no handshake in the last 180 s"
  fi

  if ip rule show priority "$prio" | grep -q "from $ip lookup $table"; then
    result PASS egress-rule "priority $prio: from $ip lookup $table"
  else
    result FAIL egress-rule "no rule 'from $ip lookup $table' at priority $prio"
  fi
  local tbl
  tbl=$(ip -4 route show table "$table")
  if grep -q "^default dev $tun" <<<"$tbl" && grep -q "^unreachable default .*metric 4096" <<<"$tbl" &&
    grep -q "^$(cfg .network.cidr) dev $(cfg .network.bridge)" <<<"$tbl"; then
    result PASS egress-table "table $table: default via $tun, bridge route, unreachable fallback"
  else
    result FAIL egress-table "table $table: $(tr '\n' ';' <<<"$tbl")"
  fi
  dev=$(route_dev "$ip")
  if [ "$dev" = "$tun" ]; then result PASS egress-route "$ip -> internet via $tun"; else result FAIL egress-route "$ip -> internet via ${dev:-?}"; fi
  local c rules
  # Listed once: `nft ... | grep -q` fails under pipefail when grep exits early.
  rules=$(nft list table inet garage)
  for c in "egress $b: not via its tunnel" "egress $b: tunnel of another bay" "egress $b: on the uplink" "egress $b: dns via tunnel" "egress $b: tunnel to another bay"; do
    if grep -qF "comment \"$c\"" <<<"$rules"; then result PASS egress-nft "rule '$c'"; else result FAIL egress-nft "rule '$c' missing"; fi
  done
}

# egress_killswitch <bay>: stop the tunnel, the bay must reach nothing; then
# also remove its policy rule (routing falls back to the uplink), nftables must
# still drop everything; nothing of the bay may show up on the uplink. The
# tunnel unit is restarted afterwards, also on failure or interrupt.
egress_restore() {
  systemctl restart "$1" >/dev/null 2>&1 || true
}

egress_killswitch() {
  local b=$1 ip unit prio up0 up1 nv0 nv1 out t
  ip=$(bay_field "$b" ipv4)
  unit=$(egress_field "$b" unit)
  prio=$(egress_field "$b" rulePriority)
  echo "== egress kill switch ($unit stopped, then started again)"
  # shellcheck disable=SC2064 # expand now
  trap "egress_restore '$unit'" EXIT
  # shellcheck disable=SC2064 # expand now
  trap "egress_restore '$unit'; exit 130" INT TERM
  up0=$(counter_of "egress $b: on the uplink")
  nv0=$(counter_of "egress $b: not via its tunnel")
  t=$(mktemp)
  printf '%s\n' only-network "deny-https $PUBLIC_IP_HOST" "deny-https github.com" \
    "deny-tcp 1.1.1.1 443" "deny-tcp 9.9.9.9 443" "deny-tcp 1.1.1.1 53" END >"$t"

  systemctl stop "$unit"
  if ip link show dev "$(egress_field "$b" tunnel)" >/dev/null 2>&1; then
    result FAIL killswitch-down "tunnel still there after stop"
  else
    result PASS killswitch-down "$unit stopped, $(egress_field "$b" tunnel) gone, rule kept: $(ip rule show priority "$prio" | head -n1)"
  fi
  out=$(vsock_call "$b" "$(cfg .vsockPorts.selftest)" <"$t") || true
  ks_collect "tunnel down" "$out"

  # Second layer: without the policy rule the bay is routed to the uplink.
  while ip rule del priority "$prio" 2>/dev/null; do :; done
  result INFO killswitch-norule "policy rule removed, route now via $(route_dev "$ip")"
  out=$(vsock_call "$b" "$(cfg .vsockPorts.selftest)" <"$t") || true
  ks_collect "no rule" "$out"
  rm -f "$t"
  nv1=$(counter_of "egress $b: not via its tunnel")
  if [ "$nv1" -gt "$nv0" ]; then
    result PASS killswitch-nft "dropped by nftables when routed to the uplink ($nv0 -> $nv1 packets)"
  else
    result FAIL killswitch-nft "drop counter did not move ($nv0 -> $nv1)"
  fi

  systemctl restart "$unit"
  trap - EXIT INT TERM
  up1=$(counter_of "egress $b: on the uplink")
  if [ "$up1" -eq "$up0" ]; then
    result PASS killswitch-uplink "no packet from $ip reached the uplink ($up0 -> $up1)"
  else
    result FAIL killswitch-uplink "packets from $ip reached the uplink postrouting ($up0 -> $up1)"
  fi
  if systemctl is-active --quiet "$unit" && [ "$(route_dev "$ip")" = "$(egress_field "$b" tunnel)" ]; then
    result PASS killswitch-restored "$unit active, $ip routed via $(egress_field "$b" tunnel) again"
  else
    result FAIL killswitch-restored "$unit $(systemctl is-active "$unit" || true), route via $(route_dev "$ip")"
  fi
  # Back online through the tunnel (the first handshake can take a few seconds).
  local pip="" n
  for n in 1 2 3 4 5 6; do
    out=$(printf '%s\n' only-network "public-ip $PUBLIC_IP_HOST" END | vsock_call "$b" "$(cfg .vsockPorts.selftest)") || true
    pip=$(printf '%s\n' "$out" | sed -n 's/^INFO public-ip \([0-9.]*\)$/\1/p' | head -n1)
    [ -n "$pip" ] && break
    sleep 5
  done
  if [ -n "$pip" ] && [ "$pip" != "$HOST_PUBLIC_IP" ]; then
    result PASS killswitch-back "online again as $pip (attempt $n)"
  else
    result FAIL killswitch-back "no internet after restart (${pip:-none})"
  fi
}

# ks_collect <label> <selftest output>: count the in-bay results of a kill switch run.
ks_collect() {
  local label=$1 out=$2 p f
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL) ' | sed "s/^\(PASS\|FAIL\) \([^ ]*\)/\1 \2 [$label]/"
  p=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  f=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  if printf '%s\n' "$out" | grep -q '^SUMMARY '; then
    pass=$((pass + p))
    fail=$((fail + f))
  else
    result FAIL killswitch-in-bay "no SUMMARY from the bay ($label)"
  fi
}

# Sleep mode: the wake address is loopback only and leads to this bay's T3;
# the bay does not start at boot; the idle check is scheduled. The bay is not
# put to sleep here (that would end whatever runs in it); `garage sleep` and
# `garage wake` do that on request.
sleep_checks() {
  local b=$1 addr port sock wake timer vm listen others code cf
  addr=$(sleep_field "$b" address)
  echo "== sleep mode"
  if [ -z "$addr" ]; then
    result INFO sleep "no sleep mode for $b (always running)"
    return 0
  fi
  sock=$(sleep_field "$b" socketUnit)
  wake=$(sleep_field "$b" wakeUnit)
  timer=$(sleep_field "$b" timerUnit)
  port=$(sleep_field "$b" port)
  cf=$(cfg .public.unit)
  vm=$(bay_field "$b" vm)
  for u in "$sock" "$timer"; do
    if systemctl is-active --quiet "$u"; then result PASS unit-active "$u"; else result FAIL unit-active "$u $(systemctl is-active "$u" || true)"; fi
  done
  if [[ $addr == 127.* ]]; then result PASS wake-loopback "wake address $addr is a loopback address"; else result FAIL wake-loopback "wake address $addr is not loopback"; fi
  listen=$(systemctl show -p Listen --value "$sock")
  if [ "$listen" = "$addr:$port (Stream)" ]; then
    result PASS wake-listen "$sock listens on $listen only"
  else
    result FAIL wake-listen "$sock listens on '$listen'"
  fi
  # Nothing else listens on the wake port: not on another address, and the
  # listener on the wake address is systemd's socket (or its relay).
  # shellcheck disable=SC2016 # awk variables
  others=$(ss -H -ltn "sport = :$port" | awk '{print $4}' | grep -v '^127\.180\.0\.[0-9]*:' | tr '\n' ' ' || true)
  if [ -z "$others" ]; then result PASS wake-only-loopback "port $port open on wake addresses only"; else result FAIL wake-only-loopback "also on: $others"; fi
  # Fail closed: without the wake socket the tunnel must not run.
  if [ -n "$(bay_field "$b" publicUrl)" ]; then
    if systemctl show -p Requires --value "$cf" | tr ' ' '\n' | grep -qx "$sock"; then
      result PASS wake-required "$cf requires $sock"
    else
      result FAIL wake-required "$cf runs without $sock"
    fi
  fi
  if systemctl show -p Wants --value microvms.target | tr ' ' '\n' | grep -qx "microvm@$vm.service"; then
    result FAIL sleep-no-autostart "microvm@$vm starts at boot"
  else
    result PASS sleep-no-autostart "microvm@$vm starts on request, not at boot"
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 150 "http://$addr:$port/" 2>/dev/null) || code=000
  if [ "$code" = 200 ]; then result PASS wake-relay "http://$addr:$port HTTP $code (relayed to the bay)"; else result FAIL wake-relay "http://$addr:$port HTTP $code"; fi
  if systemctl is-active --quiet "$wake"; then result PASS unit-active "$wake"; else result FAIL unit-active "$wake $(systemctl is-active "$wake" || true)"; fi
  if systemctl cat "$cf" 2>/dev/null | grep '^IPAddressAllow=' | grep -qw "$(bay_field "$b" ipv4)/32"; then
    result FAIL sleep-cloudflared "$cf may still reach the bay directly"
  else
    result PASS sleep-cloudflared "$cf reaches $b only through $addr"
  fi
}

cmd_test() {
  need_root test
  local b=${1:-}
  [ -n "$b" ] || die "usage: garage test <bay>"
  check_bay "$b"
  wake_bay "$b"
  local vm ip uplink gw_br t3port tap
  vm=$(bay_field "$b" vm)
  ip=$(bay_field "$b" ipv4)
  tap=$(bay_field "$b" tap)
  uplink=$(cfg .uplink)
  gw_br=$(cfg .network.gateway)
  t3port=$(cfg .t3Port)

  echo "== host checks"
  local u
  # The admin's own way in (sshd, Tailscale) is checked when it is enabled.
  for u in tailscaled.service sshd.service; do
    systemctl is-enabled --quiet "$u" 2>/dev/null || continue
    if systemctl is-active --quiet "$u"; then result PASS unit-active "$u"; else result FAIL unit-active "$u $(systemctl is-active "$u" || true)"; fi
  done
  for u in garage-bridge.service garage-nftables.service "microvm@$vm.service"; do
    if systemctl is-active --quiet "$u"; then result PASS unit-active "$u"; else result FAIL unit-active "$u $(systemctl is-active "$u" || true)"; fi
  done
  if ip -4 route show default | grep -q " dev $uplink "; then
    result PASS default-route "$(ip -4 route show default | head -n1)"
  else
    result FAIL default-route "not via $uplink: $(ip -4 route show default | head -n1)"
  fi
  # VPN egress must not touch the host's own routing or Tailscale's rules.
  if systemctl is-active --quiet tailscaled.service 2>/dev/null; then
    if ip rule show | grep -q 'lookup 52' && ip rule show | grep -q 'fwmark 0x80000/0xff0000 lookup main'; then
      result PASS tailscale-rules "Tailscale's policy rules present"
    else
      result FAIL tailscale-rules "$(ip rule show | tr '\n' ';')"
    fi
  fi
  if nft list table inet garage >/dev/null 2>&1 && nft list table bridge garage >/dev/null 2>&1; then
    result PASS nft-tables "inet garage + bridge garage loaded"
  else
    result FAIL nft-tables "missing"
  fi
  if bridge -d link show dev "$tap" | grep -q 'isolated on'; then
    result PASS port-isolated "$tap isolated on $(cfg .network.bridge)"
  else
    result FAIL port-isolated "$tap not isolated"
  fi
  if [ "$(cat "/proc/sys/net/ipv6/conf/$(cfg .network.bridge)/disable_ipv6")" = 1 ]; then
    result PASS bridge-no-ipv6 "IPv6 off on the bridge"
  else
    result FAIL bridge-no-ipv6 "IPv6 on on the bridge"
  fi

  echo "== no LAN or tailnet way in (Cloudflare Access only)"
  # No socket proxy may listen on the host for a bay, and no NAT rule may
  # forward to one.
  # The one exception is the wake relay of a bay with sleep mode, which
  # listens on a loopback address only (checked below).
  local listen_pids="" p_ wake_units
  wake_units=$(cfg '[.bays[].sleep | select(. != null) | .wakeUnit] | join(" ")')
  for p_ in $(pgrep -f "systemd-socket-proxyd .*$(cfg .network.cidr | cut -d. -f1-3 | sed 's/\./\\./g')\\." || true); do
    case " $wake_units " in
      *" $(ps -o unit= -p "$p_" | tr -d ' ') "*) ;;
      *) listen_pids="$listen_pids$p_ " ;;
    esac
  done
  if [ -z "$listen_pids" ]; then result PASS no-socket-proxy "no socket proxy to a bay running (wake relays aside)"; else result FAIL no-socket-proxy "pids: $listen_pids"; fi
  if nft list ruleset 2>/dev/null | grep -E 'dnat|redirect' | grep -qF "$(cfg .network.cidr | cut -d. -f1-3)."; then
    result FAIL no-forwarding "an nftables dnat/redirect rule points into the bay network"
  else
    result PASS no-forwarding "no nftables dnat/redirect into $(cfg .network.cidr)"
  fi
  local code_bay
  code_bay=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://$ip:$t3port/" 2>/dev/null) || code_bay=000
  if [ "$code_bay" = 200 ]; then result PASS t3-from-host "http://$ip:$t3port HTTP $code_bay"; else result FAIL t3-from-host "http://$ip:$t3port HTTP $code_bay"; fi

  public_checks "$b"
  egress_checks "$b"
  sleep_checks "$b"

  echo "== other bay (stand-in on the bridge)"
  trap neighbor_down EXIT
  neighbor_down
  neighbor_up
  if tcp_open "$NB_IP" 3773; then
    result PASS neighbor-control "host reaches the stand-in on $NB_IP:3773"
  else
    result FAIL neighbor-control "host cannot reach the stand-in (test setup broken)"
  fi
  # shellcheck disable=SC2016
  if ip netns exec "$NB_NS" timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$ip" "$t3port" 2>/dev/null; then
    result FAIL neighbor-to-bay "stand-in reached $ip:$t3port"
  else
    result PASS neighbor-to-bay "stand-in cannot reach $ip:$t3port"
  fi

  # The real other bays: isolated bridge ports with their own anti-spoof rules.
  local ob ob_tap ob_ip
  # shellcheck disable=SC2016 # jq variables
  for ob in $(cfg --arg b "$b" '.bays | keys[] | select(. != $b)'); do
    ob_tap=$(bay_field "$ob" tap)
    ob_ip=$(bay_field "$ob" ipv4)
    if bridge -d link show dev "$ob_tap" 2>/dev/null | grep -q 'isolated on'; then
      result PASS other-bay-isolated "$ob ($ob_tap) isolated on $(cfg .network.bridge)"
    elif ! ip link show dev "$ob_tap" >/dev/null 2>&1; then
      result INFO other-bay-isolated "$ob ($ob_tap) not running"
    else
      result FAIL other-bay-isolated "$ob ($ob_tap) not isolated"
    fi
    if nft list table bridge garage | grep -q "iifname \"$ob_tap\" ip saddr != $ob_ip "; then
      result PASS other-bay-antispoof "$ob ($ob_tap) may send only from $ob_ip"
    else
      result FAIL other-bay-antispoof "no anti-spoof rule for $ob ($ob_tap)"
    fi
  done

  echo "== targets for the in-bay checks"
  local targets lan_gw ts_ip addr p host_user magic other
  targets=$(mktemp)
  host_ips=$(ip -4 -o addr show dev "$uplink" | awk '{split($4, a, "/"); print a[1]}')
  ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  lan_gw=$(ip -4 route show default dev "$uplink" | awk '{print $3; exit}')
  {
    for addr in $host_ips $ts_ip $gw_br; do
      for p in 22 53 80 443 3773 8384 9222; do echo "deny-tcp $addr $p"; done
      echo "deny-ping $addr"
    done
    if [ -n "$lan_gw" ]; then
      for p in 53 80 443; do echo "deny-tcp $lan_gw $p"; done
      echo "deny-ping $lan_gw"
    fi
    echo "deny-tcp 100.100.100.100 53"
    echo "deny-tcp 169.254.169.254 80"
    if ip -4 -o addr show dev docker0 >/dev/null 2>&1; then
      for addr in $(ip -4 -o addr show dev docker0 | awk '{split($4, a, "/"); print a[1]}'); do echo "deny-tcp $addr 22"; done
    fi
    # shellcheck disable=SC2016 # jq variables
    # Other bays: no port at all (sample across the range; the bridge port
    # isolation blocks layer 2 entirely, the host drops routed attempts).
    for other in $(cfg --arg b "$b" '.bays | to_entries[] | select(.key != $b) | .value.ipv4'); do
      for p in $OTHER_BAY_PORTS; do echo "deny-tcp $other $p"; done
      echo "deny-ping $other"
    done
    echo "deny-tcp $NB_IP 3773"
    echo "deny-tcp $NB_IP 22"
    echo "deny-ping $NB_IP"
    echo "deny-tcp-host aspmx.l.google.com 25"
    echo "deny-tcp-host smtp.gmail.com 25"
    echo "allow-https cache.nixos.org"
    echo "allow-https github.com"
    echo "allow-https api.anthropic.com"
    echo "allow-dns github.com"
    echo "public-ip $PUBLIC_IP_HOST"
    echo "absent-store $(basename "$(readlink -f /run/current-system)")"
    if command -v tailscale >/dev/null; then
      echo "absent-store $(basename "$(dirname "$(dirname "$(readlink -f "$(command -v tailscale)")")")")"
    fi
    host_user=${SUDO_USER:-}
    magic=$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty' || true)
    for t in "$(hostname | tr '[:upper:]' '[:lower:]')" ${host_user:+"$host_user"} .ts.net ${magic:+"$magic"} $host_ips $ts_ip; do
      echo "search-all $t"
    done
    for t in "$(hostname | tr '[:upper:]' '[:lower:]')" ${host_user:+"/home/$host_user"} ${magic:+"$magic"} $host_ips $ts_ip; do
      echo "search-store $t"
    done
    echo END
  } >"$targets"
  printf '%s lines (host addresses, ports, search terms are sent at run time, not stored in the bay)\n' "$(wc -l <"$targets")"

  local smtp_before smtp_after out dns_before dns_after up_before up_after tun
  smtp_before=$(counter_of smtp)
  tun=$(egress_field "$b" tunnel)
  dns_before=$(counter_of "egress $b: dns via tunnel")
  up_before=$(counter_of "egress $b: on the uplink")
  HOST_PUBLIC_IP=$(host_public_ip) || HOST_PUBLIC_IP=""

  echo "== in-bay checks (vsock port $(cfg .vsockPorts.selftest))"
  out=$(vsock_call "$b" "$(cfg .vsockPorts.selftest)" <"$targets") || true
  rm -f "$targets"
  printf '%s\n' "$out"
  local in_fail in_pass
  in_pass=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  in_fail=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  if printf '%s\n' "$out" | grep -q '^SUMMARY '; then
    pass=$((pass + in_pass))
    fail=$((fail + in_fail))
  else
    result FAIL in-bay "no SUMMARY from the bay"
  fi

  smtp_after=$(counter_of smtp)
  if [ "$smtp_after" -gt "$smtp_before" ]; then
    result PASS smtp-rule "tcp/25 drop counter $smtp_before -> $smtp_after"
  else
    result FAIL smtp-rule "tcp/25 drop counter did not move ($smtp_before -> $smtp_after)"
  fi

  # Public address: the home IP without VPN egress, never the home IP with it.
  local bay_ip4
  bay_ip4=$(printf '%s\n' "$out" | sed -n 's/^INFO public-ip \([0-9.]*\)$/\1/p' | head -n1)
  if [ -z "$HOST_PUBLIC_IP" ] || [ -z "$bay_ip4" ]; then
    result FAIL public-ip "host=${HOST_PUBLIC_IP:-none} bay=${bay_ip4:-none}"
  elif [ -n "$tun" ] && [ "$bay_ip4" != "$HOST_PUBLIC_IP" ]; then
    result PASS public-ip "bay $bay_ip4 (VPN) != host $HOST_PUBLIC_IP"
  elif [ -z "$tun" ] && [ "$bay_ip4" = "$HOST_PUBLIC_IP" ]; then
    result PASS public-ip "bay $bay_ip4 == host $HOST_PUBLIC_IP (uplink, no VPN)"
  else
    result FAIL public-ip "bay $bay_ip4 host $HOST_PUBLIC_IP egress=${tun:-uplink}"
  fi
  if [ -n "$tun" ]; then
    dns_after=$(counter_of "egress $b: dns via tunnel")
    up_after=$(counter_of "egress $b: on the uplink")
    if [ "$dns_after" -gt "$dns_before" ]; then
      result PASS dns-via-tunnel "DNS packets from $(bay_field "$b" ipv4) on $tun: $dns_before -> $dns_after"
    else
      result FAIL dns-via-tunnel "no DNS on $tun ($dns_before -> $dns_after)"
    fi
    if [ "$up_after" -eq "$up_before" ]; then
      result PASS no-uplink-leak "no packet from $(bay_field "$b" ipv4) on $uplink during the run ($up_before -> $up_after)"
    else
      result FAIL no-uplink-leak "packets from $(bay_field "$b" ipv4) reached $uplink ($up_before -> $up_after)"
    fi
  fi
  neighbor_down
  trap - EXIT

  [ -z "$tun" ] || egress_killswitch "$b"

  echo "== sandboxing of the garage units (systemd-analyze security)"
  local units
  units="garage-bridge.service garage-nftables.service microvm@$vm.service $(egress_field "$b" unit) $(sleep_field "$b" wakeUnit)"
  for u in $units; do
    result INFO security "$u $(systemd-analyze security --no-pager "$u" 2>/dev/null | tail -n1 | sed 's/.*Overall exposure level for [^:]*: //')"
  done
  if [ -n "$(bay_field "$b" publicUrl)" ]; then
    # Internet-facing: must rate OK or SAFE (docs/design.md section 11).
    local cf_unit level
    cf_unit=$(cfg .public.unit)
    level=$(systemd-analyze security --no-pager "$cf_unit" 2>/dev/null | tail -n1 | sed 's/.*Overall exposure level for [^:]*: //')
    case $level in
      *" OK"* | *" SAFE"*) result PASS security "$cf_unit $level" ;;
      *) result FAIL security "$cf_unit ${level:-unknown} (needs OK or SAFE)" ;;
    esac
  fi

  echo "== measurements"
  local pid rss sd img store_img
  pid=$(systemctl show -p MainPID --value "microvm@$vm.service")
  if [ "${pid:-0}" -gt 0 ]; then
    rss=$(ps -o rss= -p "$pid" | tr -d ' ')
    result INFO host-ram "hypervisor RSS $((rss / 1024)) MiB (pid $pid)"
    local t1 t2 c1 c2 hz
    hz=$(getconf CLK_TCK)
    c1=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    t1=$(date +%s%N)
    sleep 10
    c2=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    t2=$(date +%s%N)
    result INFO idle-cpu "$(awk -v d="$((c2 - c1))" -v hz="$hz" -v ns="$((t2 - t1))" 'BEGIN {printf "%.1f%% of one core over 10 s", 100 * d / hz / (ns / 1e9)}')"
  fi
  sd="$(cfg .stateDir)/$vm"
  img="$sd/data.img"
  [ -f "$img" ] && result INFO volume "$(du -h --apparent-size "$img" | cut -f1) apparent, $(du -h "$img" | cut -f1) on disk"
  store_img=$(grep -o '/nix/store/[^,'"'"' ]*\.\(erofs\|squashfs\|img\)' "$(readlink -f "$sd/current")/bin/microvm-run" | head -n1 || true)
  [ -n "$store_img" ] && result INFO store-image "$(du -h "$store_img" | cut -f1) $store_img"

  printf 'SUMMARY pass=%d fail=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  status) cmd_status ;;
  pair) shift; cmd_pair "$@" ;;
  wake) shift; cmd_wake "$@" ;;
  sleep) shift; cmd_sleep "$@" ;;
  test) shift; cmd_test "$@" ;;
  *) die "usage: garage status | garage pair <bay> | garage wake <bay> | garage sleep <bay> | garage test <bay>" ;;
esac
