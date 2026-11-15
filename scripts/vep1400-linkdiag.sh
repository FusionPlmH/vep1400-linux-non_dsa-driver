#!/bin/bash
# Dell VEP1400 / VMware Edge 610 - decode the link state of one front panel
# port.
#
#   vep1400-linkdiag.sh [1-6]
#
# Prints the negotiated speed plus both sides' autonegotiation advertisement,
# which makes it obvious whether 1G is possible on this cable / peer or
# whether the partner only offers 10/100 Mbps.

set -u

PHY=/sys/kernel/debug/vep1400/phy
PORTS=/sys/kernel/debug/vep1400/ports
port=${1:-1}

case "$port" in
[1-6]) ;;
*)
	echo "usage: ${0##*/} [1-6]" >&2
	exit 1
	;;
esac

if [ ! -r "$PHY" ] || [ ! -r "$PORTS" ]; then
	echo "ERROR: debugfs files missing (module loaded? run as root)" >&2
	exit 1
fi

line=$(awk -v want="p$port" '$1 == want { print; exit }' "$PHY")
sline=$(awk -v want="$port" '$1 == want { print; exit }' "$PORTS")
if [ -z "$line" ] || [ -z "$sline" ]; then
	echo "ERROR: port $port not reported by the driver" >&2
	exit 1
fi

# PHY registers, as 0x.... so bash arithmetic accepts them
reg() { echo "$line" | tr ' ' '\n' | sed -n "s/^r$1=//p" | head -1 | sed 's/^/0x/'; }
has() { [ $(( $1 & $2 )) -ne 0 ]; }

# switch port status: bit 11 = link, bits 9:8 = speed, $8 = up/down
status=$(echo "$sline" | awk '{ print $2 }')
link=$(echo "$sline" | awk '{ print $8 }')

case $(( (status >> 8) & 3 )) in
3) speed=2.5G ;;
2) speed=1G ;;
1) speed=100M ;;
*) speed=10M ;;
esac
[ "$link" = up ] || speed="-"

bmcr=$(reg 00) bmsr=$(reg 01) anar=$(reg 04) lpar=$(reg 05)
t1000c=$(reg 09) t1000s=$(reg 0a) spec=$(reg 11)
for v in "$bmcr" "$bmsr" "$anar" "$lpar" "$t1000c"; do
	if [ -z "$v" ]; then
		echo "ERROR: PHY registers for port $port are not readable" >&2
		exit 1
	fi
done

adv_10_100() {
	local out=""

	has "$1" 0x0100 && out="$out 100FD"
	has "$1" 0x0080 && out="$out 100HD"
	has "$1" 0x0040 && out="$out 10FD"
	has "$1" 0x0020 && out="$out 10HD"
	echo "${out# }"
}

adv_of() {	# $1 anar/lpar, $2 1000BASE-T reg, $3 FD bit, $4 HD bit
	local out

	out=$(adv_10_100 "$1")
	has "$2" "$3" && out="$out 1000FD"
	has "$2" "$4" && out="$out 1000HD"
	echo "${out# }"
}

local_adv=$(adv_of "$anar" "$t1000c" 0x0200 0x0100)
# The link partner's 1000BASE-T status word is not decoded: its layout differs
# between Marvell PHY generations, and the negotiated speed already tells the
# truth.
peer_adv=$(adv_10_100 "$lpar")

[ "$link" = up ] && duplex=$([ $(( (spec >> 13) & 1 )) -eq 1 ] && echo full || echo half)
duplex=${duplex:--}

printf 'port %s: link %s  speed=%s  duplex=%s  an=%s  an-complete=%s\n' \
	"$port" "$link" "$speed" "$duplex" \
	"$(has "$bmcr" 0x1000 && echo on || echo off)" \
	"$(has "$bmsr" 0x0020 && echo yes || echo no)"
echo "  local: anar=$anar 1000t-ctrl=$t1000c -> [${local_adv:-none}]"
echo "  peer : anlpar=$lpar (10/100), 1000t-status=${t1000s:-?} -> [${peer_adv:-unknown}]"

case "$local_adv" in
*1000FD*) ;;
*) echo "  note : this side does not advertise 1000BASE-T, reload the module" ;;
esac

if [ "$link" = up ] && [ "$speed" != 1G ] && [ "$speed" != 2.5G ]; then
	case "$local_adv" in
	*1000FD*)
		echo "  note : 1000BASE-T is advertised but the link came up at" \
		     "$speed - check the cable and the peer port"
		;;
	esac
fi

if has "$t1000c" 0x1000 || has "$t1000c" 0x0800; then
	echo "  note : 1000BASE-T master/slave is forced ($t1000c)," \
	     "the driver programs 0x0200 (automatic)"
fi
exit 0
