# Beispiel-Archive

Lege hier die ZIP-Archive ab, mit denen du den Import testen willst. Der
Ordner ist absichtlich leer im Repository: `.gitignore` schließt `*.zip` aus,
weil ein Hörbuch schnell mehrere hundert Megabyte hat und damit über GitHubs
Dateigrenze liegt.

## Erwartetes Format

Ein Ordner pro Buch, darin die Kapitel als Audiodateien:

```
Harry Potter und die Kammer des Schreckens.zip
└── Harry Potter und die Kammer des Schreckens/
    ├── 1. Ansage.mp3
    ├── 2. Ein gräßlicher Geburtstag.mp3
    ├── 3. Dobbys Warnung.mp3
    …
    └── 19. Dobbys Belohnung.mp3
```

Enthält ein Archiv mehrere solcher Ordner, wird jeder davon als eigenes Buch
importiert. Liegen die Dateien direkt im Wurzelverzeichnis des Archivs, wird
der Dateiname des Archivs zum Buchtitel.

## Woher die Metadaten kommen

| Angabe | Quelle | Fallback |
| --- | --- | --- |
| Buchtitel | Ordnername im Archiv | Dateiname des Archivs |
| Autor | ID3 `TPE2`, sonst `TPE1` | „Unbekannt“ |
| Kapiteltitel | ID3 `TIT2` | Dateiname ohne führende Nummer |
| Reihenfolge | ID3 `TRCK`, wenn für alle Kapitel eindeutig | Dateiname, natürlich sortiert |
| Cover | Erstes eingebettetes `APIC` (Front Cover bevorzugt) | Platzhalter |
| Länge | AVFoundation beim Import | – |

Gelesen werden ID3v2.2, v2.3 und v2.4, inklusive Unsynchronisation und
UTF-16-Text. Unterstützte Endungen: `mp3`, `m4a`, `m4b`, `aac`, `wav`, `aif`,
`aiff`, `caf`, `mp4`, `flac`. `__MACOSX/` und Dateien mit führendem Punkt
werden übersprungen.

Im ZIP werden die Methoden *stored* (0) und *deflate* (8) unterstützt, dazu
ZIP64 für Archive über 4 GB. Jede Datei wird beim Entpacken gegen ihre CRC32
geprüft.

## Auf dem Gerät

Archive lassen sich auf drei Wegen importieren:

1. **Importieren → Archiv aus Dateien wählen** im Tab-Bar der App.
2. Im Teilen-Menü einer anderen App **„Auf Audioble sichern“** wählen.
3. Die Datei in der Dateien-App nach **Auf meinem iPhone › Audioble** legen;
   sie taucht dann direkt im Import-Dialog unter „Im Audioble-Ordner
   gefunden“ auf.
