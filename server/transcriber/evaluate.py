"""Compare local recognition models against a supplied UTF-8 reference.

Audio and reference text remain local. Prints metrics only, never transcript text.
"""
import argparse
import json
import time
import unicodedata
from pathlib import Path


def normalize(text):
    """Ignore punctuation, diacritics and whitespace; retain Arabic/Persian letters."""
    text = unicodedata.normalize('NFC', text)
    return ' '.join(''.join(
        char if char.isalnum() or char.isspace() else ' '
        for char in text if unicodedata.category(char) != 'Mn'
    ).split())


def distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for index, expected in enumerate(reference, 1):
        next_row = [index]
        for column, actual in enumerate(hypothesis, 1):
            next_row.append(min(next_row[-1] + 1, row[column] + 1,
                                row[column - 1] + (expected != actual)))
        row = next_row
    return row[-1]


def score(reference, hypothesis):
    reference, hypothesis = normalize(reference), normalize(hypothesis)
    words = reference.split()
    characters = reference.replace(' ', '')
    if not words or not characters:
        raise ValueError('reference must contain words')
    return {
        'wer': distance(words, hypothesis.split()) / len(words),
        'cer': distance(characters, hypothesis.replace(' ', '')) / len(characters),
        'reference_words': len(words),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audio', type=Path)
    parser.add_argument('reference', type=Path)
    parser.add_argument('--model', default='large-v3-turbo')
    parser.add_argument('--language', choices=['auto', 'fa', 'ar'], default='auto')
    parser.add_argument('--threads', type=int, default=2)
    args = parser.parse_args()
    reference = args.reference.read_text(encoding='utf-8')
    score(reference, '')  # Reject empty references before loading the model.
    from faster_whisper import WhisperModel
    from service import model_source
    model = WhisperModel(model_source(args.model), device='cpu', compute_type='int8',
                         cpu_threads=args.threads)
    started = time.monotonic()
    segments, info = model.transcribe(
        str(args.audio), language=None if args.language == 'auto' else args.language,
        beam_size=5, condition_on_previous_text=False, vad_filter=False,
    )
    hypothesis = ' '.join(segment.text for segment in segments)
    elapsed = time.monotonic() - started
    print(json.dumps({
        'model': args.model, 'language_requested': args.language,
        'language_detected': info.language, 'seconds': round(elapsed, 3),
        'audio_seconds': info.duration, **score(reference, hypothesis),
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
