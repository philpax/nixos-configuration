from datetime import datetime

from patlabor import slash_clock as sc


def glyph(v):
    return {sc.ON: "#", sc.DIM: ".", 0: " "}[v]


def test_frame_is_one_byte_per_zone():
    for second in range(60):
        for us in (0, 450_000, 999_999):
            frame = sc.frame_for(datetime(2026, 9, 26, 22, 47, second, us))
            assert len(frame) == sc.ZONES
            assert all(0 <= v <= 255 for v in frame)


def test_bcd_digits_are_lsb_first_with_separators():
    frame = sc.frame_for(datetime(2026, 9, 26, 22, 47, 0))
    # 2 = 0100, 2 = 0100 | 4 = 0010, 7 = 1110
    assert "".join(map(glyph, frame[:21])) == ".#.. .#..  ..#. ###. "


def test_seconds_fill_grows_by_whole_zones_and_never_completes():
    for second in range(60):
        region = sc.seconds_region(second, 0.0)
        filled = [i for i, c in enumerate(region) if c == sc.FILL]
        assert filled == list(range(second * sc.SECONDS_ZONES // 60))
        assert len(filled) < sc.SECONDS_ZONES


def test_dot_stays_in_empty_zones_and_rests_on_first_empty_zone():
    for second in range(0, 56):
        filled = second * sc.SECONDS_ZONES // 60
        for sub in (0.0, 0.3, 0.45, 0.6, sc.TRAVEL_TIME, 0.99):
            region = sc.seconds_region(second, sub)
            assert all(region[i] == sc.FILL for i in range(filled))
            # The dot is anti-aliased over at most two adjacent empty zones.
            dot = [i for i, c in enumerate(region) if c > sc.FILL]
            assert dot and all(i >= filled for i in dot)
            assert abs(sum(region[i] for i in dot) - sc.ON) <= 1
        assert sc.seconds_region(second, sc.TRAVEL_TIME).index(sc.ON) == filled
        assert sc.seconds_region(second, 0.45)[filled] < sc.ON


def test_last_zone_fades_up_to_fill_level():
    last = sc.SECONDS_ZONES - 1
    start = sc.seconds_region(56, 0.0)[last]
    mid = sc.seconds_region(58, 0.0)[last]
    end = sc.seconds_region(59, 0.999)[last]
    assert 0 <= start < 10
    assert start < mid < end <= sc.FILL
    assert end >= sc.FILL - 2
