docker exec -i hassio_audio tee /data/custom.pa > /dev/null <<'PACFG'
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
# Master-Sink: alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71
# ==============================================================================

# Wohnzimmer -- front-left,front-right des Master-Sinks, also ein Ausgangspaar der Karte.
load-module module-remap-sink sink_name=zone_wohnzimmer sink_properties=device.description="Wohnzimmer" master=alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 master_channel_map=front-left,front-right channels=2 channel_map=front-left,front-right remix=no

# Küche -- rear-left,rear-right des Master-Sinks, also ein Ausgangspaar der Karte.
load-module module-remap-sink sink_name=zone_kueche sink_properties=device.description="Küche" master=alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 master_channel_map=rear-left,rear-right channels=2 channel_map=front-left,front-right remix=no

# Bad -- front-center,lfe des Master-Sinks, also ein Ausgangspaar der Karte.
load-module module-remap-sink sink_name=zone_bad sink_properties=device.description="Bad" master=alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 master_channel_map=front-center,lfe channels=2 channel_map=front-left,front-right remix=no

# Büro -- side-left,side-right des Master-Sinks, also ein Ausgangspaar der Karte.
load-module module-remap-sink sink_name=zone_buero sink_properties=device.description="Büro" master=alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 master_channel_map=side-left,side-right channels=2 channel_map=front-left,front-right remix=no

# Alle Zonen -- alle 8 Kanaele zugleich.
load-module module-remap-sink sink_name=zone_alle_zonen sink_properties=device.description="Alle Zonen" master=alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 master_channel_map=front-left,front-right,rear-left,rear-right,front-center,lfe,side-left,side-right channels=8 channel_map=front-left,front-right,rear-left,rear-right,front-center,lfe,side-left,side-right remix=no

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
set-sink-volume alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 65536

# Einmal aus- und wieder einschalten, nachdem die Zonen angelegt sind. Das setzt
# den Zustand des ALSA-Treibers zurueck, der die Kanaele jetzt anders zugeteilt
# bekommt als beim Start des Geraets.
suspend-sink alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 1
suspend-sink alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71 0

# module-switch-on-connect ist ebenfalls geladen: es macht jeden neu
# auftauchenden Sink zum Default. Die Zonen oben tauchen bei jedem Start auf, und
# die letzte von ihnen wuerde damit zum Default-Sink der ganzen Maschine -- also
# dorthin, wo HAs eigene Ansagen und jedes Add-on ohne eigene Auswahl landen.
# Die Zeile setzt den Default zurueck auf die Karte als Ganzes. Wer stattdessen
# eine bestimmte Zone als Default will, traegt sie hier ein.
set-default-sink alsa_output.usb-ESI_Audiotechnik_GmbH_GIGAPORT_eX_GIGAeX-5610-A287-330112025-4648-01.analog-surround-71

PACFG
ha audio restart
sleep 5
echo '--- Zonen-Sinks ---'; ha audio info | grep -E 'name: zone_' || echo 'KEINE ZONEN - siehe ha audio logs'
