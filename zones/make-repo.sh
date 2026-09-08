#!/usr/bin/env bash
# Erzeugt ein Home-Assistant-Add-on-Repository mit N Zonen-Instanzen.
#
# Aufruf:  ./make-repo.sh <zielverzeichnis> [anzahl|zones.conf] [repo-url]
#
#   ./make-repo.sh ~/dev/ha-addons 4 https://github.com/sunnyhd/ha-addons
#   ./make-repo.sh ~/dev/ha-addons zones.conf https://github.com/sunnyhd/ha-addons
#
# Mit einer zones.conf statt einer Zahl entstehen genau so viele Instanzen, wie
# die Datei Zonen kennt, und das Feld "Audio output" wird zur Auswahlliste aus
# ihren Sinks statt zu einem Textfeld -- man klickt das Ausgangspaar an, statt
# `pulse:zone_kueche` fehlerfrei abtippen zu muessen. Die Liste ist damit an
# dieselbe Datei gebunden wie die custom.pa, also koennen die beiden Seiten
# nicht auseinanderlaufen.
#
# Der Unterschied zu make-addons.sh: dort werden Zonen fest ins Manifest
# geschrieben, weil die Kopien fuer genau eine Maschine erzeugt werden. Hier
# nicht. Ein Repository wird einmal angelegt und dann ueber seine URL im
# Add-on-Store eingebunden, also bleiben die zonenspezifischen Werte leer und
# werden in der Oberflaeche gesetzt -- Sink, Anzeigename und Server sind
# Optionen, keine Generierungsparameter. Was pro Instanz verschieden sein *muss*
# und in der Oberflaeche nicht zu setzen ist, steht weiterhin im Manifest: der
# Slug, der AppArmor-Profilname und SENDSPIN_ID.
#
# Der Add-on-Store ist dabei der richtige Store: HACS fuehrt Integrationen,
# Lovelace-Karten und Themes, keine Add-ons.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_addon="${here}/../local_audio"

if [ "$#" -lt 1 ]; then
    echo "Aufruf: $0 <zielverzeichnis> [anzahl] [repo-url]" >&2
    exit 1
fi

target=$1
count=${2:-4}
repo_url=${3:-}

[ -d "${source_addon}" ] || { echo "Kein local_audio/ neben zones/ gefunden." >&2; exit 1; }

# Zweites Argument: eine Zahl, oder eine zones.conf, aus der Zahl und Auswahl-
# liste kommen.
outputs=''
labels=''
if [ -f "${count}" ]; then
    conf=${count}
    count=0
    while IFS='|' read -r suffix label sink chanmap || [ -n "${suffix}" ]; do
        case ${suffix} in '' | '#'*) continue ;; esac
        [ -n "${sink}" ] || continue
        count=$((count + 1))
        outputs="${outputs}|pulse:${sink}"
        labels="${labels}${labels:+, }${label}"
    done < "${conf}"
    if [ "${count}" -eq 0 ]; then
        echo "In ${conf} steht keine Zone." >&2
        exit 1
    fi
    echo "Aus ${conf}: ${count} Zonen (${labels})" >&2
fi

case ${count} in
    *[!0-9]* | '') echo "Anzahl \"${count}\" ist weder eine Zahl noch eine lesbare zones.conf." >&2; exit 1 ;;
esac
if [ "${count}" -lt 1 ] || [ "${count}" -gt 16 ]; then
    echo "Anzahl ${count}: erwartet wird 1 bis 16." >&2
    exit 1
fi

base_version=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' \
    "${source_addon}/config.yaml" | head -n 1)
[ -n "${base_version}" ] || { echo "version: nicht aus dem Manifest lesbar." >&2; exit 1; }

mkdir -p "${target}"

# ------------------------------------------------------------------------------
# repository.yaml -- daran erkennt der Supervisor ein Add-on-Repository. Ohne
# diese Datei nimmt er das Verzeichnis nicht an.
# ------------------------------------------------------------------------------
cat > "${target}/repository.yaml" <<EOF
name: sys.tec Home Assistant Add-ons
maintainer: Klaus Breidinger <k.breidinger@sys-tec.info>
EOF
if [ -n "${repo_url}" ]; then
    printf 'url: %s\n' "${repo_url}" >> "${target}/repository.yaml"
fi

