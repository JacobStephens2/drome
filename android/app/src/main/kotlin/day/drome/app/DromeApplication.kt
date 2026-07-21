package day.drome.app

import android.app.Application
import android.content.Context
import day.drome.app.reminders.ReminderScheduler
import day.drome.core.DromeCoreClient
import day.drome.core.LiveDromeCore

class DromeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DromeCoreProvider.initialize(this)
        ReminderScheduler.reschedule(this)
    }
}

/** One lazily opened store per Android process; safe from Activity and widget cold starts. */
object DromeCoreProvider {
    @Volatile private var client: DromeCoreClient? = null
    @Volatile private var appContext: Context? = null

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    fun get(context: Context? = null): DromeCoreClient {
        client?.let { return it }
        return synchronized(this) {
            client ?: run {
                val app = context?.applicationContext ?: checkNotNull(appContext) {
                    "DromeCoreProvider must be initialized with an application context"
                }
                // Explicit backup rules exclude the SQLite/WAL trio on every supported API.
                LiveDromeCore.open(app.filesDir.resolve("drome.sqlite").absolutePath).also { client = it }
            }
        }
    }
}
