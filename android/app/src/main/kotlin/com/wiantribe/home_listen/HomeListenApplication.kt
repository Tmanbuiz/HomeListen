package com.wiantribe.home_listen

import android.app.Application
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

/** Restore public Firebase options before a background FCM receiver runs. */
class HomeListenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val prefs = getSharedPreferences("homelisten_firebase", MODE_PRIVATE)
        val appId = prefs.getString("appId", null) ?: return
        val apiKey = prefs.getString("apiKey", null) ?: return
        val project = prefs.getString("projectId", null) ?: return
        val sender = prefs.getString("sender", null) ?: return
        if (FirebaseApp.getApps(this).isEmpty()) {
            FirebaseApp.initializeApp(this, FirebaseOptions.Builder()
                .setApplicationId(appId).setApiKey(apiKey)
                .setProjectId(project).setGcmSenderId(sender).build())
        }
    }
}