# ------------------------------------------------------------------------------
# Die Zonen-Instanzen
# ------------------------------------------------------------------------------
for ((i = 1; i <= count; i++)); do
    number=${i}
    slug="local_audio_zone${number}"
    dir="${target}/${slug}"

    # Mit einer zones.conf traegt Instanz n den Namen und den Sink der n-ten
    # Zone schon ab Werk. Ohne sie bleiben beide leer und werden in der
    # Oberflaeche gesetzt.
    zone_label=''
    zone_sink=''
    if [ -n "${conf:-}" ]; then
        line=$(grep -vE '^[[:space:]]*(#|$)' "${conf}" | sed -n "${number}p")
        zone_label=$(printf '%s' "${line}" | cut -d'|' -f2)
        zone_sink=$(printf '%s' "${line}" | cut -d'|' -f3)
    fi

    mkdir -p "${dir}"
    cp "${source_addon}/apparmor.txt" "${dir}/"
    cp -R "${source_addon}/translations" "${dir}/"

    # Der Profilname ist das Einzige im Profil, das den Slug traegt; der Rest
    # ist Pfad- und Capability-Politik und gilt unveraendert.
    sed -i.bak "s/^profile local_audio /profile ${slug} /" "${dir}/apparmor.txt"
    rm -f "${dir}/apparmor.txt.bak"
    grep -q "^profile ${slug} " "${dir}/apparmor.txt" \
        || { echo "AppArmor-Profil in ${slug} nicht umbenannt." >&2; exit 1; }

    python3 - "${source_addon}/config.yaml" "${dir}/config.yaml" "${slug}" "${number}" \
        "${outputs}" "${zone_label}" "${zone_sink}" <<'PY'
import re
import sys

source, dest, slug, number, outputs, zone_label, zone_sink = sys.argv[1:8]
text = open(source, encoding='utf-8').read()

title = f'Local Audio Zone {number}'
if zone_label:
    title = f'Local Audio – {zone_label}'
text = re.sub(r'^name: .*$', f'name: {title}', text, count=1, flags=re.M)
text = re.sub(r'^slug: .*$', f'slug: {slug}', text, count=1, flags=re.M)
text = re.sub(r'^description: >-\n(?:  .*\n)+',
              'description: >-\n'
              f'  Sendspin player for Music Assistant, zone {number}. Plays to one\n'
              '  PulseAudio sink, so several of these split a multi-channel interface\n'
              '  into independent stereo zones.\n',
              text, count=1, flags=re.M)

# `output` war bis 0.1.10 eine Option und wurde entfernt, weil auf einer
# Ein-Player-Maschine das Audio-Panel die ganze Antwort ist. Bei mehreren
# Instanzen ist es das nicht: jede braucht ihr eigenes Ziel, und das Panel
# vergibt eines pro Add-on. common.sh liest den Schluessel unveraendert weiter
# aus der Supervisor-Config, also genuegt es, ihn ins Manifest zurueckzuholen --
# am Image aendert sich nichts.
#
# Leer statt vorbelegt: welcher Sink zu dieser Zone gehoert, weiss erst die
# Maschine, auf der sie laeuft. Leer faellt der Player auf `default` zurueck und
# spielt ueber das Audio-Panel -- ein brauchbarer Anfangszustand, der beim ersten
# Start hoerbar macht, dass die Instanz laeuft.
default_output = f'pulse:{zone_sink}' if zone_sink else ('default' if outputs else '""')
text = re.sub(r'^  log_level: info$', f'  output: {default_output}\n  log_level: info',
              text, count=1, flags=re.M)
if zone_label:
    text = re.sub(r'^  name: ""$', f'  name: "{zone_label}"', text, count=1, flags=re.M)

# Der eine Punkt, an dem eine Instanz nicht sein darf wie das Original.
#
# Der Player lauscht auf Port 8928, und das ist im Image nicht einstellbar: das
# run-Skript rendert seine Konfiguration aus einer festen Schluesselliste, in
# der `port` nicht vorkommt -- obwohl sendspin-cli selbst ein --port kennt und
# in seiner Hilfe ausdruecklich zwei Player auf einem Host damit vorsieht.
#
# Im Netzwerk-Namespace des Hosts kann diesen Port nur eine Instanz bekommen.
# Die uebrigen scheitern beim Binden, und ein Player, der mit Fehler endet,
# stoppt seinen Container. Fuenf installierte Zonen waeren also ein laufender
# Player und vier gestoppte Container.
#
# Ein eigener Namespace je Instanz loest das, weil dann jede ihren eigenen
# Port 8928 hat. Der Preis ist mDNS: ohne Host-Netz kann sich der Player nicht
# anbieten und der Server nicht zurueckverbinden. Deshalb ist `server` hier
# nicht mehr die Empfehlung, die es bei host_network war, sondern
# Voraussetzung -- der Player waehlt sich ein, und ueber diese Verbindung
# laeuft danach alles.
text = re.sub(r'^# The mDNS advertisement.*\n# on, both need.*\nhost_network: true$',
              '# Eigener Netzwerk-Namespace je Instanz: der Player lauscht auf dem festen\n'
              '# Port 8928, den im Netz des Hosts nur eine Instanz bekommen koennte. Ohne\n'
              '# Host-Netz gibt es kein mDNS, also muss `server` gesetzt sein -- der Player\n'
              '# waehlt sich dort ein, statt gefunden zu werden.\n'
              'host_network: false',
              text, count=1, flags=re.M)
