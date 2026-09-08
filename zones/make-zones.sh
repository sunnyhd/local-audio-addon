#!/usr/bin/env bash
# Erzeugt eine zones.conf: aus einem mehrkanaligen Ausgang werden Stereo-Zonen,
# eine je Kanalpaar. Fuer jedes Interface, nicht fuer ein bestimmtes.
#
# Aufruf:  ./make-zones.sh <kanalzahl> [Name1 Name2 ...] > zones.conf
#
#   ./make-zones.sh 8 Wohnzimmer Kueche Bad Buero   -> 4 Stereo-Zonen
#   ./make-zones.sh 4                               -> 2 Zonen, "Zone 1", "Zone 2"
#   ./make-zones.sh 6 Wohnzimmer                    -> 3 Zonen, Rest generisch
#
# Die Kanalzahl ist die des Ausgangs, nicht die der Buchsen am Geraet: ein
# 8-Kanal-Interface, dessen Profil auf Stereo steht, hat hier 2. Wie man beides
# nachsieht, steht in README.de.md.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Aufruf: $0 <kanalzahl> [Zonenname ...]" >&2
    exit 1
fi

channels=$1
shift

case ${channels} in
    *[!0-9]* | '')
        echo "Die Kanalzahl \"${channels}\" ist keine Zahl." >&2
        exit 1
        ;;
esac

# Ungerade Kanalzahlen haben kein letztes Paar, und mehr als acht Kanaele hat
# keine der Standard-Kanalmaps unten. Beides ist ein Abbruch statt einer
# zones.conf, die halb stimmt.
if [ "${channels}" -lt 2 ] || [ "${channels}" -gt 8 ] || [ $((channels % 2)) -ne 0 ]; then
    echo "Kanalzahl ${channels}: erwartet wird eine gerade Zahl von 2 bis 8." >&2
    exit 1
fi

# Die Kanalpositionen, die PulseAudio einem Ausgang dieser Breite gibt, in der
# Reihenfolge der Buchsen. Das ist die ALSA-Konvention, der die Profile
# analog-stereo, -surround-40, -surround-51 und -surround-71 folgen.
case ${channels} in
    2) positions='front-left front-right' ;;
    4) positions='front-left front-right rear-left rear-right' ;;
    6) positions='front-left front-right rear-left rear-right front-center lfe' ;;
    8) positions='front-left front-right rear-left rear-right front-center lfe side-left side-right' ;;
esac

read -r -a position <<< "${positions}"
zone_count=$((channels / 2))

cat <<EOF
# Zonendefinition, erzeugt von zones/make-zones.sh aus ${channels} Kanaelen.
#
# Spalten, durch | getrennt:
#   1 slug-suffix  Anhaengsel an den Add-on-Slug. [a-z0-9_], kurz halten.
#   2 Anzeigename  So heisst der Player in Music Assistant und im HA-Seitenmenue.
#   3 Sink-Name    Name des PulseAudio-Sinks, [a-z0-9_].
#   4 Kanalpaar    Die zwei Kanaele des Ausgangs, die diese Zone belegt.
#
# Die Kanalpositionen in Spalte 4 sind Namen fuer Buchsen, keine Aussage
# darueber, was daran haengt -- "lfe" auf Ausgang 6 ist ein Etikett, kein
# Subwoofer. Zeile fuer Zeile gilt: Zone n liegt auf den Ausgaengen 2n-1 und 2n.
#
# Zonen dazunehmen oder wegnehmen geht durch Bearbeiten dieser Datei; danach
# make-custom-pa.sh und make-addons.sh erneut laufen lassen.
EOF

for ((i = 0; i < zone_count; i++)); do
    left=${position[$((i * 2))]}
    right=${position[$((i * 2 + 1))]}

    if [ "$#" -gt 0 ]; then
        label=$1
        shift
    else
        label="Zone $((i + 1))"
    fi

    # Der Sink-Name wird aus dem Anzeigenamen abgeleitet, weil zwei Zonen sonst
    # denselben bekaemen. Umlaute und alles andere ausserhalb [a-z0-9_] fallen
    # dabei weg -- PulseAudio-Sinknamen sind ASCII, und ein Name, den man in
    # eine Modulzeile schreibt, sollte keine Sonderzeichen tragen.
    # Umlaute werden ausgeschrieben statt entwertet, damit aus Kueche und Kuche
    # nicht derselbe Sink wird; alles weitere ausserhalb [a-z0-9_] faellt weg.
    # PulseAudio-Sinknamen sind ASCII, und ein Name, den man in eine Modulzeile
    # schreibt, sollte keine Sonderzeichen tragen.
    sink=$(printf '%s' "${label}" \
        | sed -e 's/Ä/Ae/g' -e 's/Ö/Oe/g' -e 's/Ü/Ue/g' \
              -e 's/ä/ae/g' -e 's/ö/oe/g' -e 's/ü/ue/g' -e 's/ß/ss/g' \
        | tr 'A-Z' 'a-z' \
        | tr -c 'a-z0-9' '_' \
        | sed -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')

    # Der Praefix bleibt weg, wo der Name ihn schon traegt: aus "Zone 1" wird
    # zone_1, nicht zone_zone_1.
    case ${sink} in
        '') sink="zone_$((i + 1))" ;;
        zone_*) ;;
        zone*) sink="zone_${sink#zone}" ;;
        *) sink="zone_${sink}" ;;
    esac
    sink=$(printf '%s' "${sink}" | sed -e 's/__*/_/g' -e 's/_$//')

    printf 'z%d|%s|%s|%s,%s\n' "$((i + 1))" "${label}" "${sink}" "${left}" "${right}"
done
