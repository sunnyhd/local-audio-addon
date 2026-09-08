#!/usr/bin/env bash
# Erzeugt eine zones.conf: aus einem mehrkanaligen Ausgang werden Stereo-Zonen,
# eine je Kanalpaar. Fuer jedes Interface, nicht fuer ein bestimmtes.
#
# Aufruf:  ./make-zones.sh <kanalzahl|kanalmap> [Name1 Name2 ...] > zones.conf
#
#   ./make-zones.sh 8 Wohnzimmer Kueche Bad Buero
#   ./make-zones.sh front-left,front-right,rear-left,rear-right Wohnzimmer Kueche
#
# Das erste Argument ist entweder die Kanalzahl des Ausgangs oder seine
# tatsaechliche Kanalmap. Die Map ist die bessere Angabe: aus einer Zahl muss
# geraten werden, welche Kanalpositionen dahinterstehen, und das stimmt nur,
# solange das Geraet der ALSA-Konvention folgt. `ha audio info` bzw.
# `pactl list sinks` nennen die echte Map -- wo sie zur Hand ist, gehoert sie
# hierher.
#
# Zonen entstehen nur fuer Paare, die in der Map auch wirklich vorkommen. Ein
# Ausgang mit sechs Kanaelen ergibt drei Zonen, einer mit acht vier, und einer
# mit Positionen, die zu keinem bekannten Paar gehoeren, entsprechend weniger.
set -euo pipefail

# Die vier Paare, aus denen eine Stereo-Zone werden kann. Das ist dieselbe
# Aufstellung, die der (nie veroeffentlichte) local_audio-Provider von Music
# Assistant in remap_topology.py fuehrte -- uebernommen, damit die Aufteilung
# hier dieselbe ist wie die, die dort funktioniert hat.
readonly PAIRS='front-left:front-right rear-left:rear-right front-center:lfe side-left:side-right'

# Ab dieser Breite bekommt der Ausgang zusaetzlich eine Zone ueber alle Kanaele
# -- die "alle Raeume"-Zone. Ebenfalls von dort uebernommen.
readonly PASSTHROUGH_MIN_CHANNELS=6

# Der Sink-Name benennt die Buchsen, nicht den Raum: out_3_4_rear sagt, wo das
# Kabel steckt, waehrend "Kueche" sagt, wer zuhoert. Das ist die Trennung, die
# zaehlt -- ein umbenannter Raum laesst die custom.pa unberuehrt, und im
# Auswahlfeld des Add-ons steht etwas, das man ohne Zettel wiedererkennt.
#
# Die Namensteile kommen aus der Kanalmap des Ausgangs, also von PulseAudio. Ein
# USB-Interface meldet in aller Regel keine eigenen Buchsennamen: die ESI
# GIGAPort eX etwa fuehrt fuer alle acht Ausgaenge zusammen genau einen Port,
# "Analog Output". Was es an Namen gibt, sind die Kanalpositionen.
sink_for_pair() {
    local left=$1 right=$2 first=$3 second=$4 kind

    case "${left},${right}" in
        front-left,front-right)  kind=front ;;
        rear-left,rear-right)    kind=rear ;;
        front-center,lfe)        kind=center_sub ;;
        side-left,side-right)    kind=side ;;
        *)                       kind=$(printf '%s' "${left}" | tr -c 'a-z0-9' '_' | sed 's/_*$//') ;;
    esac

    printf 'out_%d_%d_%s\n' "${first}" "${second}" "${kind}"
}

if [ "$#" -lt 1 ]; then
    echo "Aufruf: $0 <kanalzahl|kanalmap> [Zonenname ...]" >&2
    exit 1
fi

spec=$1
shift

case ${spec} in
    *[!0-9]*)
        # Eine Kanalmap: uebernommen, wie sie ist.
        channel_map=${spec}
        ;;
    '')
        echo "Erstes Argument fehlt." >&2
        exit 1
        ;;
    *)
        # Eine Kanalzahl: die Map, die ein Geraet dieser Breite ueblicherweise
        # hat. ALSA-Konvention, der die Profile analog-stereo, -surround-40,
        # -surround-51 und -surround-71 folgen.
        if [ "${spec}" -lt 2 ] || [ "${spec}" -gt 8 ] || [ $((spec % 2)) -ne 0 ]; then
            echo "Kanalzahl ${spec}: erwartet wird eine gerade Zahl von 2 bis 8, oder eine Kanalmap." >&2
            exit 1
        fi
        case ${spec} in
            2) channel_map='front-left,front-right' ;;
            4) channel_map='front-left,front-right,rear-left,rear-right' ;;
            6) channel_map='front-left,front-right,rear-left,rear-right,front-center,lfe' ;;
            8) channel_map='front-left,front-right,rear-left,rear-right,front-center,lfe,side-left,side-right' ;;
        esac
        ;;
