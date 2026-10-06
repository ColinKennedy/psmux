// Discussion #749: tmux folds an emoji cluster (a ZWJ sequence, a skin tone
// modifier sequence, a regional indicator pair, an emoji followed by U+FE0F)
// into ONE cell of TWO columns, which is what seven of the eight measured
// Windows terminals draw (mintty is the outlier and draws the parts apart).
// psmux used to give every wide member of the cluster its own cell, so the
// child believed in two columns while the grid spent four or eight.
//
// Parity oracle (tmux 3.7c, cursor_x after writing the sequence to a fresh
// pane), see tmux utf8-combined.c utf8_should_combine and screen-write.c
// screen_write_cell:
//   U+0041                                        -> 1
//   U+3042                                        -> 2
//   U+2764                                        -> 1
//   U+2764 U+FE0F                                 -> 2
//   U+2733 U+FE0F                                 -> 2
//   U+1F44D                                       -> 2
//   U+1F44D U+1F3FD                               -> 2
//   U+1F1EF U+1F1F5                               -> 2
//   U+1F3F3 U+FE0F U+200D U+1F308                 -> 2
//   U+1F468 U+200D U+1F469 U+200D U+1F467 U+200D U+1F466 -> 2

fn parse(cols: u16, chunks: &[&str]) -> vt100_psmux::Parser {
    let mut p = vt100_psmux::Parser::new(4, cols, 0);
    for c in chunks {
        p.process(c.as_bytes());
    }
    p
}

fn cursor_col_after(s: &str) -> u16 {
    parse(40, &[s]).screen().cursor_position().1
}

const SEQUENCES: [(&str, &str, u16); 10] = [
    ("A", "\u{0041}", 1),
    ("hiragana a", "\u{3042}", 2),
    ("heart", "\u{2764}", 1),
    ("heart VS16", "\u{2764}\u{FE0F}", 2),
    ("asterisk VS16", "\u{2733}\u{FE0F}", 2),
    ("thumbs up", "\u{1F44D}", 2),
    ("thumbs up skin tone", "\u{1F44D}\u{1F3FD}", 2),
    ("flag JP", "\u{1F1EF}\u{1F1F5}", 2),
    ("rainbow flag", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", 2),
    (
        "family",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
        2,
    ),
];

const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";

#[test]
fn ten_sequences_match_tmux_cursor_columns() {
    let got: Vec<u16> = SEQUENCES.iter().map(|(_, s, _)| cursor_col_after(s)).collect();
    let want: Vec<u16> = SEQUENCES.iter().map(|(_, _, w)| *w).collect();
    println!("psmux cursor columns: {got:?}");
    println!("tmux  cursor columns: {want:?}");
    assert_eq!(got, want, "cursor columns must match tmux 3.7c");
}

#[test]
fn every_cluster_is_one_cell_and_text_follows_on_col_2() {
    for (name, s, w) in SEQUENCES.iter().filter(|(_, _, w)| *w == 2) {
        let p = parse(40, &[&format!("{s}X")]);
        let scr = p.screen();
        let base = scr.cell(0, 0).unwrap();
        assert_eq!(base.contents(), *s, "{name}: cell 0 holds the whole cluster");
        assert!(base.is_wide(), "{name}: cluster cell is wide");
        assert!(scr.cell(0, 1).unwrap().is_wide_continuation(), "{name}: col 1 continuation");
        assert_eq!(scr.cell(0, *w).unwrap().contents(), "X", "{name}: X lands on col 2");
    }
}

#[test]
fn clusters_survive_every_chunk_boundary() {
    for (name, s, w) in SEQUENCES.iter() {
        let bytes = s.as_bytes();
        for cut in 1..bytes.len() {
            let mut p = vt100_psmux::Parser::new(4, 40, 0);
            p.process(&bytes[..cut]);
            p.process(&bytes[cut..]);
            assert_eq!(p.screen().cursor_position().1, *w, "{name}: byte split at {cut}");
            assert_eq!(p.screen().cell(0, 0).unwrap().contents(), *s, "{name}: split at {cut}");
        }
    }
}

// tmux: a ZWJ is zero width and folds into whatever cell came before it, but
// the character after the ZWJ only joins when the previous cell is an emoji
// (utf8_should_combine requires the previous cell to be width 2). After a
// letter the following wide emoji stands on its own.
#[test]
fn letter_followed_by_zwj_does_not_swallow_the_next_emoji() {
    let p = parse(40, &["a\u{200D}\u{1F466}X"]);
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().contents(), "a\u{200D}", "ZWJ folds into the letter");
    assert!(!s.cell(0, 0).unwrap().is_wide(), "the letter stays narrow");
    assert_eq!(s.cell(0, 1).unwrap().contents(), "\u{1F466}", "the boy gets its own cell");
    assert_eq!(s.cell(0, 3).unwrap().contents(), "X");
    assert_eq!(s.cursor_position().1, 4);
}

