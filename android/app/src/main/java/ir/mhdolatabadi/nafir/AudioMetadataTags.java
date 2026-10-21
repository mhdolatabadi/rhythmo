package ir.mhdolatabadi.nafir;

import java.io.File;
import java.util.LinkedHashMap;
import java.util.Map;
import org.jaudiotagger.audio.AudioFile;
import org.jaudiotagger.audio.AudioFileIO;
import org.jaudiotagger.tag.FieldKey;
import org.jaudiotagger.tag.Tag;

/** Rewrites tags on a temporary copy; encoded audio and unmanaged tags are retained. */
public final class AudioMetadataTags {
    private AudioMetadataTags() {}

    private static Map<String, FieldKey> fields() {
        Map<String, FieldKey> fields = new LinkedHashMap<>();
        fields.put("title", FieldKey.TITLE);
        fields.put("artist", FieldKey.ARTIST);
        fields.put("album", FieldKey.ALBUM);
        fields.put("albumArtist", FieldKey.ALBUM_ARTIST);
        fields.put("composer", FieldKey.COMPOSER);
        fields.put("genre", FieldKey.GENRE);
        fields.put("year", FieldKey.YEAR);
        fields.put("trackNumber", FieldKey.TRACK);
        fields.put("discNumber", FieldKey.DISC_NO);
        fields.put("comment", FieldKey.COMMENT);
        return fields;
    }

    public static Map<String, String> read(File file) throws Exception {
        Tag tag = AudioFileIO.read(file).getTag();
        Map<String, String> values = new LinkedHashMap<>();
        if (tag == null) return values;
        for (Map.Entry<String, FieldKey> field : fields().entrySet()) {
            values.put(field.getKey(), tag.getFirst(field.getValue()));
        }
        return values;
    }

    public static void rewrite(File file, Map<String, Object> values) throws Exception {
        AudioFile audio = AudioFileIO.read(file);
        Tag tag = audio.getTagOrCreateAndSetDefault();
        Map<String, String> expected = new LinkedHashMap<>();
        for (Map.Entry<String, FieldKey> field : fields().entrySet()) {
            Object raw = values.get(field.getKey());
            String value = raw == null ? "" : raw.toString().trim();
            expected.put(field.getKey(), value);
            if (value.isEmpty()) {
                // Do not ask a format to delete fields it never held.
                if (!tag.getFirst(field.getValue()).isEmpty()) tag.deleteField(field.getValue());
            } else {
                tag.setField(field.getValue(), value);
            }
        }
        audio.commit();
        Map<String, String> actual = read(file);
        for (Map.Entry<String, String> field : expected.entrySet()) {
            if (!field.getValue().equals(actual.getOrDefault(field.getKey(), ""))) {
                throw new java.io.IOException("Metadata verification failed: " + field.getKey());
            }
        }
    }
}
