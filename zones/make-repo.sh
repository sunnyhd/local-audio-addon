#!/usr/bin/env bash
# Erzeugt ein Home-Assistant-Add-on-Repository mit N Zonen-Instanzen.
#
# Aufruf:  ./make-repo.sh <zielverzeichnis> [anzahl] [repo-url]
#
#   ./make-repo.sh ~/dev/ha-addons 4 https://github.com/sunnyhd/ha-addons
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

case ${count} in
    *[!0-9]* | '') echo "Anzahl \"${count}\" ist keine Zahl." >&2; exit 1 ;;
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

    mkdir -p "${dir}"
    cp "${source_addon}/apparmor.txt" "${dir}/"
    cp -R "${source_addon}/translations" "${dir}/"

    # Der Profilname ist das Einzige im Profil, das den Slug traegt; der Rest
    # ist Pfad- und Capability-Politik und gilt unveraendert.
    sed -i.bak "s/^profile local_audio /profile ${slug} /" "${dir}/apparmor.txt"
    rm -f "${dir}/apparmor.txt.bak"
    grep -q "^profile ${slug} " "${dir}/apparmor.txt" \
        || { echo "AppArmor-Profil in ${slug} nicht umbenannt." >&2; exit 1; }

    python3 - "${source_addon}/config.yaml" "${dir}/config.yaml" "${slug}" "${number}" <<'PY'
import re
import sys

source, dest, slug, number = sys.argv[1:5]
text = open(source, encoding='utf-8').read()

text = re.sub(r'^name: .*$', f'name: Local Audio Zone {number}', text, count=1, flags=re.M)
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
text = re.sub(r'^  log_level: info$', '  output: ""\n  log_level: info',
              text, count=1, flags=re.M)
text = re.sub(r'^  log_level: list\(', '  output: str?\n  log_level: list(',
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

    grep -q '^  output: ""$' "${dir}/config.yaml" \
        || { echo "output-Option in ${slug} fehlt." >&2; exit 1; }
    grep -q '^  output: str?$' "${dir}/config.yaml" \
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
      Audio panel instead, which is the right setting when only one instance is
      running. The zone sinks themselves are created in
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
4. With more than one instance on this machine, set **Music Assistant server**
   as well. Every instance shares the host's network namespace, and each one
   that advertises over mDNS starts its own avahi-daemon — they would fight over
   port 5353. A server address suppresses the advertisement.

Left unconfigured this plays through the Audio panel like a single instance
would, which is a good way to check it starts at all.

This app runs the image published by
[music-assistant/local-audio-addon](https://github.com/music-assistant/local-audio-addon);
only the manifest differs.
EOF

    printf '%-22s Local Audio Zone %s\n' "${slug}" "${number}"
done
