package ee.sbj.spot

import android.content.Context
import android.location.LocationManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small diagnostics channel. Read-only device/provider facts plus a
 * keep-screen-on switch for walk tests. Every call is best-effort: anything
 * the OS can't answer comes back null instead of throwing.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ee.sbj.spot/diag")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(deviceInfo())
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") == true
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(on)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun deviceInfo(): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["manufacturer"] = Build.MANUFACTURER
        info["model"] = Build.MODEL
        info["device"] = Build.DEVICE
        info["sdk_int"] = Build.VERSION.SDK_INT
        info["release"] = Build.VERSION.RELEASE
        info["build_id"] = Build.ID
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm != null) {
            info["enabled_providers"] = runCatching { lm.getProviders(true) }.getOrNull()
            info["all_providers"] = runCatching { lm.allProviders }.getOrNull()
            info["location_enabled"] = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) lm.isLocationEnabled else null
            }.getOrNull()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info["gnss_hardware_model"] = runCatching { lm.gnssHardwareModelName }.getOrNull()
                info["gnss_year"] = runCatching { lm.gnssYearOfHardware }.getOrNull()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val caps = runCatching { lm.gnssCapabilities }.getOrNull()
                if (caps != null) {
                    info["gnss_has_measurements"] = runCatching { caps.hasMeasurements() }.getOrNull()
                    info["gnss_has_navigation_messages"] =
                        runCatching { caps.hasNavigationMessages() }.getOrNull()
                }
            }
        }
        return info
    }
}