if 'host_network: false' not in text:
    sys.exit('host_network konnte nicht umgestellt werden.')
# Mit bekannten Zonen wird das Feld eine Auswahlliste, sonst bleibt es frei.
# `default` steht als erster Eintrag darin und ist der Wert, mit dem der Player
# dem Audio-Panel folgt -- eine Instanz, die noch keine Zone hat, spielt damit
# hoerbar statt ins Leere.
if outputs:
    schema_line = '  output: list(default' + outputs + ')?\n'
else:
    schema_line = '  output: str?\n'
text = re.sub(r'^  log_level: list\(', schema_line + '  log_level: list(',
              text, count=1, flags=re.M)

# SENDSPIN_ID ist bewusst keine Add-on-Option: eine Instanz pro Maschine hat
# keine Kollision zu loesen. Mehrere haben sie, und common.sh liest die Variable
# ausschliesslich aus der Umgebung -- ein Schema-Eintrag wuerde nicht gelesen.
text = text.rstrip('\n') + f'''

# Ohne eigene Identitaet leiten alle Instanzen dieselbe aus der MAC der
# Netzwerkkarte ab, und ein Server legt Lautstaerke, Gruppenzugehoerigkeit und
# Pairing unter ihr ab -- die Einstellungen aller Zonen landen dann auf
# derjenigen, die sich zuletzt verbunden hat. Der Wert muss nur stabil und pro
# Instanz verschieden sein, und der Slug ist beides.
environment:
  SENDSPIN_ID: {slug}
'''
open(dest, 'w', encoding='utf-8').write(text)
PY

    # Die Vorbelegung ist `default`, wo es eine Auswahlliste gibt, und sonst leer.
    grep -qE '^  output: (""|default|pulse:[a-z0-9_]+)$' "${dir}/config.yaml" \
        || { echo "output-Option in ${slug} fehlt." >&2; exit 1; }
    grep -qE '^  output: (str\?|list\(default\|.*\)\?)$' "${dir}/config.yaml" \
        || { echo "output-Schema in ${slug} fehlt." >&2; exit 1; }

    python3 - "${dir}/translations/en.yaml" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding='utf-8').read()

entry = '''  output:
    name: Audio output
    description: >-
      Which PulseAudio sink this zone plays to, as `pulse:<sink>` — for example
      `pulse:zone_kitchen`. Leave it empty and the player follows this app's
      Audio panel instead. The zone sinks themselves are created in
      /mnt/data/supervisor/audio/custom.pa; see the repository README. A
      sound-card name like `hw:1,0` cannot be opened from an app and stops it.
'''
text = re.sub(r'^  log_level:$', entry + '  log_level:', text, count=1, flags=re.M)
open(path, 'w', encoding='utf-8').write(text)
PY

    # Ein knappes README je Add-on: das ist die Seite, die der Store neben der
    # Konfiguration zeigt.
    cat > "${dir}/README.md" <<EOF
# Local Audio Zone ${number}

One Sendspin player for Music Assistant, playing to one PulseAudio sink.

Several of these split a multi-channel audio interface into independent stereo
zones — one player per pair of outputs, each with its own volume, queue and
group membership.

## Setting it up

1. Create the zone sinks once, in \`/mnt/data/supervisor/audio/custom.pa\`.
   The repository README has the recipe and the scripts that generate it.
2. Set **Audio output** here to \`pulse:<sink>\` — the sink this zone owns.
3. Set **Player name** to what the zone should be called in Music Assistant.
4. Set **Music Assistant server** to \`<host>:8927\`. This one is required, not
   optional: each instance runs in its own network namespace so that they do not
   all fight over the player's fixed port 8928, and without the host's network
   there is no mDNS to be discovered on. The player dials out to the server
   instead, and everything runs over that connection.

Without a server address the player waits to be found, and nothing will find it.

This app runs the image published by
[music-assistant/local-audio-addon](https://github.com/music-assistant/local-audio-addon);
only the manifest differs.
EOF

    printf '%-22s Local Audio Zone %s\n' "${slug}" "${number}"
done
