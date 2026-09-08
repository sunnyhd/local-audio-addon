# Stereo-Zonen aus einem mehrkanaligen USB-Interface

Ein USB-Audio-Interface mit mehreren Ausgängen wird hier zu mehreren
unabhängigen Music-Assistant-Playern: je zwei Kanäle eine Stereo-Zone, jede
Zone ein eigener Player mit eigener Lautstärke, eigener Warteschlange und
eigener Gruppenzugehörigkeit. Bei acht Ausgängen sind das vier Zonen.

Das ist nicht an ein bestimmtes Gerät gebunden. Die Skripte nehmen den Namen
des Ausgangs und seine Kanalzahl als Argumente; getestet wurde die Aufteilung
gegen eine ESI GIGAPort eX (8 analoge Ausgänge), aber jedes Interface, das
PulseAudio mit einem Mehrkanal-Profil erkennt, geht denselben Weg.

## Warum es diesen Umweg braucht

Das Add-on spielt über die PulseAudio, die der Supervisor mit `audio: true`
hereinreicht — es kann keine Soundkarte direkt öffnen. Die Aufteilung muss
deshalb in dieser PulseAudio passieren, nicht im Player. Und ein Add-on läuft
einmal pro Slug, also braucht jede Zone eine eigene Kopie des Manifests.

Beides zusammen ergibt zwei Hälften, die zueinander passen müssen:

- `custom.pa` schneidet den 8-Kanal-Ausgang in vier Stereo-Sinks.
- Je eine Add-on-Kopie zeigt mit `output: pulse:<sink>` auf einen davon.

Beide Hälften werden aus derselben `zones.conf` erzeugt, damit die Namen nicht
auseinanderlaufen.

Am Player-Image ändert sich dabei nichts. Die Kopien tragen `image:` aus dem
Original, ziehen also dasselbe veröffentlichte Image; geändert wird nur das
Manifest. Ein Upstream-Update ist damit ein neuer Versionsstring, kein Merge.

## Schritt 1 — Interface anschließen und das Mehrkanal-Profil setzen

Auf der Home-Assistant-Konsole (SSH-Add-on oder direkt am Gerät):

```sh
ha audio info
```

Interessant sind zwei Dinge: der Name der Karte unter `cards`, und welche
Profile sie anbietet. Ein Interface, das auf `analog-stereo` steht, hat für
PulseAudio zwei Kanäle — dann gibt es nichts aufzuteilen. Also auf das breiteste
Profil setzen, das die Karte anbietet:

```sh
ha audio profile --card <kartenname> --name output:analog-surround-71
ha audio restart
```

`module-card-restore` ist in HAs PulseAudio geladen, das Profil überlebt also den
Neustart. Danach noch einmal `ha audio info`: unter `outputs` steht jetzt der
mehrkanalige Sink. Sein Name ist das, was gleich als *Master* gebraucht wird, und
sieht ungefähr so aus:

```
alsa_output.usb-<Hersteller>_<Modell>-00.analog-surround-71
```

## Schritt 2 — Zonen festlegen

```sh
./make-zones.sh 8 Wohnzimmer Küche Bad Büro > zones.conf
```

Die Zahl ist die Kanalzahl des Ausgangs, die Namen sind frei. Weniger Namen als
Zonen ist in Ordnung, der Rest heißt dann "Zone 3", "Zone 4". Die erzeugte
Datei ordnet Zone *n* den Ausgängen *2n-1* und *2n* zu — Zone 1 also den
Buchsen 1 und 2. Wer eine andere Zuordnung will, bearbeitet die Datei; sie ist
absichtlich vier Spalten Text und kein generiertes Artefakt, das man nicht
anfassen darf.

## Schritt 3 — PulseAudio aufteilen

```sh
./make-custom-pa.sh <master-sink-name> > custom.pa
```

Die Datei gehört auf der HA-Maschine nach:

```
/mnt/data/supervisor/audio/custom.pa
```

HAs PulseAudio zieht sie am Ende ihrer `system.pa` mit `.include /data/custom.pa`
ein — ein vorgesehener Erweiterungspunkt, und `/data` überlebt Updates des
Audio-Plugins. Das `.nofail` davor heißt allerdings auch: eine kaputte Zeile
hält das Audio nicht an, sie fällt nur still aus. Nach dem Kopieren deshalb:

```sh
ha audio restart
ha audio logs | tail -40     # laden die vier Module?
ha audio info                # stehen die vier Sinks unter outputs?
```

