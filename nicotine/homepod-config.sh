#!/bin/bash
# homepod-config.sh - keep a HomePod Linux pod's settings on this Mac.
#
#   ./homepod-config.sh save                 pull a backup from the running pod
#   ./homepod-config.sh restore [--wait N] [--auto]
#                                            push this pod's backup back to it
#   ./homepod-config.sh status               what the pod and this folder have
#
# Why: Nicotine runs from RAM. From build 117 the pod keeps its settings on its
# own flash and puts them back when it starts; before that, a WiFi network
# joined in the web UI, a changed AirPlay name and every Bluetooth pairing were
# gone after a reboot. This script keeps a copy here as well:
#   - after changing something on the pod, run "save"
#   - after a boot, run "restore". With --auto (what HomePod Hospital does by
#     itself after it boots a pod) a pod that has already put back its own
#     settings keeps them, and takes only what its flash has no room for (a boot
#     sound of your own); the backup here is then refreshed from the pod, the
#     file it replaces staying as .prev. Without --auto the backup replaces the
#     pod's settings.
# Backups live in ./config/homepod-config-<unit>.tar.gz next to this script,
# one per pod (<unit> is the pod's 4-digit ID, shown by "status" and in the
# web UI). They contain the WiFi key and the Bluetooth link keys.
#
# Talks to the pod over the USB network (http://172.16.42.1). Needs only curl.
# To reach it another way, set HOMEPOD_URL, for example
#   HOMEPOD_URL=http://192.0.2.10 ./homepod-config.sh save
# Works with the bash 3.2 that ships with macOS.
set -u

POD="${HOMEPOD_URL:-http://172.16.42.1}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DIR="${HOMEPOD_CONFIG_DIR:-$HERE/config}"
CURL="${CURL:-curl}"
API="$POD/cgi-bin/config.cgi"

say() { echo "homepod-config: $*"; }
die() { echo "homepod-config: $*" >&2; exit 1; }

command -v "$CURL" >/dev/null 2>&1 || die "curl not found"

# json_str KEY / json_num KEY: one field out of a flat JSON answer on stdin
json_str() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -n 1; }
json_num() { sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p' | head -n 1; }

unhex() {	# hex on stdin -> text
	if command -v xxd >/dev/null 2>&1; then xxd -r -p
	else perl -e 'local $/; my $h = <STDIN>; $h =~ s/[^0-9a-fA-F]//g; print pack("H*", $h)'
	fi
}

pod_up() { "$CURL" -s -o /dev/null -m 3 "$POD/" 2>/dev/null; }

wait_for_pod() {	# wait_for_pod SECONDS
	local limit=$1 start=$SECONDS
	while ! pod_up; do
		[ $((SECONDS - start)) -ge "$limit" ] && return 1
		sleep 2
	done
	return 0
}

pod_info() {
	local j
	j=$("$CURL" -s -m 10 "$API?action=info" 2>/dev/null) || return 1
	case "$j" in *'"ok":true'*'"available":true'*) printf '%s\n' "$j" ;; *) return 1 ;; esac
}

pod_unit() {
	local u
	u=$(printf '%s\n' "$1" | json_str unit)
	case "$u" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
	printf '%s\n' "$u"
}

cmd_save() {
	local info unit file tmp n
	pod_up || die "the pod does not answer at $POD (is it booted, and is the USB cable in?)"
	info=$(pod_info) || die "this pod's software has no backup support (config.cgi did not answer)"
	unit=$(pod_unit "$info") || die "could not read the pod's unit ID"
	mkdir -p "$DIR" || die "cannot create $DIR"
	chmod 700 "$DIR" 2>/dev/null
	file="$DIR/homepod-config-$unit.tar.gz"
	tmp="$file.part"
	rm -f "$tmp"
	( umask 077; "$CURL" -s -f -m 60 -o "$tmp" "$API?action=export" ) || { rm -f "$tmp"; die "download failed"; }
	if ! gzip -t "$tmp" 2>/dev/null || ! tar -tzf "$tmp" 2>/dev/null | grep -q '^MANIFEST$'; then
		n=$(head -c 300 "$tmp" | json_str error)
		rm -f "$tmp"
		die "the pod did not send a backup${n:+: $n}"
	fi
	[ -f "$file" ] && mv -f "$file" "$file.prev"
	mv -f "$tmp" "$file" || die "cannot write $file"
	chmod 600 "$file" 2>/dev/null
	say "saved pod $unit to $file ($(wc -c < "$file" | tr -d ' ') bytes)"
	tar -tzf "$file" 2>/dev/null | grep -v '/$' | grep -v '^MANIFEST$' | sed 's/^/    /'
	say "this file holds the WiFi key and the Bluetooth link keys; keep it private"
}

