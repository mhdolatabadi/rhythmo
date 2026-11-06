package ir.mhdolatabadi.nafir;

import static org.junit.Assert.*;
import java.io.*;
import java.nio.file.Files;
import java.util.*;
import org.junit.Test;
import org.jaudiotagger.audio.AudioFileIO;
import org.jaudiotagger.tag.Tag;

public class AudioMetadataTagsTest {
    private Map<String, Object> metadata() {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("title", "عنوان تازه");
        fields.put("artist", "خواننده");
        fields.put("album", "آلبوم");
        fields.put("albumArtist", "گروه");
        fields.put("composer", "آهنگساز");
        fields.put("genre", "Test");
        fields.put("year", 2026);
        fields.put("trackNumber", 3);
        fields.put("discNumber", 2);
        fields.put("comment", "یادداشت");
        return fields;
    }

    @Test public void rewritesAndVerifiesPersianTagsPreservingArtworkAndAudio() throws Exception {
        for (String name : Arrays.asList("v24.mp3", "v23-cover-id3v1.mp3", "notag.mp3",
                "tagged.flac", "tagged.ogg", "sample.m4a")) {
            File temp = File.createTempFile("rhythmo-test-", name);
            try (InputStream input = getClass().getResourceAsStream("/"+name)) {
                assertNotNull(name, input);
                Files.copy(input, temp.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            }
            try {
                byte[] before = Files.readAllBytes(temp.toPath());
                Tag tag = AudioFileIO.read(temp).getTag();
                byte[] cover = tag == null || tag.getFirstArtwork() == null ? null : tag.getFirstArtwork().getBinaryData();
                AudioMetadataTags.rewrite(temp, metadata());
                assertEquals(name, "عنوان تازه", AudioMetadataTags.read(temp).get("title"));
                Tag after = AudioFileIO.read(temp).getTag();
                byte[] afterCover = after.getFirstArtwork() == null ? null : after.getFirstArtwork().getBinaryData();
                assertArrayEquals(name+" artwork", cover, afterCover);
                if (name.endsWith(".mp3")) {
                    assertArrayEquals(name+" encoded audio", mp3Payload(before), mp3Payload(Files.readAllBytes(temp.toPath())));
                }
                Map<String, Object> cleared = metadata();
                cleared.put("artist", "");
                AudioMetadataTags.rewrite(temp, cleared);
                assertEquals("", AudioMetadataTags.read(temp).get("artist"));
            } finally { temp.delete(); }
        }
    }

    @Test public void unsupportedFormatDoesNotChangeTheInput() throws Exception {
        File temp = File.createTempFile("rhythmo-unsupported-", ".opus");
        try (InputStream input = getClass().getResourceAsStream("/tagged.opus")) {
            Files.copy(input, temp.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
        try {
            byte[] before = Files.readAllBytes(temp.toPath());
            try {
                AudioMetadataTags.rewrite(temp, metadata());
                fail("Unsupported format must fail before any write.");
            } catch (org.jaudiotagger.audio.exceptions.CannotReadException expected) {
                assertArrayEquals(before, Files.readAllBytes(temp.toPath()));
            }
        } finally { temp.delete(); }
    }

    private byte[] mp3Payload(byte[] bytes) {
        int start = 0;
        if (bytes.length > 10 && bytes[0]=='I' && bytes[1]=='D' && bytes[2]=='3') {
            start = 10 + ((bytes[6]&127)<<21) + ((bytes[7]&127)<<14) + ((bytes[8]&127)<<7) + (bytes[9]&127);
        }
        int end = bytes.length;
        if (end >= 128 && bytes[end-128]=='T' && bytes[end-127]=='A' && bytes[end-126]=='G') end -= 128;
        return Arrays.copyOfRange(bytes, start, end);
    }
}
