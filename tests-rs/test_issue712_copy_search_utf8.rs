// #712 audit: copy mode search resumed one BYTE after each hit, which is
// inside the hit when the query starts with a multi byte character, and the
// slice panicked the server (`send-keys -X search-forward 日本`).

use super::search_line_matches;

#[test]
fn cjk_query_finds_every_hit() {
    let m = search_line_matches("x\u{65e5}\u{672c}y\u{65e5}\u{672c}z\u{65e5}\u{672c}w", "\u{65e5}\u{672c}");
    assert_eq!(m, vec![(1, 3), (4, 6), (7, 9)]);
}

#[test]
fn two_byte_query_back_to_back() {
    let line = "\u{e9}cole\u{e9}cole\u{e9}cole";
    let m = search_line_matches(line, "\u{e9}cole");
    assert_eq!(m, vec![(0, 5), (5, 10), (10, 15)]);
}

#[test]
fn four_byte_query_overlapping() {
    let line = "\u{1f600}\u{1f600}\u{1f600}";
    let m = search_line_matches(line, "\u{1f600}\u{1f600}");
    assert_eq!(m, vec![(0, 2), (1, 3)]);
}

#[test]
fn ascii_overlap_unchanged() {
    assert_eq!(search_line_matches("aaaa", "aa"), vec![(0, 2), (1, 3), (2, 4)]);
    assert_eq!(search_line_matches("abc", "x"), vec![]);
    assert_eq!(search_line_matches("", "x"), vec![]);
    assert_eq!(search_line_matches("abc", ""), vec![]);
}

#[test]
fn hit_at_the_very_end() {
    assert_eq!(search_line_matches("ab\u{65e5}", "\u{65e5}"), vec![(2, 3)]);
}
