package ir.mhdolatabadi.nafir

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import java.io.File

/// The home-screen player (#227). It shows what the app last told it, kept
/// in preferences so it survives the app's process ending, and its buttons
/// send media keys to audio_service's receiver, the same path a headset
/// button takes, so they work through the existing media service.
class RhythmoWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        update(context, manager, id)
    }

    companion object {
        private const val prefsName = "rhythmo_widget"

        /// Below this width the widget drops previous and next.
        private const val mediumMinWidthDp = 250

        /// Keeps [state] and redraws every placed widget.
        fun save(context: Context, state: Map<String, Any?>) {
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit()
                .putString("title", state["title"] as? String)
                .putString("subtitle", state["subtitle"] as? String)
                .putBoolean("playing", state["playing"] as? Boolean ?: false)
                .putString("coverPath", state["coverPath"] as? String)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, RhythmoWidget::class.java))
            ids.forEach { update(context, manager, it) }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            val width = manager.getAppWidgetOptions(id)
                ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, mediumMinWidthDp)
                ?: mediumMinWidthDp
            val medium = width >= mediumMinWidthDp
            val views = RemoteViews(
                context.packageName,
                if (medium) R.layout.widget_player else R.layout.widget_player_small,
            )
            views.setTextViewText(
                R.id.widget_title,
                prefs.getString("title", null) ?: context.getString(R.string.widget_idle_title),
            )
            views.setTextViewText(
                R.id.widget_subtitle,
                prefs.getString("subtitle", null) ?: context.getString(R.string.widget_idle_subtitle),
            )
            val playing = prefs.getBoolean("playing", false)
            views.setImageViewResource(
                R.id.widget_play,
                if (playing) R.drawable.widget_pause else R.drawable.widget_play,
            )
            views.setContentDescription(
                R.id.widget_play,
                context.getString(if (playing) R.string.widget_pause else R.string.widget_play),
            )
            val cover = prefs.getString("coverPath", null)?.let(::loadCover)
            if (cover != null) {
                views.setImageViewBitmap(R.id.widget_cover, cover)
                views.setViewVisibility(R.id.widget_cover, View.VISIBLE)
                views.setViewVisibility(R.id.widget_note, View.GONE)
            } else {
                views.setViewVisibility(R.id.widget_cover, View.GONE)
                views.setViewVisibility(R.id.widget_note, View.VISIBLE)
            }
            views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
            views.setOnClickPendingIntent(
                R.id.widget_play,
                mediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE),
            )
            if (medium) {
                views.setOnClickPendingIntent(R.id.widget_next, mediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT))
                views.setOnClickPendingIntent(R.id.widget_previous, mediaKey(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
            }
            manager.updateAppWidget(id, views)
        }

        /// A small cover: widget bitmaps travel through a binder, which has
        /// a size limit.
        private fun loadCover(path: String): Bitmap? {
            val file = File(path)
            if (!file.isFile) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 144 && bounds.outHeight / (sample * 2) >= 144) {
                sample *= 2
            }
            return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        }

        private fun openApp(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun mediaKey(context: Context, keyCode: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                .setComponent(ComponentName(context.packageName, "com.ryanheise.audioservice.MediaButtonReceiver"))
                .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            return PendingIntent.getBroadcast(
                context, keyCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
