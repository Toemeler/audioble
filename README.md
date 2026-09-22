# Audioble

Ein lokaler Hörbuch-Player für iOS. ZIP-Archiv importieren, hören, fertig –
ohne Konto, ohne Netzwerkzugriff, ohne Abhängigkeiten.

<img src="Audioble/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="Audioble">

## Was die App kann

**Bibliothek**
- ZIP-Import mit Fortschrittsanzeige, abbrechbar, streamend (auch 500 MB+)
- Kapiteltitel, Autor und Cover aus den ID3-Tags, Reihenfolge aus `TRCK`
- Suche, Filter (*Nicht begonnen*, *Weiterhören*), Sortierung, Raster/Liste
- Fortschrittsbalken und „noch X h Y min“ pro Buch
- Umbenennen, von vorn beginnen, als beendet markieren, löschen

**Player**
- Kapitelübersicht mit Sprung, Scrubber, ±30 s (einstellbar 10–60 s)
- Automatischer Übergang ins nächste Kapitel
- Hörposition wird gesichert – bei Pause, Kapitelwechsel, im Hintergrund und
  laufend während der Wiedergabe
- Geschwindigkeit 0,5×–3×, Schlummer-Timer (auch „Ende des Kapitels“)
- Clips als Lesezeichen, Auto-Modus mit großen Tasten
- Sperrbildschirm, Control Center, AirPlay, Kopfhörer-Tasten
- Pausiert bei Anruf und beim Abziehen der Kopfhörer, setzt danach fort

## Format der Archive

Ein Ordner pro Buch, darin die Kapitel:

```
Buchtitel.zip
└── Buchtitel/
    ├── 1. Erstes Kapitel.mp3
    ├── 2. Zweites Kapitel.mp3
    …
```

Details, Fallbacks und die unterstützten Formate stehen in
[`Sample/README.md`](Sample/README.md). Dort ist auch der Ordner, in den du
Test-Archive legen kannst.

## Installieren

Jeder Build landet als unsigniertes IPA in einem
[GitHub Release](../../releases). Zwei Wege:

- **SideStore / AltStore:** die Quelle hinzufügen – dann meldet der Sideloader
  neue Builds von selbst:

  ```
  https://toemeler.github.io/audioble/s.json
  ```

  Auf [toemeler.github.io/audioble](https://toemeler.github.io/audioble/) gibt
  es dafür einen Ein-Tipp-Button. Die Seite wird vom Workflow mitgebaut und
  über GitHub Pages veröffentlicht; ohne Pages funktioniert stattdessen
  `https://raw.githubusercontent.com/Toemeler/audioble/main/s.json`.
- **Direkt:** `Audioble.ipa` laden und mit SideStore, AltStore oder
  Sideloadly installieren.

## Bauen

```sh
.github/scripts/build_app.sh Release iphoneos
.github/scripts/package_ipa.sh build/Release-iphoneos/Audioble.app Audioble.ipa
```

Oder in Xcode: `Audioble.xcodeproj` öffnen, Target `Audioble`.

Der Workflow [`Build`](.github/workflows/build.yml) baut bei jedem Push auf
`main` und veröffentlicht `build-N`; ein `v*`-Tag veröffentlicht unter diesem
Tag. Ein Push, der die App nicht verändert, wird über `.build-stamp`
übersprungen.

### Deployment-Target

Die App ist auf **iOS 26.0** gesetzt (`IPHONEOS_DEPLOYMENT_TARGET` in
`Audioble.xcodeproj/project.pbxproj`). Das ist die *Mindest*version – auf
iOS 27 läuft sie unverändert. Höher geht erst, wenn die GitHub-Runner ein
Xcode mit dem passenden SDK mitbringen; der Workflow prüft das und bricht mit
einer klaren Meldung ab, statt tief im Build zu scheitern.

## Aufbau

| Datei | Rolle |
| --- | --- |
| `ZipReader.swift` | Streamender ZIP-Leser, stored + deflate, ZIP64, CRC32 |
| `ID3.swift` | ID3v2.2/2.3/2.4: Titel, Track, Autor, Cover |
| `Importer.swift` | Archiv → Bücher: entpacken, Tags lesen, Längen messen |
| `LibraryStore.swift` | Bibliothek und Hörpositionen, atomar auf Platte |
| `PlayerEngine.swift` | AVPlayer, Autoplay, Timer, Fernbedienung |
| `LibraryView.swift` / `PlayerView.swift` | Die beiden Bildschirme |

Keine Pakete, keine Pods – nur SwiftUI, AVFoundation, MediaPlayer und
Compression.
