package com.example.veraxi_app

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "veraxi/termux_bridge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "runCommand" -> {
                        val command = call.argument<String>("command") ?: ""
                        runTermuxCommand(command, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Sends [command] to Termux via the `RUN_COMMAND` intent (requires
     * Termux:API plugin). The output is returned asynchronously, but since
     * the intent is fire-and-forget on most Termux versions, we acknowledge
     * success once the intent is dispatched.
     */
    private fun runTermuxCommand(command: String, result: MethodChannel.Result) {
        val termuxPackage = "com.termux"
        val pm = packageManager

        // Check if Termux is installed
        try {
            pm.getPackageInfo(termuxPackage, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            result.error("TERMUX_NOT_INSTALLED", "Termux is not installed", null)
            return
        }

        try {
            val intent = Intent().apply {
                setClassName(
                    termuxPackage,
                    "com.termux.app.RunCommandService"
                )
                action = "com.termux.RUN_COMMAND"
                putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            }
            startService(intent)
            result.success("Command sent to Termux: $command")
        } catch (e: Exception) {
            result.error("TERMUX_ERROR", e.message, null)
        }
    }
}
