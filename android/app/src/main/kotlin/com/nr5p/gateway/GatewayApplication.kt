package com.nr5p.gateway

import android.app.Application
import java.io.File

/** The app's long-lived state, shared by every screen. */
class GatewayApplication : Application() {
    lateinit var settings: Settings; private set
    lateinit var store: MailStore; private set
    lateinit var session: SessionController; private set
    lateinit var rig: RigController; private set
    lateinit var gateways: GatewayStore; private set

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        store = MailStore(File(filesDir, "Mail"))
        session = SessionController(settings)
        rig = RigController(this, settings)
        rig.log = { kind, text -> session.append(kind, text) }
        gateways = GatewayStore(this)
    }
}
