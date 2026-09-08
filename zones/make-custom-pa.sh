#!/usr/bin/env bash
# Erzeugt die custom.pa, die aus dem 8-Kanal-Sink der Karte vier Stereo-Sinks
# macht -- einen je Zone aus zones.conf.
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
# HAs PulseAudio zieht sie am Ende seiner system.pa mit
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

    cat <<EOF
# ${label} -- ${chanmap} des Master-Sinks, also ein Ausgangspaar der Karte.
# remix=no, damit ein Stereo-Stream genau auf diese zwei Buchsen geht und
# PulseAudio ihn nicht auf die Kanalpositionen der Zielmap hochrechnet.
load-module module-remap-sink sink_name=${sink} sink_properties=device.description="${label}" master=${master} master_channel_map=${chanmap} channels=2 channel_map=front-left,front-right remix=no

EOF
done < "${conf}"

cat <<'EOF'
# module-switch-on-connect ist in HAs system.pa geladen: es macht jeden neu
# auftauchenden Sink zum Default. Die vier oben tauchen bei jedem Start auf, und
# der letzte von ihnen wuerde damit zum Default-Sink der ganzen Maschine -- also
# dorthin, wo HAs eigene Ansagen und jedes Add-on ohne eigene Auswahl landen.
# Die Zeile setzt den Default zurueck auf die Karte als Ganzes, nachdem die
# Zonen da sind. Wer stattdessen einen bestimmten Sink als Default will, traegt
# ihn hier ein.
EOF
printf 'set-default-sink %s\n' "${master}"
