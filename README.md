# Kopek iOS

L'application iOS de Kopek et son SDK **KopekKit** (Swift package local).

## Prérequis

- Xcode 27 (Swift 6, mode de langage Swift 6)
- Un simulateur iOS : `xcrun simctl list devices available` pour voir leurs noms

## Compiler et tester

```bash
# Compile l'appli et lance tous les tests du scheme (appli + KopekKit)
xcodebuild -project kopek_ios.xcodeproj -scheme kopek_ios \
  -destination 'platform=iOS Simulator,name=iPhone 17' build test

# Tests du SDK seul, sans simulateur
swift test --package-path KopekKit
```

Remplace `iPhone 17` par un simulateur de la liste.

## Structure

| Dossier | Rôle |
|---|---|
| `kopek_ios/` | L'application SwiftUI (`com.lteixeira.kopek`) |
| `KopekKit/` | Le SDK KopekKit, Swift package local (`Package.swift`, `Sources/`, `Tests/`) |
| `kopek_iosTests/`, `kopek_iosUITests/` | Tests de l'appli |
| `docs/API.md` | L'API publique de KopekKit, commune avec Android |
| `kopek_ios.xcodeproj/` | Le projet Xcode (le scheme `kopek_ios` est partagé) |

L'appli dépend de KopekKit, jamais l'inverse.

## Version

KopekKit suit la version de Kopek web : **0.1.0**.
