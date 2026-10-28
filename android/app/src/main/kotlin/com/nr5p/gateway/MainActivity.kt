package com.nr5p.gateway

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import com.nr5p.gateway.ui.GatewayRoot
import com.nr5p.gateway.ui.GatewayTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as GatewayApplication
        setContent {
            // Keep the screen on during a session, as the iPhone app does: Android may
            // otherwise stop the app's network traffic while the link is up.
            val running = app.session.running
            LaunchedEffect(running) {
                if (running) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
            GatewayTheme { GatewayRoot(app) }
        }
    }
}
