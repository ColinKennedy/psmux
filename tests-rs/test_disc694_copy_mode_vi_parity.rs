// Discussion #694: tanaeakihiko's audit of the 51 default copy-mode-vi keys
// against tmux. Each section below pins one of the differences it found.

use super::*;
use super::test_copy_mode_snapshot::{app_with_pane, feed, filled, parked_live_term, view_term};

fn scroll(app: &AppState) -> usize {
    view_term(app).lock().map(|p| p.screen().scrollback()).unwrap_or(0)
}

// ── 3. refresh-from-pane ────────────────────────────────────────────────────
//
// Measured on dd695ea with a printer ticking every 400 ms: the drawn screen
// stayed on `tick 12` while the pane reached `tick 28` after `r`, and `r` only
// reset the scroll offset to 0. `r` flipped the #494 freeze off, which stopped
// meaning anything once copy mode moved onto a snapshot (d74f52a).

#[test]
fn refresh_from_pane_brings_new_output_into_the_snapshot() {
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "old", 0, 100);
    crate::copy_mode::enter_copy_mode(&mut app);
    let before = filled(&view_term(&app));

    feed(&live, "tick", 0, 10);
    assert_eq!(filled(&view_term(&app)), before, "the snapshot holds still while the pane prints");

    crate::copy_mode::refresh_from_pane(&mut app);

    assert_eq!(filled(&view_term(&app)), before + 10, "r must copy the new lines in");
    let parked = parked_live_term(&app).expect("still in copy mode on a snapshot");
    assert!(std::sync::Arc::ptr_eq(&parked, &live), "the live parser stays the one the reader feeds");
    assert!(!std::sync::Arc::ptr_eq(&view_term(&app), &live), "copy mode still reads a snapshot");
}

#[test]
fn refresh_from_pane_keeps_the_line_at_the_top_of_the_view() {
    // tmux 3.7 keeps `oy_from_top` (window-copy.c): the reader stays on the
    // same lines and the new output lands underneath.
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "old", 0, 200);
    crate::copy_mode::enter_copy_mode(&mut app);
    crate::copy_mode::scroll_copy_up(&mut app, 30);
    assert_eq!(app.copy_scroll_offset, 30);

    feed(&live, "tick", 0, 8);
    crate::copy_mode::refresh_from_pane(&mut app);

    assert_eq!(app.copy_scroll_offset, 38, "8 new lines underneath push the offset by 8");
    assert_eq!(scroll(&app), 38, "the snapshot parser holds the same offset");
}

#[test]
fn scrolling_still_works_after_refresh_from_pane() {
    // The old toggle left scrolling nearly dead: 20 presses of cursor-up moved
    // the offset by one.
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "old", 0, 200);
    crate::copy_mode::enter_copy_mode(&mut app);
    feed(&live, "tick", 0, 5);
    crate::copy_mode::refresh_from_pane(&mut app);
    let at = app.copy_scroll_offset;
    crate::copy_mode::scroll_copy_up(&mut app, 20);
    assert_eq!(app.copy_scroll_offset, at + 20);
}

#[test]
fn refresh_from_pane_clears_the_selection_and_stays_in_copy_mode() {
    // window_copy_size_changed runs window_copy_clear_selection after the
    // re-clone; measured in tmux 3.4: selection_present 1 -> 0, in_mode 1.
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "old", 0, 60);
    crate::copy_mode::enter_copy_mode(&mut app);
    app.copy_anchor = Some((3, 0));
    crate::copy_mode::refresh_from_pane(&mut app);
    assert!(app.copy_anchor.is_none());
    assert!(matches!(app.mode, Mode::CopyMode));
}

#[test]
fn refreshed_offset_follows_tmux_3_7() {
    // Same line on top: 100 lines of history at offset 0, 8 more arrive.
    assert_eq!(crate::copy_mode::refreshed_offset(100, 0, 108), (8, false));
    // Scrolled 30 up.
    assert_eq!(crate::copy_mode::refreshed_offset(100, 30, 108), (38, false));
    // The line on top was evicted: park on the oldest line.
    assert_eq!(crate::copy_mode::refreshed_offset(100, 90, 5), (5, true));
    // An offset past the history is clamped first, as tmux clamps oy.
    assert_eq!(crate::copy_mode::refreshed_offset(100, 500, 100), (100, false));
}

