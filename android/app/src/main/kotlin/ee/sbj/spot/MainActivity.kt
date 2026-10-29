package ee.sbj.spot

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.hardware.GeomagneticField
import android.location.LocationManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The compass plugin reports magnetic north on Android; Dart asks for
        // the local declination here to turn it into true north.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ee.sbj.spot/geomag")
            .setMethodCallHandler { call, result ->
                if (call.method != "declination") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val lat = call.argument<Double>("lat")
                val lon = call.argument<Double>("lon")
                if (lat == null || lon == null) {
                    result.error("bad_args", "lat and lon are required", null)
                    return@setMethodCallHandler
                }
                val alt = call.argument<Double>("alt") ?: 0.0
                val field = GeomagneticField(
                    lat.toFloat(),
                    lon.toFloat(),
                    alt.toFloat(),
                    System.currentTimeMillis(),
                )
                result.success(field.declination.toDouble())
            }
        // In-app updater: Dart downloads the APK into cache/updates/ and checks
        // its minisign-signed SHA-256 first; this only opens the system
        // installer, which asks the user and checks the app certificate.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ee.sbj.spot/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val updates = File(cacheDir, "updates").canonicalFile
                        val file = path?.let { File(it).canonicalFile }
                        if (file == null || file.parentFile != updates || !file.isFile) {
                            result.error("bad_path", "APK must be in cache/updates", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                            result.success("needs_permission")
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                        val intent = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success("started")
                    }
                    else -> result.notImplemented()
                }
            }
        // Small diagnostics channel. Read-only device/provider facts plus a
        // keep-screen-on switch for walk tests. Every call is best-effort:
        // anything the OS can't answer comes back null instead of throwing.
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
