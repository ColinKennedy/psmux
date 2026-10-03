// Issue #732: with `copy-mode-line-numbers` on, a mouse click or drag in copy
// mode lands on a cell to the RIGHT of the pointer, by the width of the line
// number gutter.
//
// The gutter is drawn by pushing the pane content right and clipping the last
// columns, so a content column `cx` is painted at view column `gutter + cx`.
// psmux applied that shift when it placed the copy cursor (client.rs) and
// never applied its inverse to a pointer column, so every mouse position in
// copy mode was read as a content column while it carried a view column.
//
// tmux keeps both directions and runs the pointer column through the inverse
// at all three of its mouse entry points, `window_copy_move_mouse`,
// `window_copy_start_drag` and `window_copy_drag_update` (window-copy.c, tag
// 3.7c `e476c123`):
//
//     static u_int
//     window_copy_cursor_offset(struct window_mode_entry *wme, u_int cx,
//         u_int sx)
//     static u_int
//     window_copy_cursor_unoffset(struct window_mode_entry *wme, u_int vx,
//         u_int sx)
//
// These tests pin the pair on both of psmux's mouse routes: `pane-mouse`,
// where the attached client sends pane relative coordinates, and the raw
// `mouse-down` / `mouse-drag` / `mouse-up` verbs, which carry screen
// coordinates.

use crate::types::{AppState, Mode, Node};
use ratatui::layout::Rect;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::{handle_pane_mouse, remote_mouse_down, remote_mouse_drag, remote_mouse_up};

const ROWS: u16 = 8;
const COLS: u16 = 40;
const AREA: Rect = Rect { x: 0, y: 0, width: COLS, height: ROWS };
/// The alphabet is written to the pane's first row, so content column N holds
/// the Nth letter and a selection reads back as the letters it covered.
const LETTERS: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
/// `gutter_width` for this pane: 8 rows and no history is under 10 lines, so
/// the number takes the 3 column minimum, plus 1 for the separating space.
const GUTTER: u16 = 4;

fn make_pane(id: usize) -> crate::types::Pane {
    let size = portable_pty::PtySize { rows: ROWS, cols: COLS, pixel_width: 0, pixel_height: 0 };
    let (master, writer) = crate::util::stub_pane_pty(size);
    let child = crate::util::StubChild::exited();
    let term = Arc::new(Mutex::new(vt100::Parser::new(ROWS, COLS, 0)));
    term.lock().expect("term lock").process(LETTERS.as_bytes());
    let epoch = Instant::now() - Duration::from_secs(2);
    crate::types::Pane {
        master,
        writer,
        child,
        term,
        last_rows: ROWS,
        last_cols: COLS,
        id,
        title: format!("pane{id}"),
        title_locked: false,
        child_pid: None,
        data_version: Arc::new(AtomicU64::new(0)),
        last_title_check: epoch,
        last_infer_title: epoch,
        dead: false,
        last_text_input: None,
        last_special_key: None,
        vt_bridge_cache: None,
        vti_mode_cache: None,
        mouse_input_cache: None,
        win32_input_latched: false,
        scroll_fg_cache: None,
        mouse_proto_owner: None,
        wheel_auth: None,
        cursor_shape: Arc::new(AtomicU8::new(0)),
        bell_pending: Arc::new(AtomicBool::new(false)),
        cpr_pending: Arc::new(AtomicBool::new(false)),
        color_query_pending: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        copy_state: None,
        live_term: None,
        pane_style: None,
        pane_options: Default::default(),
        squelch_until: None,
        output_ring: Arc::new(Mutex::new(std::collections::VecDeque::new())),
        spawned_at: None,
        start_command: String::new(),
        cwd_hint: None,
    }
}

/// One full-window pane holding the alphabet, in copy mode, with
/// `copy-mode-line-numbers` set to `mode`.
fn app_with(mode: &str) -> AppState {
    let mut app = AppState::new("issue732".to_string());
    app.mouse_enabled = true;
    app.last_window_area = AREA;
    if mode != "off" {
        app.user_options.insert("copy-mode-line-numbers".into(), mode.into());
    }
    app.windows.push(crate::types::Window {
        root: Node::Leaf(make_pane(41)),
        active_path: vec![],
        name: "w0".to_string(),
        id: 0,
        area: AREA,
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![41],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    });
    app.active_idx = 0;
    crate::copy_mode::enter_copy_mode(&mut app);
    app
}

