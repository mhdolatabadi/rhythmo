package ir.mhdolatabadi.nafir

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

// Shares the Flutter engine with audio_service's background playback service,
// so music keeps playing and responds to media controls with the app closed.
class MainActivity : AudioServiceActivity() {
    private val channelName = "ir.mhdolatabadi.nafir/local_audio"
    private val permissionRequest = 4102
    private val writePermissionRequest = 4103
    private val deleteRequest = 4104

    /// Where downloaded tracks are saved, relative to shared storage.
    private val musicFolder = "${Environment.DIRECTORY_MUSIC}/rhythmo"
    private var pendingResult: MethodChannel.Result? = null

    /// Waiting for the storage write permission (Android 9 and older).
    private var pendingWrite: ((Boolean) -> Unit)? = null

    /// Waiting for the user to confirm deleting a file another app made.
    private var pendingDelete: ((Boolean) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "permissionStatus" -> result.success(mapOf(
                    "audio" to hasAudioPermission(),
                    "microphone" to (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
                    "notifications" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
                ))
                "openAppSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }
                "appVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
                    result.success(mapOf("version" to info.versionName, "build_number" to build.toString()))
                }
                "queryAudio" -> handleQueryAudio(result)
                "readArtwork" -> handleReadArtwork(call.argument<String>("uri"), result)
                "copyAudioToCache" -> handleCopyAudioToCache(
                    call.argument<String>("uri"),
                    call.argument<String>("fileName"),
                    result,
                )
                "deleteAudio" -> handleDeleteAudio(call.argument<String>("uri"), result)
                "saveAudio" -> handleSaveAudio(
                    call.argument<String>("path"),
                    call.argument<String>("fileName"),
                    call.argument<String>("mimeType"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun handleReadArtwork(value: String?, result: MethodChannel.Result) {
        val uri = value?.let { Uri.parse(it) }
        if (uri == null || uri.scheme != "content" || uri.authority != MediaStore.AUTHORITY || !hasAudioPermission()) {
            result.success(null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            var output: ByteArray? = null
            try {
                retriever.setDataSource(this, uri)
                val picture = retriever.embeddedPicture
                if (picture != null && picture.size <= 16 * 1024 * 1024) {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(picture, 0, picture.size, bounds)
                    if (bounds.outWidth > 0 && bounds.outHeight > 0 &&
                        bounds.outWidth.toLong() * bounds.outHeight <= 16 * 1024 * 1024) {
                        var sample = 1
                        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 512) sample *= 2
                        val options = BitmapFactory.Options().apply { inSampleSize = sample }
                        val bitmap = BitmapFactory.decodeByteArray(picture, 0, picture.size, options)
                        if (bitmap != null) {
                            val buffer = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.JPEG, 88, buffer)
                            bitmap.recycle()
                            output = buffer.toByteArray().takeIf { it.size <= 512 * 1024 }
                        }
                    }
                }
            } catch (_: Exception) {
                // A corrupt or absent picture must not prevent playback.
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
            runOnUiThread { result.success(output) }
        }.start()
    }

    private fun handleQueryAudio(result: MethodChannel.Result) {
        if (hasAudioPermission()) {
            result.success(queryAudio())
        } else if (pendingResult != null) {
            result.error("BUSY", "An audio permission request is already active.", null)
        } else {
            pendingResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(audioPermission()),
                permissionRequest,
            )
        }
    }

    private fun handleCopyAudioToCache(
        uri: String?,
        fileName: String?,
        result: MethodChannel.Result,
    ) {
        if (uri == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Audio uri and filename are required.", null)
            return
        }
        if (!hasAudioPermission()) {
            result.error("PERMISSION_DENIED", "Audio access was denied.", null)
            return
        }
        try {
            val safeName = fileName.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val output = File.createTempFile("nafir-upload-", "-$safeName", cacheDir)
            contentResolver.openInputStream(Uri.parse(uri)).use { input ->
                if (input == null) {
                    result.error("NOT_FOUND", "Audio file could not be opened.", null)
                    return
                }
                output.outputStream().use { outputStream -> input.copyTo(outputStream) }
            }
            result.success(output.absolutePath)
        } catch (error: Exception) {
            result.error("READ_FAILED", error.message, null)
        }
    }

    /// Adds a downloaded file to the device's music (Music/rhythmo), where
    /// queryAudio finds it, copying it as is. Runs off the main thread and
    /// answers with the new file's uri; a file with the same name and size
    /// already there is reported as DUPLICATE and left untouched.
    private fun handleSaveAudio(
        path: String?,
        fileName: String?,
        mimeType: String?,
        result: MethodChannel.Result,
    ) {
        if (path == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Path and filename are required.", null)
            return
        }
        if (pendingWrite != null) {
            result.error("BUSY", "Another storage request is active.", null)
            return
        }
        val name = File(fileName).name.ifBlank { "track" }
        val type = mimeType ?: "audio/*"
        withWritePermission { granted ->
            if (!granted) {
                result.error("PERMISSION_DENIED", "Storage access was denied.", null)
                return@withWritePermission
            }
            Thread {
                try {
                    saveAudio(File(path), name, type) { uri ->
                        runOnUiThread { result.success(uri) }
                    }
                } catch (error: DuplicateAudio) {
                    runOnUiThread { result.error("DUPLICATE", "Already saved.", null) }
                } catch (error: Exception) {
                    val code = if (error.message?.contains("ENOSPC") == true ||
                        error.message?.contains("No space left") == true
                    ) "NO_SPACE" else "SAVE_FAILED"
                    runOnUiThread { result.error(code, error.message, null) }
                }
            }.start()
        }
    }

    private class DuplicateAudio : Exception()

    private fun saveAudio(source: File, name: String, type: String, done: (String) -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            contentResolver.query(
                collection,
                arrayOf(MediaStore.Audio.Media.SIZE),
                "${MediaStore.Audio.Media.RELATIVE_PATH}=? AND ${MediaStore.Audio.Media.DISPLAY_NAME}=?",
                arrayOf("$musicFolder/", name),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getLong(0) == source.length()) throw DuplicateAudio()
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, type)
                put(MediaStore.Audio.Media.RELATIVE_PATH, musicFolder)
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            // Android renames the file when another one has the same name.
            val uri = contentResolver.insert(collection, values)
                ?: throw IOException("Could not create the audio file.")
            try {
                val output = contentResolver.openOutputStream(uri)
                    ?: throw IOException("Could not open the audio file.")
                output.use { out -> source.inputStream().use { it.copyTo(out) } }
                contentResolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
            done(uri.toString())
        } else {
            @Suppress("DEPRECATION")
            val directory = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                musicFolder.substringAfter('/'),
            )
            if (!directory.exists() && !directory.mkdirs()) {
                throw IOException("Could not create $directory.")
            }
            var target = File(directory, name)
            if (target.exists() && target.length() == source.length()) throw DuplicateAudio()
            var copy = 1
            while (target.exists()) {
                target = File(directory, "${name.substringBeforeLast('.')} ($copy)" +
                    (if (name.contains('.')) ".${name.substringAfterLast('.')}" else ""))
                copy++
            }
            try {
                source.copyTo(target)
            } catch (error: Exception) {
                target.delete()
                throw error
            }
            // Answer once the media scanner indexed it, so a refresh finds it.
            MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(type)) { _, uri ->
                done((uri ?: Uri.fromFile(target)).toString())
            }
        }
    }

    /// Deletes a device track. Files rhythmo saved are deleted directly; for
    /// others Android asks the user to confirm. Answers true once deleted and
    /// false when the user declined.
    private fun handleDeleteAudio(uri: String?, result: MethodChannel.Result) {
        if (uri == null) {
            result.error("INVALID_ARGUMENT", "Audio uri is required.", null)
            return
        }
        if (pendingDelete != null || pendingWrite != null) {
            result.error("BUSY", "Another storage request is active.", null)
            return
        }
        withWritePermission { granted ->
            if (!granted) {
                result.error("PERMISSION_DENIED", "Storage access was denied.", null)
                return@withWritePermission
            }
            deleteAudio(Uri.parse(uri), result, askUser = true)
        }
    }

    private fun deleteAudio(uri: Uri, result: MethodChannel.Result, askUser: Boolean) {
        try {
            contentResolver.delete(uri, null, null)
            result.success(true)
        } catch (error: SecurityException) {
            val sender = when {
                !askUser -> null
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    MediaStore.createDeleteRequest(contentResolver, listOf(uri)).intentSender
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    error is RecoverableSecurityException ->
                    error.userAction.actionIntent.intentSender
                else -> null
            }
            if (sender == null) {
                result.error("PERMISSION_DENIED", error.message, null)
                return
            }
            pendingDelete = { confirmed ->
                when {
                    !confirmed -> result.success(false)
                    // Android 11+ deletes the file itself once confirmed.
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> result.success(true)
                    else -> deleteAudio(uri, result, askUser = false)
                }
            }
            startIntentSenderForResult(sender, deleteRequest, null, 0, 0, 0)
        } catch (error: Exception) {
            result.error("DELETE_FAILED", error.message, null)
        }
    }

    @Deprecated("Needed for MediaStore delete confirmation on API 29+.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != deleteRequest) return
        val callback = pendingDelete ?: return
        pendingDelete = null
        callback(resultCode == Activity.RESULT_OK)
    }

    /// Android 9 and older need a runtime permission to change shared
    /// storage; newer versions use MediaStore and need none.
    private fun withWritePermission(callback: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            callback(true)
            return
        }
        pendingWrite = callback
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            writePermissionRequest,
        )
    }

    private fun audioPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun hasAudioPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            ContextCompat.checkSelfPermission(this, audioPermission()) ==
            PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == writePermissionRequest) {
            val callback = pendingWrite ?: return
            pendingWrite = null
            callback(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            return
        }
        if (requestCode != permissionRequest) return
        val result = pendingResult ?: return
        pendingResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            result.success(queryAudio())
        } else {
            result.error("PERMISSION_DENIED", "Audio access was denied.", null)
        }
    }

    private fun queryAudio(): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.SIZE,
        )
        val tracks = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val artistColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val typeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                tracks += mapOf(
                    "id" to id.toString(),
                    "title" to (cursor.getString(titleColumn)
                        ?: cursor.getString(nameColumn)
                        ?: "Unknown"),
                    "artist" to cursor.getString(artistColumn),
                    "album" to cursor.getString(albumColumn),
                    "contentType" to (cursor.getString(typeColumn) ?: "audio/*"),
                    "sizeBytes" to cursor.getLong(sizeColumn),
                    "fileName" to cursor.getString(nameColumn),
                    "uri" to ContentUris.withAppendedId(
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                        id,
                    ).toString(),
                )
            }
        }
        return tracks
    }
}
