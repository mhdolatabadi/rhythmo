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
    private val metadataWriteRequest = 4105
    private var pendingMetadataWrite: ((Boolean) -> Unit)? = null
    private var editingMetadata = false

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
                "recoverAudioMetadata" -> {
                    val journal = metadataJournal()
                    val uri = journal.getString("uri", null)
                    val name = journal.getString("name", null)
                    if (uri == null || name == null) result.success(true)
                    else handleWriteAudioMetadata(uri, name, mapOf("__recover" to true), result)
                }
                "readAudioMetadata" -> {
                    val uri = call.argument<String>("uri")
                    val name = call.argument<String>("fileName") ?: "audio.mp3"
                    if (uri == null) {
                        result.error("INVALID_ARGUMENT", "Audio URI is required.", null)
                    } else Thread {
                        var copy: File? = null
                        try {
                            val temp = File.createTempFile("rhythmo-tags-", "."+name.substringAfterLast('.'), cacheDir)
                            copy = temp
                            contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                                temp.outputStream().use { input.copyTo(it) }
                            } ?: throw IOException("Audio could not be read.")
                            val values = AudioMetadataTags.read(temp)
                            runOnUiThread { result.success(values) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("METADATA_READ_FAILED", error.message, null) }
                        } finally { copy?.delete() }
                    }.start()
                }
                "writeAudioMetadata" -> handleWriteAudioMetadata(
                    call.argument<String>("uri"),
                    call.argument<String>("fileName"),
                    call.argument<Map<String, Any?>>("metadata"),
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
        Thread {
            var output: File? = null
            try {
                val safeName = fileName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                val target = File.createTempFile("rhythmo-upload-", "-$safeName", cacheDir)
                output = target
                val input = contentResolver.openInputStream(Uri.parse(uri))
                if (input == null) {
                    target.delete()
                    runOnUiThread {
                        result.error("NOT_FOUND", "Audio file could not be opened.", null)
                    }
                } else {
                    input.use { source ->
                        target.outputStream().use { destination -> source.copyTo(destination) }
                    }
                    runOnUiThread { result.success(target.absolutePath) }
                }
            } catch (error: Exception) {
                output?.delete()
                runOnUiThread { result.error("READ_FAILED", error.message, null) }
            }
        }.start()
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
        if (pendingDelete != null || pendingWrite != null || editingMetadata) {
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

    private fun handleWriteAudioMetadata(
        rawUri: String?,
        fileName: String?,
        metadata: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        if (rawUri == null || fileName == null || metadata == null ||
            fileName.isBlank() || fileName.any { it in "/\\:*?\"<>|" }) {
            result.error("INVALID_ARGUMENT", "A valid audio file and metadata are required.", null)
            return
        }
        if (editingMetadata || pendingDelete != null || pendingWrite != null) {
            result.error("BUSY", "Another storage request is active.", null)
            return
        }
        editingMetadata = true
        val uri = Uri.parse(rawUri)
        fun finishError(code: String, message: String?) {
            editingMetadata = false
            result.error(code, message, null)
        }
        fun start(askUser: Boolean) {
            Thread {
                try {
                    // Probe without truncation before making any changes.
                    contentResolver.openFileDescriptor(uri, "rw")?.use { }
                        ?: throw IOException("Audio file could not be opened for writing.")
                    val size = if (metadata["__recover"] == true) {
                        restoreMetadataBackup()
                        1L
                    } else rewriteAudioMetadata(uri, fileName, metadata)
                    runOnUiThread {
                        editingMetadata = false
                        result.success(mapOf("sizeBytes" to size))
                    }
                } catch (error: SecurityException) {
                    runOnUiThread {
                        val sender = try { when {
                            !askUser -> null
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                                MediaStore.createWriteRequest(contentResolver, listOf(uri)).intentSender
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && error is RecoverableSecurityException ->
                                error.userAction.actionIntent.intentSender
                            else -> null
                        } } catch (_: Exception) { null }
                        if (sender == null) {
                            finishError("PERMISSION_DENIED", "Audio write access was denied.")
                        } else {
                            pendingMetadataWrite = { granted ->
                                if (granted) start(false)
                                else finishError("PERMISSION_DENIED", "Audio write access was declined.")
                            }
                            try {
                                startIntentSenderForResult(sender, metadataWriteRequest, null, 0, 0, 0)
                            } catch (failure: Exception) {
                                pendingMetadataWrite = null
                                finishError("PERMISSION_DENIED", failure.message)
                            }
                        }
                    }
                } catch (error: Exception) {
                    runOnUiThread { finishError("METADATA_WRITE_FAILED", error.message) }
                }
            }.start()
        }
        withWritePermission { granted ->
            if (granted) start(true)
            else finishError("PERMISSION_DENIED", "Storage write access was denied.")
        }
    }

    // Content providers cannot atomically replace an audio URI. Keep an exact
    // backup until the rewritten bytes have been read back and verified.
    private fun rewriteAudioMetadata(uri: Uri, fileName: String, metadata: Map<String, Any?>): Long {
        val originalName = contentResolver.query(uri, arrayOf(MediaStore.Audio.Media.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            ?: throw IOException("Audio filename is unavailable.")
        val extension = originalName.substringAfterLast('.', "").lowercase()
        require(extension == fileName.substringAfterLast('.', "").lowercase()) { "Audio format cannot change." }
        if (metadataJournal().contains("uri")) throw IOException("An interrupted audio edit must be recovered first.")
        val backup = File.createTempFile("rhythmo-original-", ".$extension", filesDir)
        val edited = File.createTempFile("rhythmo-edited-", ".$extension", cacheDir)
        var changed = false
        var restored = true
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                backup.outputStream().use { output -> input.copyTo(output); output.fd.sync() }
            } ?: throw IOException("Audio file could not be read.")
            backup.copyTo(edited, overwrite = true)
            @Suppress("UNCHECKED_CAST")
            AudioMetadataTags.rewrite(edited, metadata as Map<String, Any>)
            // Tag writing and verification finish on the copy before touching
            // the user's original URI. No decoder or encoder is involved.
            if (!metadataJournal().edit().putString("uri", uri.toString())
                    .putString("backup", backup.absolutePath).putString("name", originalName).commit()) {
                throw IOException("Audio recovery journal could not be saved.")
            }
            changed = true
            replaceAudioBytes(uri, edited)
            val expected = java.security.MessageDigest.getInstance("SHA-256")
            val actual = java.security.MessageDigest.getInstance("SHA-256")
            edited.inputStream().use { input ->
                val bytes = ByteArray(65536)
                while (true) { val count = input.read(bytes); if (count < 0) break; expected.update(bytes, 0, count) }
            }
            contentResolver.openInputStream(uri)?.use { input ->
                val bytes = ByteArray(65536)
                while (true) { val count = input.read(bytes); if (count < 0) break; actual.update(bytes, 0, count) }
            } ?: throw IOException("Audio could not be verified.")
            if (!expected.digest().contentEquals(actual.digest())) throw IOException("Audio write verification failed.")
            val values = ContentValues().apply { put(MediaStore.Audio.Media.DISPLAY_NAME, fileName) }
            if (contentResolver.update(uri, values, null, null) != 1) throw IOException("Audio rename failed.")
            val path = runCatching {
                contentResolver.query(uri, arrayOf(MediaStore.Audio.Media.DATA), null, null, null)
                    ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            }.getOrNull()
            if (path != null) MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
            if (!metadataJournal().edit().clear().commit()) throw IOException("Audio recovery journal could not be cleared.")
            return edited.length()
        } catch (error: Exception) {
            if (changed) {
                try {
                    restoreMetadataBackup()
                } catch (rollback: Exception) {
                    restored = false
                    throw IOException("Original audio backup retained at "+backup.absolutePath, rollback)
                }
            }
            throw error
        } finally {
            edited.delete()
            if (restored) backup.delete()
        }
    }

    private fun metadataJournal() = getSharedPreferences("rhythmo_metadata_recovery", MODE_PRIVATE)

    // A durable original in filesDir survives process death and cache eviction.
    // Dart invokes recovery before reading an editor, requesting write consent
    // through the same path as an ordinary edit when Android requires it.
    private fun restoreMetadataBackup() {
        val journal = metadataJournal()
        val rawUri = journal.getString("uri", null) ?: return
        val originalName = journal.getString("name", null) ?: throw IOException("Recovery filename missing.")
        val path = journal.getString("backup", null) ?: throw IOException("Recovery backup missing.")
        val backup = File(path)
        if (!backup.isFile || backup.length() == 0L) throw IOException("Original audio backup unavailable.")
        val uri = Uri.parse(rawUri)
        replaceAudioBytes(uri, backup)
        val expected = java.security.MessageDigest.getInstance("SHA-256")
        val actual = java.security.MessageDigest.getInstance("SHA-256")
        backup.inputStream().use { input ->
            val bytes = ByteArray(65536)
            while (true) { val count = input.read(bytes); if (count < 0) break; expected.update(bytes, 0, count) }
        }
        contentResolver.openInputStream(uri)?.use { input ->
            val bytes = ByteArray(65536)
            while (true) { val count = input.read(bytes); if (count < 0) break; actual.update(bytes, 0, count) }
        } ?: throw IOException("Restored audio could not be read.")
        if (!expected.digest().contentEquals(actual.digest())) throw IOException("Original audio restore verification failed.")
        if (contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, originalName)
            }, null, null) != 1) throw IOException("Original filename could not be restored.")
        if (!journal.edit().clear().commit()) throw IOException("Audio recovery state could not be cleared.")
        backup.delete()
    }

    private fun replaceAudioBytes(uri: Uri, source: File) {
        val descriptor = contentResolver.openFileDescriptor(uri, "rw")
            ?: throw IOException("Audio file could not be written.")
        android.os.ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { output ->
            output.channel.truncate(0)
            output.channel.position(0)
            source.inputStream().use { it.copyTo(output) }
            output.fd.sync()
        }
    }

    @Deprecated("Needed for MediaStore delete confirmation on API 29+.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == metadataWriteRequest) {
            val callback = pendingMetadataWrite ?: return
            pendingMetadataWrite = null
            callback(resultCode == Activity.RESULT_OK)
            return
        }
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
