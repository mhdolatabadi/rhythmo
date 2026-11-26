import unittest
from evaluate import score


class EvaluationTest(unittest.TestCase):
    def test_exact_arabic_ignores_diacritics_and_punctuation(self):
        self.assertEqual(score('سَلام، عليك', 'سلام عليك')['wer'], 0)

    def test_substitution_deletion_and_insertion(self):
        self.assertEqual(score('one two three', 'one other')['wer'], 2 / 3)
        self.assertEqual(score('one', 'one two')['wer'], 1)
        self.assertEqual(score('ab', 'ac')['cer'], 0.5)

    def test_empty_hypothesis_and_empty_reference(self):
        self.assertEqual(score('سلام', '')['wer'], 1)
        with self.assertRaises(ValueError):
            score(' ! ', 'سلام')

    def test_does_not_hide_persian_arabic_letter_substitutions(self):
        self.assertEqual(score('علي', 'علی')['wer'], 1)
