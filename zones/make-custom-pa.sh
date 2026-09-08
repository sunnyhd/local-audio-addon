#!/usr/bin/env bash
# Erzeugt die custom.pa, die den mehrkanaligen Ausgang in die Zonen aus
# zones.conf schneidet.
#
# Aufruf:  ./make-custom-pa.sh <master-sink-name> [zones.conf] > custom.pa
#
# Der Master-Sink-Name ist der des mehrkanaligen Ausgangs, auszulesen auf der
# HA-Konsole mit `ha audio info`. Er sieht ungefaehr so aus:
#   alsa_output.usb-<Hersteller>_<Modell>-00.analog-surround-71
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Aufruf: $0 <master-sink-name> [zones.conf]" >&2
    exit 1
fi

master=$1
conf=${2:-"$(dirname "$0")/zones.conf"}

# Ein Sink-Name mit Leerzeichen oder Anfuehrungszeichen wuerde die erzeugte
# Modulzeile zerlegen. Lieber hier abbrechen als eine custom.pa schreiben, die
# PulseAudio halb einliest.
case ${master} in
    *[[:space:]\"\']*)
        echo "Der Sink-Name enthaelt Leerzeichen oder Anfuehrungszeichen: ${master}" >&2
        exit 1
        ;;
esac

cat <<EOF
# ==============================================================================
# Stereo-Zonen auf einem mehrkanaligen Ausgang
#
# Erzeugt von zones/make-custom-pa.sh -- Aenderungen hier gehen beim naechsten
# Lauf verloren, also zones.conf pflegen und neu erzeugen.
#
# Diese Datei gehoert auf der HA-Maschine nach /mnt/data/supervisor/audio/custom.pa.
# HAs PulseAudio zieht sie am Ende ihrer system.pa mit
#   .nofail
#   .include /data/custom.pa
# ein -- ein offizieller Erweiterungspunkt, und /data ueberlebt Updates des
# Audio-Plugins. Das .nofail davor heisst: eine kaputte Zeile hier haelt HAs
# Audio nicht an, sie steht dann nur im Log des Audio-Plugins.
#
# Master-Sink: ${master}
# ==============================================================================

EOF

lineno=0
seen=''
while IFS='|' read -r suffix label sink chanmap || [ -n "${suffix}" ]; do
    lineno=$((lineno + 1))
    case ${suffix} in '' | '#'*) continue ;; esac

    if [ -z "${label}" ] || [ -z "${sink}" ] || [ -z "${chanmap}" ]; then
        echo "zones.conf Zeile ${lineno}: unvollstaendig, vier Spalten erwartet." >&2
        exit 1
    fi

    # Ein Anfuehrungszeichen im Anzeigenamen beendet den sink_properties-Wert
    # mitten in der Zeile, und der Rest der Zeile wird als weitere Modulargumente
    # gelesen. Leerzeichen sind dagegen in Ordnung: dafuer stehen die
    # Anfuehrungszeichen ueberhaupt da.
    case ${label} in
        *[\"\']*)
            echo "zones.conf Zeile ${lineno}: Anzeigename enthaelt ein Anfuehrungszeichen." >&2
            exit 1
            ;;
    esac

    # Ein Sink-Name ausserhalb [a-z0-9_] ist entweder ein PulseAudio-Fehler beim
    # Laden oder ein Wert, der die Modulzeile zerlegt.
    case ${sink} in
        *[!a-z0-9_]*)
            echo "zones.conf Zeile ${lineno}: Sink-Name \"${sink}\" -- erlaubt sind a-z, 0-9 und _." >&2
            exit 1
            ;;
    esac

    # Zwei Zonen mit demselben Sink-Namen waeren keine zwei Zonen: das zweite
    # module-remap-sink scheitert an der Namenskollision, und weil HAs system.pa
    # die custom.pa unter .nofail einliest, faellt genau diese Zone still aus.
    case " ${seen} " in
        *" ${sink} "*)
            echo "zones.conf Zeile ${lineno}: Sink-Name \"${sink}\" kommt mehrfach vor." >&2
            exit 1
            ;;
    esac
    seen="${seen} ${sink}"

    case ${chanmap} in
        *[!a-z0-9,-]*)
            echo "zones.conf Zeile ${lineno}: Kanalliste \"${chanmap}\" -- erlaubt sind a-z, 0-9, - und Komma." >&2
            exit 1
            ;;
    esac

    # Wie viele Kanaele die Zone belegt, steht in Spalte 4 und wird nicht
    # geraten. Zwei Positionen sind eine Stereo-Zone; mehr als zwei eine Zone
    # ueber alle genannten Kanaele.
    count=$(printf '%s' "${chanmap}" | tr ',' '\n' | grep -c .)

    if [ "${count}" -lt 2 ]; then
        echo "zones.conf Zeile ${lineno}: \"${chanmap}\" nennt weniger als zwei Kanaele." >&2
        exit 1
    fi

    if [ "${count}" -eq 2 ]; then
        # Nach aussen ist jede Stereo-Zone gewoehnliches front-left,front-right,
        # ganz gleich, auf welchen Buchsen sie physisch liegt -- ein Player
        # schickt Stereo und muss nichts von rear-left wissen.
        target_map='front-left,front-right'
        note="${chanmap} des Master-Sinks, also ein Ausgangspaar der Karte"
    else
        # Die Zone ueber alle Kanaele: Ein- und Ausgangsmap sind dieselbe.
        target_map=${chanmap}
        note="alle ${count} Kanaele zugleich"
    fi

    cat <<EOF