// A skin tone modifier with nothing before it is an ordinary wide emoji.
#[test]
fn modifier_with_nothing_before_it_is_a_wide_cell() {
    assert_eq!(cursor_col_after("\u{1F3FD}"), 2);
    let p = parse(40, &["\u{1F3FD}X"]);
    assert_eq!(p.screen().cell(0, 0).unwrap().contents(), "\u{1F3FD}");
    assert_eq!(p.screen().cell(0, 2).unwrap().contents(), "X");
}

// A modifier after a narrow letter does not combine: tmux only combines into
// a width 2 cell, so the modifier stands as its own wide emoji.
#[test]
fn modifier_after_a_letter_stands_alone() {
    assert_eq!(cursor_col_after("a\u{1F3FD}"), 3);
}

// Three regional indicators: the first two pair into a flag, the third does
// not join the flag (tmux utf8_should_combine refuses a third indicator when
// the cell already holds a pair).
#[test]
fn third_regional_indicator_starts_a_new_cell() {
    let p = parse(40, &["\u{1F1EF}\u{1F1F5}\u{1F1FA}"]);
    let s = p.screen();
    assert_eq!(s.cell(0, 0).unwrap().contents(), "\u{1F1EF}\u{1F1F5}");
    assert_eq!(s.cell(0, 2).unwrap().contents(), "\u{1F1FA}");
    assert_eq!(s.cursor_position().1, 4);
}

// A cluster longer than a cell can hold keeps the cell intact and the column
// count right: the extra code points are dropped from the cell rather than
// spilling into new cells, as tmux drops them when utf8_append would overflow
// UTF8_SIZE.
#[test]
fn cluster_longer_than_a_cell_stays_one_cell() {
    let long = format!("{FAMILY}\u{200D}{FAMILY}\u{200D}{FAMILY}");
    let p = parse(40, &[&format!("{long}X")]);
    let s = p.screen();
    assert!(s.cell(0, 0).unwrap().is_wide());
    assert!(s.cell(0, 0).unwrap().contents().starts_with('\u{1F468}'));
    assert_eq!(s.cell(0, 2).unwrap().contents(), "X", "X still lands on col 2");
    assert_eq!(s.cursor_position().1, 3);
}

// The cluster arrives with its first emoji on the last column: the wide base
// wraps to the next row and the rest of the cluster follows it there.
#[test]
fn cluster_at_the_last_column_wraps_whole() {
    let p = parse(5, &[&format!("abcd{FAMILY}X")]);
    let s = p.screen();
    assert_eq!(s.cell(1, 0).unwrap().contents(), FAMILY, "family wrapped whole");
    assert!(s.cell(1, 1).unwrap().is_wide_continuation());
    assert_eq!(s.cell(1, 2).unwrap().contents(), "X");
    assert_eq!(s.cursor_position(), (1, 3));
}

// Text extraction (capture-pane, copy mode) must reproduce the original
// bytes of a combined cell, not just its first code point.
#[test]
fn text_extraction_reproduces_the_cluster_bytes() {
    let row = format!("{FAMILY} \u{1F44D}\u{1F3FD} \u{1F1EF}\u{1F1F5} \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}!");
    let p = parse(40, &[&row]);
    let s = p.screen();
    assert_eq!(s.contents().trim_end(), row);
    assert_eq!(s.rows(0, 40).next().unwrap().trim_end(), row);
    // The 2 + 1 + 2 + 1 + 2 + 1 + 2 + 1 columns of the row.
    assert_eq!(s.cursor_position().1, 12);
    // A copy mode style range read over the family cell alone.
    assert_eq!(s.contents_between(0, 0, 0, 2), FAMILY);

    let formatted = s.contents_formatted();
    let mut p2 = vt100_psmux::Parser::new(4, 40, 0);
    p2.process(&formatted);
    assert_eq!(p2.screen().contents().trim_end(), row, "formatted replay");
    assert_eq!(p2.screen().cursor_position().1, 12);
}
