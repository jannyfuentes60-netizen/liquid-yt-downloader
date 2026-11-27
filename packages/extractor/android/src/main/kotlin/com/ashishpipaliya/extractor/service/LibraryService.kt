package com.ashishpipaliya.extractor.service

import android.content.Context
import com.ashishpipaliya.extractor.generated.InitConfig
import com.ashishpipaliya.extractor.generated.InitResult
import com.ashishpipaliya.extractor.generated.VersionInfo
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.os.Handler
import android.os.Looper

/**
 * Service responsible for library initialization and version management
 * Follows Single Responsibility Principle
 *
 * LIQUID YT FORK (v1.0.9) — cambios vs extractor 1.0.0:
 *  1. La inicialización YA NO corre en el hilo principal. El plugin
 *     original la forzaba con mainHandler.post + Dispatchers.Main, y
 *     extraer ~50 MB (Python + FFmpeg) en el hilo principal mataba la
 *     app en teléfonos de gama baja (Galaxy A07): el watchdog de ANR
 *     la cerraba sin dejar ningún log. youtubedl-android NO exige el
 *     hilo principal para init (el propio plugin ya corre getInfo y
 *     las descargas en executors en segundo plano); el comentario
 *     "must be on main thread" del plugin original no es un requisito
 *     de la librería. Ahora el trabajo pesado corre en Dispatchers.IO.
 *  2. La respuesta (callback Pigeon) SÍ vuelve al hilo principal, como
 *     antes: solo se movió el trabajo, no el canal de respuesta.
 *  3. Se atrapa Throwable, no solo Exception: un Error (OOM,
 *     UnsatisfiedLinkError) durante la extracción antes escapaba del
 *     catch y mataba el proceso sin respuesta. Ahora devuelve
 *     success=false y la app sigue viva para reintentar o avisar.
 *  4. Init por componentes e idempotente: si yt-dlp ya quedó listo y
 *     solo falta FFmpeg, el reintento no vuelve a extraer Python.
 */
class LibraryService(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var initialized = false
    @Volatile
    private var youtubeDlInitialized = false
    @Volatile
    private var ffmpegInitialized = false
    @Volatile
    private var aria2cInitialized = false

    fun initialize(config: InitConfig, callback: (Result<InitResult>) -> Unit) {
        // Trabajo pesado en IO: extraer Python/FFmpeg ya no congela la UI.
        scope.launch {
            val result = try {
                // Initialize YoutubeDL (required) — solo la primera vez.
                if (!youtubeDlInitialized) {
                    YoutubeDL.getInstance().init(context)
                    youtubeDlInitialized = true
                }

                // Initialize FFmpeg if enabled — solo si aún no está.
                if (config.enableFFmpeg && !ffmpegInitialized) {
                    FFmpeg.getInstance().init(context)
                    ffmpegInitialized = true
                }

                // Initialize Aria2c if enabled — solo si aún no está.
                if (config.enableAria2c && !aria2cInitialized) {
                    Aria2c.getInstance().init(context)
                    aria2cInitialized = true
                }

                initialized = true

                Result.success(InitResult(success = true, errorMessage = null))
            } catch (t: Throwable) {
                // No se marca como inicializado: se puede reintentar.
                // Un fallo aquí ya no mata la app: es un success=false.
                initialized = false
                Result.success(
                    InitResult(
                        success = false,
                        errorMessage = t.message ?: "Unknown initialization error"
                    )
                )
            }
            // La respuesta Pigeon vuelve al hilo principal, como antes.
            mainHandler.post { callback(result) }
        }
    }

    fun getVersion(callback: (Result<VersionInfo>) -> Unit) {
        scope.launch {
            try {
                // Get actual yt-dlp version by executing --version command
                val youtubeDlVersion = withContext(Dispatchers.IO) {
                    try {
                        val request = com.yausername.youtubedl_android.YoutubeDLRequest(emptyList())
                        request.addOption("--version")
                        val response = YoutubeDL.getInstance().execute(request)
                        val version = response.out.trim()
                        "yt-dlp $version"
                    } catch (e: Exception) {
                        // Fallback to bundled version if command fails
                        "yt-dlp 2025.11.12 (bundled in library v0.18.1)"
                    }
                }
                
                val ffmpegVersion = "FFmpeg 6.0 (bundled)"
                val pythonVersion = "Python 3.8 (bundled)"

                callback(
                    Result.success(
                        VersionInfo(
                            youtubeDlVersion = youtubeDlVersion,
                            ffmpegVersion = ffmpegVersion,
                            pythonVersion = pythonVersion
                        )
                    )
                )
            } catch (e: Exception) {
                callback(Result.failure(e))
            }
        }
    }

    fun isInitialized(): Boolean = initialized
}