# ${label} -- ${note}.
# Der Wert von sink_properties steht in doppelten *und* einfachen Anfuehrungs-
# zeichen. Ohne die inneren zerlegt PulseAudio einen Namen mit Leerzeichen in
# zwei Argumente und lehnt die ganze Zeile mit "Failed to parse module
# arguments" ab -- beobachtet an einer Zone namens "Alle Zonen", waehrend die
# vier einwortigen daneben luden.
# remix=no betrifft die Abbildung zwischen dieser Zone und dem Master: was hier
# hineingeht, geht genau auf die genannten Buchsen und wird nicht auf die
# uebrigen Kanalpositionen hochgerechnet.
load-module module-remap-sink sink_name=${sink} sink_properties="device.description='${label}'" master=${master} master_channel_map=${chanmap} channels=${count} channel_map=${target_map} remix=no

EOF
done < "${conf}"

cat <<'EOF'
# ------------------------------------------------------------------------------
# Aufraeumen hinter den Modulen oben. Die drei folgenden Zeilen stammen aus dem
# Music-Assistant-PR, der dieselbe Topologie im Server bauen sollte (#5132,
# geschlossen ohne Merge) -- dort standen sie als das, was sich im Betrieb als
# noetig herausgestellt hatte.
# ------------------------------------------------------------------------------

# module-device-restore ist in HAs system.pa geladen und stellt die zuletzt
# gesetzte Lautstaerke des Master-Sinks wieder her. Die liegt aber *unter* jeder
# Zone: ein Master auf 40% daempft alle Zonen um 40%, und zwar unsichtbar --
# die Zonenregler stehen weiter auf 100, Music Assistant zeigt volle Lautstaerke,
# und es ist trotzdem leise. Der Master gehoert deshalb auf Anschlag; geregelt
# wird in den Zonen. 65536 ist PulseAudios 100%.
EOF
printf 'set-sink-volume %s 65536\n\n' "${master}"

cat <<'EOF'
# Einmal aus- und wieder einschalten, nachdem die Zonen angelegt sind. Das setzt
# den Zustand des ALSA-Treibers zurueck, der die Kanaele jetzt anders zugeteilt
# bekommt als beim Start des Geraets.
EOF
printf 'suspend-sink %s 1\nsuspend-sink %s 0\n\n' "${master}" "${master}"

cat <<'EOF'
# module-switch-on-connect ist ebenfalls geladen: es macht jeden neu
# auftauchenden Sink zum Default. Die Zonen oben tauchen bei jedem Start auf, und
# die letzte von ihnen wuerde damit zum Default-Sink der ganzen Maschine -- also
# dorthin, wo HAs eigene Ansagen und jedes Add-on ohne eigene Auswahl landen.
# Die Zeile setzt den Default zurueck auf die Karte als Ganzes. Wer stattdessen
# eine bestimmte Zone als Default will, traegt sie hier ein.
EOF
printf 'set-default-sink %s\n' "${master}"