#[test]
fn refresh_toggle_follows_output_only_at_the_bottom() {
    // tmux after 3.7c: refresh-on rebuilds on a timer and follows new output
    // while the cursor is on the last row at offset 0.
    let mut app = app_with_pane();
    let live = view_term(&app);
    feed(&live, "old", 0, 100);
    crate::copy_mode::enter_copy_mode(&mut app);
    let rows = pane_of_rows(&app);
    app.copy_pos = Some((rows - 1, 0));
    crate::copy_mode::toggle_refresh(&mut app);
    assert!(app.copy_refresh_live);

    feed(&live, "tick", 0, 6);
    bump_version(&app);
    assert!(crate::copy_mode::tick_auto_refresh(&mut app));
    assert_eq!(app.copy_scroll_offset, 0, "at the bottom the view follows");
    assert_eq!(filled(&view_term(&app)), filled(&live));

    // Scrolled up, a refresh keeps the place instead.
    crate::copy_mode::scroll_copy_up(&mut app, 10);
    feed(&live, "tick", 6, 9);
    bump_version(&app);
    app.copy_refresh_at = None;
    assert!(crate::copy_mode::tick_auto_refresh(&mut app));
    assert_eq!(app.copy_scroll_offset, 13);

    // A selection pauses it.
    app.copy_anchor = Some((0, 0));
    feed(&live, "tick", 9, 12);
    bump_version(&app);
    app.copy_refresh_at = None;
    assert!(!crate::copy_mode::tick_auto_refresh(&mut app));

    crate::copy_mode::toggle_refresh(&mut app);
    assert!(!app.copy_refresh_live);
}

fn pane_of_rows(app: &AppState) -> u16 {
    super::test_copy_mode_snapshot::pane_of(app).map(|p| p.last_rows).unwrap_or(24)
}

fn bump_version(app: &AppState) {
    if let Some(p) = super::test_copy_mode_snapshot::pane_of(app) {
        p.data_version.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

// ── 1. clear-selection on Escape ────────────────────────────────────────────
//
// Measured on dd695ea with real keystrokes: Space lll then Escape gave
// pane_in_mode 0. tmux binds Escape to clear-selection in copy-mode-vi
// (key-bindings.c:654) and to cancel in copy-mode (:577).

fn vi_app_with_selection() -> AppState {
    let mut app = app_with_pane();
    feed(&view_term(&app), "row", 0, 60);
    app.mode_keys = "vi".to_string();
    crate::copy_mode::enter_copy_mode(&mut app);
    app.copy_pos = Some((10, 2));
    crate::input::send_key_to_active(&mut app, "space").unwrap();
    crate::input::send_text_to_active(&mut app, "lll").unwrap();
    assert!(app.copy_anchor.is_some(), "Space starts a selection");
    app
}

#[test]
fn escape_clears_the_selection_and_stays_in_copy_mode_in_vi() {
    let mut app = vi_app_with_selection();
    crate::input::send_key_to_active(&mut app, "esc").unwrap();
    assert!(app.copy_anchor.is_none(), "Escape drops the selection");
    assert!(matches!(app.mode, Mode::CopyMode), "and copy mode stays up");
    // With nothing selected it does nothing: tmux 3.4 keeps pane_in_mode 1.
    crate::input::send_key_to_active(&mut app, "esc").unwrap();
    assert!(matches!(app.mode, Mode::CopyMode));
    // q is the key that leaves.
    crate::input::send_text_to_active(&mut app, "q").unwrap();
    assert!(!app.mode.in_copy());
}

#[test]
fn escape_as_text_clears_the_selection_in_vi() {
    let mut app = vi_app_with_selection();
    crate::input::send_text_to_active(&mut app, "\x1b").unwrap();
    assert!(app.copy_anchor.is_none());
    assert!(matches!(app.mode, Mode::CopyMode));
}

#[test]
fn escape_still_cancels_with_emacs_keys() {
    let mut app = vi_app_with_selection();
    app.mode_keys = "emacs".to_string();
    crate::input::send_key_to_active(&mut app, "esc").unwrap();
    assert!(!app.mode.in_copy(), "copy-mode binds Escape to cancel");
}

#[test]
fn clear_selection_keeps_the_rectangle_flag() {
    // tmux's window_copy_clear_selection leaves rectflag alone.
    let mut app = vi_app_with_selection();
    crate::copy_mode::toggle_rectangle(&mut app);
    crate::copy_mode::clear_selection(&mut app);
    assert_eq!(app.copy_selection_mode, crate::types::SelectionMode::Rect);
}
