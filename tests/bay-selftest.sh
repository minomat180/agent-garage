# Acceptance checks that run inside a bay (docs/design.md section 11).
#
# Started by systemd per vsock connection from the host (bay-selftest.socket,
# vsock port 7002, only CID 2 = the host is served). The host sends the targets
# on stdin, one per line, ending with END; this file itself holds nothing about
# the host. Every input line is checked against a strict pattern; anything
# else aborts the run.
#
#   deny-tcp <ipv4> <port>          connecting must fail
#   deny-tcp-host <hostname> <port> connecting must fail (name resolved here)
#   deny-ping <ipv4>                ICMP echo must get no answer
#   allow-https <hostname>          an HTTPS request must get an HTTP answer
#   deny-https <hostname>           an HTTPS request must fail (no answer)
#   allow-dns <hostname>            the name must resolve (bay resolvers)
#   public-ip <hostname>            HTTPS GET of an "what is my IP" service;
#                                   prints "INFO public-ip <ipv4>" for the host
#   only-network                    run only the network checks above (used by
#                                   the host between tunnel stops and starts)
#   absent-store <store basename>   path must not exist in /nix/store
#   search-all <term>               term must not appear in file names or text
#                                   files outside the Nix store
#   search-store <term>             term must not appear anywhere in the store
#   END
#
# Output: one line per check, "PASS|FAIL|INFO <check> <detail>", then
# "SUMMARY pass=<n> fail=<n>".

set -uo pipefail
export LC_ALL=C

pass=0
fail=0
result() {
  # result <PASS|FAIL|INFO> <name> <detail...>
  local status=$1 name=$2
  shift 2
  printf '%s %s %s\n' "$status" "$name" "$*"
  case $status in
    PASS) pass=$((pass + 1)) ;;
    FAIL) fail=$((fail + 1)) ;;
  esac
}

re_ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
re_port='^[0-9]{1,5}$'
re_host='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
re_store='^[a-z0-9]{32}-[A-Za-z0-9._+?=-]+$'
re_term='^[A-Za-z0-9._/-]{3,64}$'

deny_tcp=()
deny_ping=()
allow_https=()
deny_https=()
allow_dns=()
public_ip=()
only_network=0
absent_store=()
search_all=()
search_store=()

bad_input() {
  printf 'FAIL input rejected line: %q\n' "$1"
  printf 'SUMMARY pass=0 fail=1\n'
  exit 2
}

got_end=0
lines=0
while IFS= read -r -t 30 line; do
  lines=$((lines + 1))
  [ "$lines" -le 500 ] || bad_input "too many lines"
  line=${line%$'\r'}
  read -r cmd a b rest <<<"$line"
  [ -z "${rest:-}" ] || bad_input "$line"
  case $cmd in
    END)
      got_end=1
      break
      ;;
    deny-tcp)
      [[ $a =~ $re_ipv4 && $b =~ $re_port ]] || bad_input "$line"
      deny_tcp+=("$a $b")
      ;;
    deny-tcp-host)
      [[ $a =~ $re_host && $b =~ $re_port ]] || bad_input "$line"
      deny_tcp+=("$a $b")
      ;;
    deny-ping)
      [[ $a =~ $re_ipv4 && -z ${b:-} ]] || bad_input "$line"
      deny_ping+=("$a")
      ;;
    allow-https)
      [[ $a =~ $re_host && -z ${b:-} ]] || bad_input "$line"
      allow_https+=("$a")
      ;;
    deny-https)
      [[ $a =~ $re_host && -z ${b:-} ]] || bad_input "$line"
      deny_https+=("$a")
      ;;
    allow-dns)
      [[ $a =~ $re_host && -z ${b:-} ]] || bad_input "$line"
      allow_dns+=("$a")
      ;;
    public-ip)
      [[ $a =~ $re_host && -z ${b:-} ]] || bad_input "$line"
      public_ip+=("$a")
      ;;
    only-network)
      [[ -z ${a:-} ]] || bad_input "$line"
      only_network=1
      ;;
    absent-store)
      [[ $a =~ $re_store && -z ${b:-} ]] || bad_input "$line"
      absent_store+=("$a")
      ;;
    search-all)
      [[ $a =~ $re_term && -z ${b:-} ]] || bad_input "$line"
      search_all+=("$a")
      ;;
    search-store)
      [[ $a =~ $re_term && -z ${b:-} ]] || bad_input "$line"
      search_store+=("$a")
      ;;
    *) bad_input "$line" ;;
  esac