/// The content column a press at view column `vx` selects.
fn pressed_column(mode: &str, vx: i16) -> u16 {
    let mut app = app_with(mode);
    handle_pane_mouse(&mut app, 41, 0, vx, 0, true);
    app.copy_pos.expect("a press positions the copy cursor").1
}

// The gutter width itself.

#[test]
fn the_gutter_is_only_as_wide_as_the_option_asks_for() {
    assert_eq!(crate::copy_mode::active_gutter_width(&app_with("off")), 0);
    for mode in ["default", "absolute", "relative", "hybrid"] {
        assert_eq!(
            crate::copy_mode::active_gutter_width(&app_with(mode)),
            GUTTER as usize,
            "mode {}",
            mode
        );
    }
}

// The pane-mouse route, which is what an attached client sends.

#[test]
fn a_press_selects_the_cell_under_the_pointer() {
    // Without a gutter the view column IS the content column.
    assert_eq!(pressed_column("off", 7), 7);
    // With one, the same letter is 4 columns further right on screen, and the
    // press has to come back to the content column it is drawn from.
    for mode in ["default", "absolute", "relative", "hybrid"] {
        assert_eq!(
            pressed_column(mode, 7 + GUTTER as i16),
            7,
            "mode {} must select the column under the pointer",
            mode
        );
    }
}

#[test]
fn a_press_on_the_gutter_itself_selects_the_first_column() {
    for vx in 0..GUTTER as i16 {
        assert_eq!(pressed_column("absolute", vx), 0, "view column {}", vx);
    }
}

#[test]
fn a_press_on_the_last_column_selects_the_last_visible_one() {
    // 40 columns behind a 4 wide gutter show 36 of content, so the rightmost
    // cell on screen is content column 35.
    assert_eq!(pressed_column("absolute", COLS as i16 - 1), COLS - GUTTER - 1);
    // The client reports a drag past the pane unclamped; it still cannot
    // reach past the last visible column.
    assert_eq!(pressed_column("absolute", COLS as i16 + 10), COLS - GUTTER - 1);
}

#[test]
fn a_drag_yanks_the_letters_the_pointer_covered() {
    // Drag over C to F (content columns 2 to 5) with the gutter off, then the
    // same four letters with the gutter on, which is 4 columns further right.
    let mut plain = app_with("off");
    handle_pane_mouse(&mut plain, 41, 0, 2, 0, true);
    handle_pane_mouse(&mut plain, 41, 32, 5, 0, true);
    handle_pane_mouse(&mut plain, 41, 0, 5, 0, false);
    assert_eq!(plain.paste_buffers.first().map(String::as_str), Some("CDEF"));

    let mut numbered = app_with("absolute");
    handle_pane_mouse(&mut numbered, 41, 0, 2 + GUTTER as i16, 0, true);
    handle_pane_mouse(&mut numbered, 41, 32, 5 + GUTTER as i16, 0, true);
    handle_pane_mouse(&mut numbered, 41, 0, 5 + GUTTER as i16, 0, false);
    assert_eq!(
        numbered.paste_buffers.first().map(String::as_str),
        Some("CDEF"),
        "the gutter must not shift what a drag copies"
    );
}

// The raw screen coordinate route.

#[test]
fn the_raw_verbs_take_the_gutter_off_too() {
    // `mouse-down X Y` carries a screen column, and this window starts at
    // column 0, so the pane's view column and the screen column are the same.
    let mut app = app_with("absolute");
    remote_mouse_down(&mut app, 2 + GUTTER, 0);
    assert_eq!(app.copy_pos, Some((0, 2)));
    remote_mouse_drag(&mut app, 5 + GUTTER, 0);
    assert_eq!(app.copy_pos, Some((0, 5)));
    remote_mouse_up(&mut app, 5 + GUTTER, 0);
    assert_eq!(app.paste_buffers.first().map(String::as_str), Some("CDEF"));
    assert!(matches!(app.mode, Mode::Passthrough), "a mouse yank leaves copy mode");
}

#[test]
fn the_raw_verbs_are_unchanged_without_a_gutter() {
    let mut app = app_with("off");
    remote_mouse_down(&mut app, 2, 0);
    assert_eq!(app.copy_pos, Some((0, 2)));
    remote_mouse_drag(&mut app, 5, 0);
    assert_eq!(app.copy_pos, Some((0, 5)));
    remote_mouse_up(&mut app, 5, 0);
    assert_eq!(app.paste_buffers.first().map(String::as_str), Some("CDEF"));
}
