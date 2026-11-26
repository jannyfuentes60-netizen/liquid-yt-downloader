# Liquid YT — Descargador de YouTube para Android

**Liquid YT** es una app Android en Flutter con estilo **iOS 27 Liquid Glass** que descarga videos de YouTube **en tu propio teléfono**, sin servidor de por medio. Por eso ya no te sale el error de IP de YouTube: la descarga sale desde tu conexión, no desde una IP de servidor marcada como bot.

## Qué hace

- **Búsqueda por texto:** escribes la rola y salen 10 resultados reales con miniatura, título, canal y duración.
- **Pegar link:** pegas el link de YouTube y lo resuelve (título, canal, duración y formatos reales del video).
- **Selector de formato:** MP3, M4A, MP4 720p, MP4 480p y MP4 360p, más los formatos reales que reporta yt-dlp para ese video.
- **Compartir desde YouTube:** en la app de YouTube le das Compartir y sale **Liquid YT** en el menú. Se abre un menú flotante con la miniatura, el título, el selector de calidad y formato, y el botón **Descargar**.
- **Descargas:** progreso en vivo, ETA, cancelar, historial con abrir/reproducir y borrar. Los archivos quedan en `Descargas/LiquidYT` del teléfono.
- **Estilo iOS 27 Liquid Glass:** barras y tarjetas de cristal, fondo con degradado oscuro.

## Instalar (sin PC)

1. Ve a **Releases** de este repo en tu celular.
2. Descarga `app-arm64-v8a-release.apk` (es el de tu Galaxy A07 y de casi todos los Android actuales).
3. Ábrelo e instala. Si te pregunta, permite "instalar apps desconocidas" solo para esa descarga.

## Cómo se usa

1. Abre la app la primera vez y espera a que diga **"Motor listo"** (yt-dlp se prepara unos segundos).
2. Busca una rola o pega un link, elige el formato y dale **Descargar**.
3. O desde YouTube: **Compartir → Liquid YT** → elige formato → **Descargar**.

## Cómo funciona por dentro (honesto)

- **yt-dlp y FFmpeg no son apps instaladas en el sistema:** van **incluidos dentro del APK** por el plugin `extractor` (youtubedl-android: Python 3.8 + FFmpeg). Por eso el APK pesa bastante (~60–90 MB por ABI): es el precio de llevar el motor dentro.
- La descarga corre en tu teléfono con tu IP, así que el bloqueo anti-bot de servidor ya no aplica. Aun así, **YouTube puede pedir verificación o bloquear algunos videos también en el teléfono** (videos con restricción de edad, privados o con login obligatorio). En ese caso la app te muestra el error real.
- La búsqueda usa `youtube_explode_dart` (solo metadatos, sin API key). Si YouTube cambia su página, la búsqueda puede fallar y te tocará pegar el link directo; la descarga con yt-dlp sigue funcionando porque yt-dlp se actualiza solo al iniciar.

## Tecnologías

- Flutter 3.47.9 (stable) · Dart 3.13
- `liquid_glass_widgets` 1.21.0 — Liquid Glass iOS 27 (`GlassStyle.ios27`)
- `extractor` 1.0.0 — yt-dlp + FFmpeg en el dispositivo (`YoutubeDLFlutter`, `getVideoInfo`, `DownloadRequest`, progreso y cancelación)
- `youtube_explode_dart` 2.5.3 — búsqueda por texto
- Compartir: intent-filter `ACTION_SEND` (`text/plain`) en el `AndroidManifest` + `MainActivity` en Kotlin con un `MethodChannel` (`liquid_yt/share`) que pasa el texto compartido a Flutter. Se usó canal nativo en vez del plugin `receive_sharing_intent` porque su API cambió entre versiones (en la 1.9.0 el texto llega en `SharedMediaFile.path`, sin getter `.text`) y el canal nativo es determinista y se verifica con la compilación.
- `path_provider`, `permission_handler`, `shared_preferences`, `open_file`
- minSdk 24 · applicationId `com.linejaque.liquidyt`

## Compilar en local

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

El APK arm64 queda en `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

## Compilación automática

Cada push a `main` corre `.github/workflows/build-apk.yml`: instala Flutter 3.47.9, regenera el scaffold de Android con esa versión (para que `gradlew` y el wrapper siempre coincidan), compila el APK por ABI, lo sube como artefacto y crea un Release con el APK arm64.
