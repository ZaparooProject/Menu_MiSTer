import unittest

from check_timing import METRICS, check_timing


def report(value="0.042"):
    return "\n".join(
        f"Info (332146): Worst-case {metric} slack is {value}"
        for metric in sorted(METRICS)
    )


class TimingCheckTests(unittest.TestCase):
    def test_positive_and_zero_pass(self):
        check_timing(report())
        check_timing(report("0.000"))

    def test_each_negative_metric_fails(self):
        for metric in METRICS:
            with self.subTest(metric=metric), self.assertRaises(ValueError):
                check_timing(report().replace(f"{metric} slack is 0.042", f"{metric} slack is -0.016"))

    def test_incomplete_or_unrecognized_report_fails(self):
        for text in ("", "Quartus compilation successful", report().split("\n", 1)[1], report("NaN")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                check_timing(text)

    def test_critical_warning_fails_even_with_positive_summary(self):
        with self.assertRaises(ValueError):
            check_timing(report() + "\nCritical Warning (332148): Timing requirements not met")

    def test_negative_duplicate_is_not_hidden(self):
        with self.assertRaises(ValueError):
            check_timing(report("-0.016") + "\n" + report())

    def test_crlf_report_passes(self):
        check_timing(report().replace("\n", "\r\n"))


if __name__ == "__main__":
    unittest.main()
