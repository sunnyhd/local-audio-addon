#!/usr/bin/env bash
# Erzeugt aus local_audio/ eine Add-on-Kopie je Zone aus zones.conf.
#
# Aufruf:  ./make-addons.sh <zielverzeichnis> [zones.conf] [server]
#
#   ./make-addons.sh /tmp/addons                              # zum Ansehen
#   ./make-addons.sh /addons zones.conf 192.168.1.10:8927     # auf der HA-Maschine
#
# Das dritte Argument ist die Adresse des Music-Assistant-Servers, und auf einer
# Maschine mit mehr als einer Instanz ist es keine Kuer. Alle Instanzen laufen
# mit `host_network: true` im selben Netzwerk-Namespace, und jede startet ihren
# eigenen avahi-daemon, solange sie sich ueber mDNS anbieten soll -- vier
# Responder, die sich um Port 5353 streiten. Eine gesetzte Server-Adresse
# unterdrueckt das Advertisement (der Player waehlt sich stattdessen ein), womit
# der gebuendelte avahi in jeder Instanz unten bleibt und der Streit entfaellt.
# Ohne dieses Argument bleiben die Kopien auf mDNS, und dann sollte genau eine
# davon laufen.
#
# Jede Kopie ist ein eigenstaendiges lokales Add-on mit eigenem Slug. Sie baut
# kein Image: das Manifest traegt `image:`, also zieht der Supervisor dasselbe
# veroeffentlichte Image, das auch das Original zieht. Geaendert wird nur das
# Manifest -- damit gibt es hier keinen Fork des Players zu pflegen, und ein
# Upstream-Update ist ein neuer Versionsstring statt eines Merges.
#
# Drei Dinge muessen je Kopie verschieden sein, und alle drei sind der Grund,
# warum es dieses Skript gibt statt vier Mal Copy-Paste:
#
#   slug            Der Supervisor fuehrt ein Add-on pro Slug. Gleicher Slug,
#                   gleiches Add-on -- vier Ordner mit `local_audio` darin sind
#                   nicht vier Player.
#   AppArmor-Profil Der Profilname muss den Slug tragen, sonst laedt der
#                   Supervisor das Profil des jeweils anderen.
#   SENDSPIN_ID     Ohne eigene ID leiten alle Instanzen dieselbe aus der MAC
#                   der Netzwerkkarte ab. Ein Music-Assistant-Server legt
#                   Lautstaerke, Gruppen und Pairing unter dieser ID ab, also
#                   landen die Einstellungen aller vier Zonen auf der, die sich
#                   zuletzt verbunden hat.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_addon="${here}/../local_audio"

if [ "$#" -lt 1 ]; then
    echo "Aufruf: $0 <zielverzeichnis> [zones.conf]" >&2
    exit 1
fi

target=$1
conf=${2:-"${here}/zones.conf"}
server=${3:-}

[ -d "${source_addon}" ] || { echo "Kein local_audio/ neben zones/ gefunden." >&2; exit 1; }
[ -r "${conf}" ] || { echo "zones.conf nicht lesbar: ${conf}" >&2; exit 1; }
mkdir -p "${target}"

lineno=0
seen=''
while IFS='|' read -r suffix label sink chanmap || [ -n "${suffix}" ]; do
    lineno=$((lineno + 1))
    case ${suffix} in '' | '#'*) continue ;; esac

    if [ -z "${label}" ] || [ -z "${sink}" ]; then
        echo "zones.conf Zeile ${lineno}: unvollstaendig." >&2
        exit 1
    fi

    # Der Slug landet in einem AppArmor-Profilnamen und in einem Verzeichnisnamen.
    case ${suffix} in
        *[!a-z0-9_]*)
            echo "zones.conf Zeile ${lineno}: slug-suffix \"${suffix}\" -- erlaubt sind a-z, 0-9 und _." >&2
            exit 1
            ;;
    esac
    case " ${seen} " in
        *" ${suffix} "*)
            echo "zones.conf Zeile ${lineno}: slug-suffix \"${suffix}\" kommt mehrfach vor." >&2
            exit 1
            ;;
    esac
    seen="${seen} ${suffix}"

    slug="local_audio_${suffix}"
    dir="${target}/${slug}"

    mkdir -p "${dir}"
    cp "${source_addon}/apparmor.txt" "${source_addon}/README.md" "${dir}/"
    cp -R "${source_addon}/translations" "${dir}/"

    # Der Profilname ist das Einzige im Profil, das den Slug traegt; der Rest
    # der 260 Zeilen ist Pfad- und Capability-Politik und gilt unveraendert.
    sed -i.bak "s/^profile local_audio /profile ${slug} /" "${dir}/apparmor.txt"
    rm -f "${dir}/apparmor.txt.bak"
    grep -q "^profile ${slug} " "${dir}/apparmor.txt" \
        || { echo "AppArmor-Profil in ${slug} nicht umbenannt." >&2; exit 1; }

    # Das Manifest wird nicht kopiert und gepatcht, sondern aus dem Original
    # gelesen und neu geschrieben: die Kopie unterscheidet sich in genug Feldern,
    # dass eine Kette von sed-Ausdrücken schwerer zu lesen waere als das hier.
    python3 - "${source_addon}/config.yaml" "${dir}/config.yaml" \
        "${slug}" "${label}" "${sink}" "${server}" <<'PY'
import re
import sys

source, dest, slug, label, sink, server = sys.argv[1:7]
text = open(source, encoding='utf-8').read()

