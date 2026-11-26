package com.linejaque.liquidyt

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Recibe el texto compartido desde YouTube (ACTION_SEND, text/plain) y lo
 * pasa a Flutter por el MethodChannel "liquid_yt/share".
 *
 * - App cerrada: el texto queda en [pendingSharedText] y Dart lo pide con
 *   getSharedText() al arrancar.
 * - App abierta: onNewIntent() lo empuja por el canal ("sharedText").
 * launchMode singleTask (en el Manifest) evita una instancia nueva por share.
 */
class MainActivity : FlutterActivity() {
    private var pendingSharedText: String? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        pendingSharedText?.let {
            channel?.invokeMethod("sharedText", it)
            pendingSharedText = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "liquid_yt/share",
        )
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "getSharedText") {
                result.success(pendingSharedText)
                pendingSharedText = null
            } else {
                result.notImplemented()
            }
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("text/") == true
        ) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                pendingSharedText = text
            }
        }
    }
}