done
[ "$got_end" -eq 1 ] || bad_input "no END line"

# --- identity and resources -------------------------------------------------
my_host=$(cat /proc/sys/kernel/hostname)
my_ip=$(ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')
result INFO identity "hostname=$my_host ip=${my_ip:-none} kernel=$(uname -r) vcpus=$(nproc)"
if [ "$only_network" -eq 0 ]; then
result INFO memory "$(free -m | awk '/^Mem:/ {print "total_mib=" $2 " used_mib=" $3 " available_mib=" $7}')"
result INFO boot "$(systemd-analyze time 2>/dev/null | head -n1)"
result INFO load "$(cut -d' ' -f1-3 /proc/loadavg)"
if [ "$my_host" = bay ]; then
  result PASS hostname "bay"
else
  result FAIL hostname "$my_host"
fi

# --- the agent tools are there ---------------------------------------------------
tools_ok=1
versions=""
for t in claude t3 node git gh glab tmux nix; do
  flag=--version
  [ "$t" = tmux ] && flag=-V
  v=$(runuser -u bay -- env HOME=/home/bay PATH=/run/current-system/sw/bin "$t" "$flag" 2>/dev/null </dev/null | head -n1) || v=""
  if [ -z "$v" ]; then
    tools_ok=0
    versions="$versions $t=MISSING;"
  else
    versions="$versions $t=$v;"
  fi
done
if [ "$tools_ok" -eq 1 ]; then result PASS tools "$versions"; else result FAIL tools "$versions"; fi
if nix config show experimental-features 2>/dev/null | grep -qw flakes; then
  result PASS nix-flakes "flakes enabled"
else
  result FAIL nix-flakes "flakes not enabled"
fi
if [ "$(readlink -f /home/bay/.claude/CLAUDE.md 2>/dev/null)" != "" ] && grep -q '^# Rules for every agent on this machine' /home/bay/.claude/CLAUDE.md; then
  result PASS bay-rules "/home/bay/.claude/CLAUDE.md is the bay rules file"
else
  result FAIL bay-rules "/home/bay/.claude/CLAUDE.md missing or different"
fi
if runuser -u bay -- env XDG_RUNTIME_DIR=/run/user/"$(id -u bay)" systemctl --user is-active --quiet t3code.service; then
  result PASS t3-service "user service t3code active (bay, lingering)"
else
  result FAIL t3-service "user service t3code not active"
fi
fi # only_network

# --- network: denied targets --------------------------------------------------
for t in "${deny_tcp[@]}"; do
  read -r host port <<<"$t"
  # A name is resolved first (a few tries): a lookup that fails or times out
  # must not pass as "connection dropped".
  if ! [[ $host =~ $re_ipv4 ]]; then
    name=$host
    host=""
    for _ in 1 2 3; do
      host=$(timeout 6 getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}')
      [[ ${host:-} =~ $re_ipv4 ]] && break
      host=""
    done
    if [ -z "$host" ]; then
      result FAIL "deny-tcp" "$name does not resolve (test cannot run)"
      continue
    fi
    host_label="$name ($host)"
  else
    host_label=$host
  fi
  start=$(date +%s%N)
  # shellcheck disable=SC2016 # $0/$1 expand in the child shell
  timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$host" "$port" 2>/dev/null
  rc=$?
  ms=$((($(date +%s%N) - start) / 1000000))
  case $rc in
    0) result FAIL "deny-tcp" "$host_label:$port connected" ;;
    124) result PASS "deny-tcp" "$host_label:$port dropped (timeout after ${ms} ms)" ;;
    1) result PASS "deny-tcp" "$host_label:$port refused or unreachable after ${ms} ms" ;;
    *) result FAIL "deny-tcp" "$host_label:$port test error rc=$rc" ;;
  esac
done

for ip4 in "${deny_ping[@]}"; do
  if ping -n -c 1 -W 2 "$ip4" >/dev/null 2>&1; then
    result FAIL deny-ping "$ip4 answered"
  else
    result PASS deny-ping "$ip4 no answer"
  fi
