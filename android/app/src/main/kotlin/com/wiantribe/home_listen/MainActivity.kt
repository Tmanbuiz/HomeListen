package com.wiantribe.home_listen

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The screen. The engine behind it is owned by [HomeListenEngine], so closing
 * this Activity (swiping the app away, "Close all") does not stop a running
 * session. See that class for what stays running and what stays visible.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        HomeListenEngine.engine(context)

    // The engine is created, configured and given its plugins once, in
    // HomeListenEngine. Flutter does not call this for an engine the host
    // provides, and registering plugins a second time would be a mistake.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {}

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        HomeListenEngine.activity = this
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (HomeListenEngine.activity === this) HomeListenEngine.activity = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        HomeListenEngine.onPermissionResult(requestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        HomeListenEngine.onActivityResult(this, requestCode, resultCode, data)
    }
}