Erscheinen die Zonen nicht, steht der Grund in `ha audio logs` — meist ein
Master-Sink-Name, der sich mit dem Profil geändert hat.

## Schritt 4 — Add-on-Instanzen erzeugen

```sh
./make-addons.sh /addons zones.conf 192.168.1.10:8927
```

`/addons` ist der Ordner, den der lokale Add-on-Store liest; per Samba- oder
SSH-Add-on erreichbar. Das dritte Argument ist die Adresse des
Music-Assistant-Servers, und auf einer Maschine mit mehreren Zonen ist es
keine Kür: alle Instanzen laufen mit `host_network: true` im selben
Netzwerk-Namespace, und jede startet ihren eigenen `avahi-daemon`, solange sie
sich über mDNS anbieten soll. Vier Responder streiten sich dann um Port 5353.
Eine gesetzte Server-Adresse unterdrückt das Advertisement — der Player wählt
sich stattdessen beim Server ein — und der gebündelte avahi bleibt in jeder
Instanz unten.

Danach in Home Assistant unter **Einstellungen → Add-ons → Add-on-Store** das
Drei-Punkte-Menü → **Neu laden**. Die Instanzen erscheinen unter *Local
add-ons*, einzeln installieren und starten.

## Schritt 5 — Kontrolle

Im Log jeder Instanz steht beim Start, wohin sie spielt und ob dort etwas zu
hören wäre — das Add-on meldet einen stummgeschalteten oder auf null gedrehten
Sink von sich aus. In Music Assistant tauchen die Zonen als eigene Sendspin-
Player auf, unter den Namen aus `zones.conf`.

Zum Prüfen, welche Buchse welche Zone ist, eignet sich eine Zone auf einmal:
in Music Assistant etwas darauf abspielen und hören, wo es herauskommt. Eine
Zone, die auf der falschen Buchse landet, ist eine Zeile in `zones.conf` —
Spalte 4 tauschen, Schritt 3 und 4 wiederholen.

## Was dabei zu beachten ist

**Der Default-Sink.** `module-switch-on-connect` ist in HAs `system.pa` geladen
und macht jeden neu auftauchenden Sink zum Default. Ohne Gegenmaßnahme würde die
zuletzt geladene Zone zum Standardausgang der ganzen Maschine — dorthin gehen
dann HAs eigene Ansagen und jedes Add-on ohne eigene Auswahl. Die erzeugte
`custom.pa` setzt den Default am Ende zurück auf den Master. Wer das lieber
außerhalb regelt, streicht die Zeile und nimmt `ha audio default output --name <sink>`.

**Die Identität.** Jede Kopie bekommt eine eigene `SENDSPIN_ID` mitgegeben. Ohne
sie leiten alle Instanzen dieselbe aus der MAC der Netzwerkkarte ab, und ein
Music-Assistant-Server legt Lautstärke, Gruppen und Pairing unter dieser ID ab —
die Einstellungen aller Zonen landen dann auf der, die sich zuletzt verbunden
hat.

**Der Ausgangswert.** `output` war bis Version 0.1.10 eine Option des Add-ons
und wurde entfernt, weil auf einer Maschine mit einem Player das Audio-Panel die
ganze Antwort ist. Hier ist es das nicht: vier Instanzen brauchen vier Ziele, und
das Panel vergibt eines pro Add-on. Der Schlüssel wird deshalb ins Manifest
zurückgeholt — `common.sh` im Image liest ihn unverändert weiter, es ändert sich
also nichts am Player. Der Wert ist `pulse:<sink>` und damit der native
PulseAudio-Ausgang. Ein `hw:`-Wert ist weiterhin das, was ein Add-on nicht kann:
ohne rohen Zugriff auf `/dev/snd` öffnet er nicht und hält die Instanz an.

**Latenz.** `module-remap-sink` liegt zwischen Player und Karte. Bricht der Ton
auf einer schwachen Maschine auf, hilft die Option **Audio buffer** (`buffer_ms`)
in der Instanz, auf Kosten einer längeren Wartezeit beim Titelwechsel.

**Nicht getestet.** Die Skripte und das erzeugte YAML sind hier geprüft, gegen
echte Hardware und einen laufenden Supervisor ist nichts davon gelaufen. Die
wahrscheinlichsten Stolperstellen sind der Profilname in Schritt 1 (je nach
Interface heißt er anders) und die Kanalreihenfolge in Schritt 2.
