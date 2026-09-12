# sigmond-rac — the band table and the proxy-block renderer.
#
# Sourced by install.sh and install-host.sh (and so part of the payload the
# proxmox bootstrap copies alongside them).  Keeping it here, beside the
# config templates, means a NEW SERVICE IS A NEW ROW IN THIS TABLE plus one
# entry in a site's proxy set — no change to either installer.
#
# A site has ONE number (its RAC/DASI number).  Every service it publishes
# gets a band, and a band's remote port is its base plus that number, so the
# whole port set follows from the one number and no port is picked by hand.
# Admins reach every one of them at the gateway's VPN address, 10.3.2.1:<port>.
#
# The band's PREFIX says which machine the service is on, which is what makes
# one login per site work:  host_*  -> the hypervisor, over 127.0.0.1
#                           vm_*    -> the DASI2 VM, over the bridge
#
# Bases are fleet-wide: the same band means the same base at every site, on
# this gateway and on gw2.  Do not invent one — an unlisted band must be
# given its base explicitly (band:base=localport) and should be added here
# once the WsprDaemon admin has allocated it.
rac_band_base() {
  case "$1" in
    vm_ssh)    echo 35800 ;;   # the station's shell
    vm_grape)  echo 40800 ;;   # PSWS/GRAPE WWV carrier charts (:8088)
    vm_web)    echo 45800 ;;   # ka9q-web (:8081)
    vm_web2)   echo 46800 ;;   # 2nd RX888 web UI      -- see the warning below
    vm_web3)   echo 47800 ;;   # 3rd RX888 web UI
    host_ssh)  echo 50800 ;;   # the hypervisor's shell
    host_ui)   echo 55800 ;;   # Proxmox VE web UI (:8006)
    # vm_mag)  echo ????? ;;   # magnetometer page — base not yet allocated;
    #                          # until it is, pass  vm_mag:<base>=<port>
    *)         echo "" ;;
  esac
}
#
# WARNING: on vpn.hamsci.org the firewall accepts 46000-46999 from the OPEN
# INTERNET (everything else is VPN-only), so a vm_web2 port lands in a range
# the whole world can reach.  Check with the admin before using that band.

# rac_render_proxies <proxy-name prefix> <site number|""> <vm address> <spec...>
#
# Each spec is "band=localport", or "band:base=localport" for a band that is
# not in the table yet.  Emits one [[proxies]] block per spec on stdout.
# With no site number, ports render as <PORT_band> placeholders so the file
# is still obviously incomplete rather than silently wrong.
rac_render_proxies() {
  local proxy="$1" rac="$2" vm_ip="$3" spec band base lport ip port
  shift 3
  for spec in "$@"; do
    band="${spec%%=*}"; lport="${spec#*=}"
    base=""
    case "$band" in
      *:*) base="${band#*:}"; band="${band%%:*}" ;;
      *)   base="$(rac_band_base "$band")" ;;
    esac
    if [ -z "$base" ]; then
      echo "rac: ERROR: unknown band '$band' — add it to config/rac-bands.sh," >&2
      echo "rac:   or pass it as '${band}:<base>=${lport}' with the base the" >&2
      echo "rac:   WsprDaemon admin allocated." >&2
      return 1
    fi
    case "$lport" in ''|*[!0-9]*) echo "rac: ERROR: bad local port in '$spec'" >&2; return 1 ;; esac
    case "$band" in
      host_*) ip="127.0.0.1" ;;
      vm_*)   ip="$vm_ip" ;;
      *)      echo "rac: ERROR: band '$band' must start with host_ or vm_" >&2; return 1 ;;
    esac
    if [ -n "$rac" ]; then port=$(( base + rac )); else port="<PORT_${band}>"; fi
    printf '\n[[proxies]]\nname = "%s-%s"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s   # %s + %s\n' \
      "$proxy" "$(printf '%s' "$band" | tr '_' '-')" "$ip" "$lport" "$port" "$base" "${rac:-<site number>}"
  done
}