esac

IFS=',' read -r -a position <<< "${channel_map}"
channels=${#position[@]}

if [ "${channels}" -lt 2 ]; then
    echo "Die Kanalmap \"${channel_map}\" hat weniger als zwei Kanaele." >&2
    exit 1
fi

# Position -> Index in der Map, damit die Zonen in der Reihenfolge der Buchsen
# herauskommen und nicht in der, in der die Paare oben notiert sind. Zone 1
# liegt dann auf dem ersten Kanalpaar des Geraets, Zone 2 auf dem zweiten.
index_of() {
    local target=$1 i
    for i in "${!position[@]}"; do
        if [ "${position[${i}]}" = "${target}" ]; then
            printf '%s\n' "${i}"
            return 0
        fi
    done
    return 1
}

# Erst sammeln, dann nach Index sortiert ausgeben.
found=''
for pair in ${PAIRS}; do
    left=${pair%%:*}
    right=${pair##*:}
    at=$(index_of "${left}") || continue
    index_of "${right}" > /dev/null || continue
    found="${found}${at} ${left} ${right}"$'\n'
done
found=$(printf '%s' "${found}" | sort -n)

if [ -z "${found}" ]; then
    echo "In \"${channel_map}\" steckt kein bekanntes Kanalpaar." >&2
    echo "Bekannt sind: ${PAIRS}" >&2
    exit 1
fi

cat <<EOF
# Zonendefinition, erzeugt von zones/make-zones.sh.
# Ausgang: ${channels} Kanaele -- ${channel_map}
#
# Spalten, durch | getrennt:
#   1 slug-suffix  Anhaengsel an den Add-on-Slug. [a-z0-9_], kurz halten.
#   2 Anzeigename  So heisst der Player in Music Assistant und im HA-Seitenmenue.
#   3 Sink-Name    Name des PulseAudio-Sinks, [a-z0-9_].
#   4 Kanaele      Die Kanaele des Ausgangs, die diese Zone belegt.
#
# Die Kanalpositionen in Spalte 4 sind Namen fuer Buchsen, keine Aussage
# darueber, was daran haengt -- "lfe" auf Ausgang 6 ist ein Etikett, kein
# Subwoofer. Zwei Positionen ergeben eine Stereo-Zone; mehr als zwei eine Zone,
# die auf alle genannten Kanaele zugleich spielt.
#
# Zonen dazunehmen oder wegnehmen geht durch Bearbeiten dieser Datei; danach
# make-custom-pa.sh und make-addons.sh erneut laufen lassen.
EOF

n=0
while read -r _ left right; do
    [ -n "${left}" ] || continue
    n=$((n + 1))

    if [ "$#" -gt 0 ]; then
        label=$1
        shift
    else
        label="Zone ${n}"
    fi

    printf 'z%d|%s|%s|%s,%s\n' "${n}" "${label}" \
        "$(sink_for_pair "${left}" "${right}" "$((n * 2 - 1))" "$((n * 2))")" \
        "${left}" "${right}"
done <<< "${found}"

# Die Zone ueber alle Kanaele zugleich -- was ein AV-Receiver "Multi Channel
# Stereo" nennt. Sie belegt dieselben Buchsen wie die Zonen darueber, was kein
# Konflikt ist: PulseAudio mischt, was gleichzeitig auf denselben Master geht.
# Wer sie nicht will, loescht die Zeile.
if [ "${channels}" -ge "${PASSTHROUGH_MIN_CHANNELS}" ]; then
    n=$((n + 1))
    if [ "$#" -gt 0 ]; then
        label=$1
        shift
    else
        label='Alle Zonen'
    fi
    printf 'z%d|%s|out_all|%s\n' "${n}" "${label}" "${channel_map}"
fi