done

# --- network: allowed internet -----------------------------------------------
for h in "${allow_https[@]}"; do
  code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$h/" 2>/dev/null) || true
  if [[ ${code:-000} != 000 ]]; then
    result PASS allow-https "$h HTTP $code"
  else
    result FAIL allow-https "$h no answer"
  fi
done

for h in "${deny_https[@]}"; do
  code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null) || true
  if [[ ${code:-000} == 000 ]]; then
    result PASS deny-https "$h no answer"
  else
    result FAIL deny-https "$h HTTP $code"
  fi
done

# --- network: DNS and the public address ------------------------------------------
result INFO resolvers "$(awk '$1 == "nameserver" {printf "%s ", $2}' /etc/resolv.conf)"
for h in "${allow_dns[@]}"; do
  a4=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')
  if [[ ${a4:-} =~ $re_ipv4 ]]; then
    result PASS allow-dns "$h -> $a4"
  else
    result FAIL allow-dns "$h does not resolve"
  fi
done

for h in "${public_ip[@]}"; do
  pip=$(curl -4 -sS --max-time 15 "https://$h/" 2>/dev/null | head -c 64 | tr -d '\r\n ') || true
  if [[ ${pip:-} =~ $re_ipv4 ]]; then
    result INFO public-ip "$pip"
  else
    result FAIL public-ip "$h gave no IPv4 address"
  fi
done

if [ "$only_network" -eq 1 ]; then
  printf 'SUMMARY pass=%d fail=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

# --- IPv6: none at all ----------------------------------------------------------
v6addr=$(ip -6 -o addr show 2>/dev/null | grep -v ' lo ' || true)
v6route=$(ip -6 route show 2>/dev/null | grep -v '^::1 ' || true)
if [ -z "$v6addr" ] && [ -z "$v6route" ]; then
  result PASS ipv6-none "no IPv6 addresses or routes outside lo"
else
  result FAIL ipv6-none "addr=[$v6addr] route=[$v6route]"
fi
if curl -6 -sS -o /dev/null --max-time 5 https://one.one.one.one/ 2>/dev/null; then
  result FAIL ipv6-egress "IPv6 HTTPS worked"
else
  result PASS ipv6-egress "IPv6 HTTPS fails"
fi

# --- listening sockets: only T3 on the bay address ------------------------------
listeners=$(ss -Hltnu | awk '{print $1 "/" $5}' | sort -u)
unexpected=$(printf '%s\n' "$listeners" | grep -v -E '^(tcp|udp)/(127\.[0-9.]+|\[::1\]):[0-9]+$' | grep -v -x "tcp/${my_ip}:3773" | grep -v '^$' || true)
result INFO listeners "$(printf '%s' "$listeners" | tr '\n' ' ')"
if [ -z "$unexpected" ]; then
  result PASS listeners "only T3 on ${my_ip}:3773 (plus loopback)"
else
  result FAIL listeners "unexpected: $(printf '%s' "$unexpected" | tr '\n' ' ')"
fi
if printf '%s\n' "$listeners" | grep -q -x "tcp/${my_ip}:3773"; then
  result PASS t3-listening "${my_ip}:3773"
else
  result FAIL t3-listening "nothing on ${my_ip}:3773"
fi
if systemctl is-active --quiet sshd.service 2>/dev/null; then
  result FAIL no-sshd "sshd is running"
else
  result PASS no-sshd "no sshd"
fi

# --- disk -----------------------------------------------------------------------
home_src=$(findmnt -n -o SOURCE,FSTYPE --target /home | tr -s ' ')
home_gib=$(df -BG --output=size /home | tail -n1 | tr -dc '0-9')
if [ "${home_gib:-0}" -ge 90 ] && [ "${home_gib:-0}" -le 101 ]; then
  result PASS home-size "/home ${home_gib}G on ${home_src}"
else
  result FAIL home-size "/home ${home_gib:-?}G on ${home_src}"
fi
result INFO df "$(df -h --output=target,size,used,avail /home /nix/store / | tail -n +2 | tr -s ' ' | tr '\n' ';')"

# --- no shared host paths ---------------------------------------------------------
shares=$(findmnt -rn -o TARGET,FSTYPE | awk '$2 == "virtiofs" || $2 == "9p" {print}')
if [ -z "$shares" ]; then
  result PASS no-host-shares "no virtiofs/9p mounts"