# Der Slug traegt die Instanz. Der Name ist, was in der Seitenleiste und im
# Add-on-Store steht, und traegt deshalb die Zone.
text = re.sub(r'^name: .*$', f'name: Local Audio – {label}', text, count=1, flags=re.M)
text = re.sub(r'^slug: .*$', f'slug: {slug}', text, count=1, flags=re.M)

# `options.name` ist der Name, unter dem der Player in Music Assistant auftaucht.
# Leer gelassen hiesse jede Instanz "Local Audio", und vier gleichnamige Player
# sind in der Geraeteliste des Servers nicht auseinanderzuhalten.
text = re.sub(r'^  name: ""$', f'  name: "{label}"', text, count=1, flags=re.M)

# `output` war bis 0.1.10 eine Option des Add-ons und wurde entfernt, weil auf
# einer Ein-Player-Maschine das Audio-Panel die ganze Antwort ist. Hier ist es
# das nicht: vier Instanzen brauchen vier verschiedene Ziele, und das Panel
# vergibt eines pro Add-on. common.sh liest den Schluessel unveraendert weiter
# aus der Supervisor-Config, also genuegt es, ihn ins Manifest zurueckzuholen --
# am Image aendert sich nichts.
#
# Der Wert ist `pulse:<sink>` und damit der native PulseAudio-Ausgang des
# Players, nicht ALSA: er benennt einen Sink der PulseAudio, die `audio: true`
# hereinreicht. Ein `hw:`-Wert waere das, was das Add-on nicht kann -- ohne
# rohen Zugriff auf /dev/snd oeffnet er nicht und haelt die Instanz an.
options = re.search(r'^options:$', text, flags=re.M)
if not options:
    sys.exit('Kein options:-Block im Manifest.')
text = re.sub(r'^  log_level: info$', f'  output: pulse:{sink}\n  log_level: info',
              text, count=1, flags=re.M)
text = re.sub(r'^  log_level: list\(', '  output: str?\n  log_level: list(',
              text, count=1, flags=re.M)

# `server` steht im Original-Schema, aber nicht in `options`, weil es dort
# hinter die Klappe gehoert, die man absichtlich aufmacht. Hier ist es der
# Normalfall statt der Ausnahme: es ist das, was den gebuendelten avahi jeder
# Instanz unten haelt. Leer gelassen bleibt es aus dem Manifest heraus -- ein
# leeres `server:` waere nicht dasselbe, das schaltet den Player auf Einwahl
# ohne Ziel.
if server:
    text = re.sub(r'^  output: ', f'  server: {server}\n  output: ', text,
                  count=1, flags=re.M)

# SENDSPIN_ID ist bewusst keine Add-on-Option: eine Instanz pro Maschine hat
# keine Kollision zu loesen. Vier haben sie, und common.sh liest die Variable
# ausschliesslich aus der Umgebung -- ein Schema-Eintrag wuerde nicht gelesen.
text = text.rstrip('\n') + f'''

# Ohne eigene Identitaet leiten alle Instanzen dieselbe aus der MAC der
# Netzwerkkarte ab, und ein Server legt Lautstaerke, Gruppenzugehoerigkeit und
# Pairing unter ihr ab -- die Einstellungen aller Zonen landen dann auf
# derjenigen, die sich zuletzt verbunden hat. Der Wert ist frei waehlbar und
# muss nur stabil und pro Instanz verschieden sein.
environment:
  SENDSPIN_ID: {slug}
'''
open(dest, 'w', encoding='utf-8').write(text)
PY

    # Das Original-Manifest traegt die Zeile "output: default" seit 0.1.10 nicht
    # mehr; faellt sie beim naechsten Upstream-Update anders aus, sollen die
    # Kopien nicht still ohne Ausgangswahl entstehen.
    grep -q "^  output: pulse:${sink}$" "${dir}/config.yaml" \
        || { echo "output-Option in ${slug} nicht gesetzt." >&2; exit 1; }
    grep -q '^  output: str?$' "${dir}/config.yaml" \
        || { echo "output-Schema in ${slug} nicht gesetzt." >&2; exit 1; }

    # Der Beschreibungstext der Option, damit die Konfigurationsseite kein
    # unbeschriftetes Feld zeigt.
    cat >> "${dir}/translations/en.yaml" <<YAML
    # Hinzugefuegt von zones/make-addons.sh
YAML
    python3 - "${dir}/translations/en.yaml" "${sink}" <<'PY'
import re
import sys

path, sink = sys.argv[1:3]
text = open(path, encoding='utf-8').read()
text = text.replace('    # Hinzugefuegt von zones/make-addons.sh\n', '')

entry = f'''  output:
    name: Audio output
    description: >-
      The PulseAudio sink this zone plays to, as `pulse:<sink>`. It is set to
      `pulse:{sink}` by zones/make-addons.sh and matched by an entry in
      /mnt/data/supervisor/audio/custom.pa; changing one without the other
      leaves this zone playing somewhere else. A sound-card name like `hw:1,0`
      cannot be opened from an app and stops it.
'''
# Vor log_level, damit die Reihenfolge der Felder der im Manifest entspricht.
text = re.sub(r'^  log_level:$', entry + '  log_level:', text, count=1, flags=re.M)
open(path, 'w', encoding='utf-8').write(text)
PY

    if [ -n "${server}" ]; then
        printf '%-22s -> %-12s output: pulse:%-18s server: %s\n' \
            "${slug}" "${label}" "${sink}" "${server}"
    else
        printf '%-22s -> %-12s output: pulse:%-18s mDNS\n' \
            "${slug}" "${label}" "${sink}"
    fi
done < "${conf}"