cmd_restore() {
	local wait=0 auto="" info unit file ans out err
	while [ $# -gt 0 ]; do
		case "$1" in
		--wait) [ $# -ge 2 ] || die "--wait needs a number of seconds"; wait=$2; shift 2 ;;
		--auto) auto="&auto=1"; shift ;;
		*) die "restore: unknown option $1" ;;
		esac
	done
	case "$wait" in ''|*[!0-9]*) die "--wait needs a number of seconds" ;; esac
	if ! pod_up; then
		[ "$wait" -gt 0 ] || die "the pod does not answer at $POD"
		say "waiting up to $wait s for the pod at $POD ..."
		wait_for_pod "$wait" || die "the pod did not answer within $wait s; nothing restored"
	fi
	info=$(pod_info) || die "this pod's software has no backup support (config.cgi did not answer)"
	unit=$(pod_unit "$info") || die "could not read the pod's unit ID"
	file="$DIR/homepod-config-$unit.tar.gz"
	if [ ! -f "$file" ]; then
		say "no backup for pod $unit in $DIR; nothing to restore"
		say "(make one with: $0 save)"
		return 0
	fi
	say "restoring pod $unit from $file ..."
	# "Expect:" stops curl from pausing for a 100-continue the pod never sends
	ans=$("$CURL" -s -m 200 -H 'Content-Type: application/x-homepod' -H 'Expect:' \
		--data-binary @"$file" "$API?action=import$auto" 2>/dev/null)
	if [ -z "$ans" ]; then
		# over USB the answer does not depend on the pod's WiFi, so an empty
		# one is a real failure; ask the pod what it thinks happened
		info=$(pod_info) && say "no answer; the pod reports last restore: $(printf '%s\n' "$info" | json_str last_import_result)"
		die "restore: no answer from the pod"
	fi
	out=$(printf '%s\n' "$ans" | json_str output_hex | unhex)
	[ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
	case "$ans" in
	*'"ok":true'*'"partial":true'*)
		say "restored, but one step did not go through (see the lines above)"
		return 3 ;;
	*'"ok":true'*)
		case "$out" in
		*settings=kept*)
			# The pod's own copy is the newer one. Bring this Mac's copy up to date with it
			# (the previous file stays next to it as .prev), so that the Mac has the latest
			# settings if the pod's copy is ever lost. A subshell: a failed save must not
			# turn a good start into an error.
			say "the pod put its own saved settings back when it started; they were kept"
			if ( cmd_save ) >/dev/null 2>&1; then say "this pod is using the settings it keeps itself; the copy on this Mac was updated from it"
			else say "this pod is using the settings it keeps itself (the copy on this Mac could not be updated)"; fi ;;
		*) say "restored" ;;
		esac
		return 0 ;;
	*)
		err=$(printf '%s\n' "$ans" | json_str error)
		die "the pod refused the backup: ${err:-unknown reason}" ;;
	esac
}

cmd_status() {
	local info
	if pod_up && info=$(pod_info); then
		say "pod at $POD: unit $(printf '%s\n' "$info" | json_str unit)," \
			"WiFi MAC $(printf '%s\n' "$info" | json_str wifi_mac)," \
			"$(printf '%s\n' "$info" | json_num bt_devices) paired Bluetooth device(s)"
		say "  last backup taken:   $(printf '%s\n' "$info" | json_str last_export)"
		say "  last restore:        $(printf '%s\n' "$info" | json_str last_import)" \
			"($(printf '%s\n' "$info" | json_str last_import_result))"
	elif pod_up; then
		say "pod at $POD answers, but its software has no backup support"
	else
		say "pod at $POD: no answer"
	fi
	if ls "$DIR"/homepod-config-*.tar.gz >/dev/null 2>&1; then
		say "backups in $DIR:"
		ls -l "$DIR"/homepod-config-*.tar.gz | sed 's/^/    /'
	else
		say "no backups in $DIR yet"
	fi
}

case "${1:-}" in
save)    cmd_save ;;
restore) shift; cmd_restore ${1+"$@"} ;;
status)  cmd_status ;;
*)
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit 2 ;;
esac