else
  result FAIL no-host-shares "$shares"
fi

# --- Nix store: only the bay closure plus own builds -----------------------------
if [ -d /nix/.ro-store ]; then
  closure=$(nix-store -qR /run/current-system 2>/dev/null | sed 's|^/nix/store/||' | sort -u)
  ro=$(find /nix/.ro-store -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -u)
  # The image also carries the closure registration (regInfo= on the kernel command line).
  reginfo=$(tr ' ' '\n' </proc/cmdline | sed -n 's|^regInfo=/nix/store/\([^/]*\)/.*|\1|p')
  extra_ro=$(comm -23 <(printf '%s\n' "$ro") <(printf '%s\n' "$closure") | grep -v -x -F -e .links -e "${reginfo:-none}" || true)
  n_ro=$(printf '%s\n' "$ro" | grep -c . || true)
  n_cl=$(printf '%s\n' "$closure" | grep -c . || true)
  if [ -z "$extra_ro" ] && [ "$n_cl" -gt 0 ]; then
    result PASS store-closure "read-only store has $n_ro paths, all in the system closure ($n_cl paths)"
  else
    result FAIL store-closure "not in closure: $(printf '%s' "$extra_ro" | head -n 20 | tr '\n' ' ')"
  fi
  all=$(find /nix/store -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -u)
  own=$(comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$ro") | grep -c . || true)
  result INFO store-own-builds "$own paths in the writable overlay"
else
  result FAIL store-closure "/nix/.ro-store missing"
fi
for p in "${absent_store[@]}"; do
  if [ -e "/nix/store/$p" ]; then
    result FAIL absent-store "$p present"
  else
    result PASS absent-store "$p"
  fi
done

# --- nothing of the host side visible ----------------------------------------------
# Text files and file names outside the store. /etc is followed into the store
# (its entries are symlinks to the generated configuration). Public reference
# data that ships with every system (IANA service names, CA certificates)
# contains ordinary words such as names; hits there are reported, not failed.
# Hits in the bay user's own files (/home) are reported too: they are written
# at run time (for example the HTTP Host header of a client in T3's logs).
for term in "${search_all[@]}"; do
  sys_hits=$(
    {
      grep -rIlsiF --exclude-dir=home --exclude-dir=nix -- "$term" /root /var /tmp /run /srv /opt /data 2>/dev/null
      grep -RIlsiF --exclude-dir=ssl --exclude-dir=pki --exclude=services --exclude=protocols -- "$term" /etc 2>/dev/null
      find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /nix -o -path /home \) -prune -o -iname "*${term}*" -print 2>/dev/null
      find /run /data -xdev \( -path /data/home -o -path /data/nix \) -prune -o -iname "*${term}*" -print 2>/dev/null
    } | sort -u | head -n 20
  )
  public_hits=$(grep -RlsiF -- "$term" /etc/services /etc/protocols /etc/ssl /etc/pki 2>/dev/null | sort -u | tr '\n' ' ')
  home_hits=$(
    {
      grep -rIlsiF -- "$term" /home 2>/dev/null
      find /home -xdev -iname "*${term}*" -print 2>/dev/null
    } | sort -u | head -n 10 | tr '\n' ' '
  )
  if [ -z "$sys_hits" ]; then
    result PASS search-all "'$term' not found outside /home and public reference data"
  else
    result FAIL search-all "'$term' in: $(printf '%s' "$sys_hits" | tr '\n' ' ')"
  fi
  [ -z "$public_hits" ] || result INFO search-public "'$term' in public reference data: $public_hits"
  [ -z "$home_hits" ] || result INFO search-home "'$term' in the bay user's files: $home_hits"
done
# The whole store, binaries included.
for term in "${search_store[@]}"; do
  hits=$(
    {
      grep -rlsiF -- "$term" /nix/store 2>/dev/null
      find /nix/store -mindepth 1 -maxdepth 1 -iname "*${term}*" -print 2>/dev/null
    } | sort -u | head -n 20
  )
  if [ -z "$hits" ]; then
    result PASS search-store "'$term' not found"
  else
    result FAIL search-store "'$term' in: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
done

printf 'SUMMARY pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
