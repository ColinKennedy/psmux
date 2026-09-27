// Issue #704: the copy mode position indicator could not be hidden. There was
// no `toggle-position` command, `P` was not bound, and `copy-mode -H` parsed
// and then did nothing.
//
// tmux keeps one flag on the mode entry, flips it in
// `window_copy_cmd_toggle_position` (window-copy.c) and skips the draw on it in
// `window_copy_write_line` (`!data->hide_position`). `window_copy_init` reads
// it from `-H`, so the flag belongs to that entry and a later one starts
// showing the indicator again.
//
// What is pinned here is the part that needs no pty: the command's effect on
// the state, the state reaching the wire, and the client not drawing when it
// is set. Entering with `-H`, the `P` key and the flag surviving a pane switch
// are driven end to end in tests/test_issue704_toggle_position.ps1.

use super::*;
use crate::types::{AppState, Mode};

/// One window with one pane and a real vt100 parser, shared with the copy mode
/// snapshot tests so this file does not carry a second copy of the fixture.
fn app_with_pane() -> AppState {
    super::test_copy_mode_snapshot::app_with_pane()
}

fn parked_flag(app: &AppState) -> Option<bool> {
    let win = app.windows.get(app.active_idx)?;
    let pane = crate::tree::active_pane(&win.root, &win.active_path)?;
    pane.copy_state.as_ref().map(|s| s.hide_position)
}

#[test]
fn toggle_position_flips_the_flag() {
    let mut app = app_with_pane();
    crate::copy_mode::enter_copy_mode(&mut app);
    assert!(!app.copy_hide_position, "the indicator starts visible");
    crate::copy_mode::toggle_position(&mut app);
    assert!(app.copy_hide_position, "one press hides it");
    crate::copy_mode::toggle_position(&mut app);
    assert!(!app.copy_hide_position, "the next press shows it again");
}

#[test]
fn toggle_position_asks_for_a_frame() {
    // Nothing in the pane or the layout changes, so without this the client
    // keeps drawing the last frame it was sent. Measured on a key press before
    // the flag existed: the indicator took 2.6s and 3.8s to disappear, and
    // once was still on screen after ten seconds. tmux says the same thing by
    // returning `WINDOW_COPY_CMD_REDRAW`.
    let mut app = app_with_pane();
    crate::copy_mode::enter_copy_mode(&mut app);
    app.copy_needs_redraw = false;
    crate::copy_mode::toggle_position(&mut app);
    assert!(app.copy_needs_redraw, "the toggle has to ask for its own frame");
}

#[test]
fn the_flag_is_saved_on_the_pane() {
    // tmux keeps `hide_position` on the mode entry, which belongs to the pane,
    // so a pane parked in copy mode keeps its own answer.
    let mut app = app_with_pane();
    crate::copy_mode::enter_copy_mode(&mut app);
    assert_eq!(parked_flag(&app), Some(false));
    crate::copy_mode::toggle_position(&mut app);
    assert_eq!(parked_flag(&app), Some(true), "the pane carries the toggle");
}

#[test]
fn a_later_entry_shows_the_indicator_again() {
    // `window_copy_init` reads the flag from `-H` every time the mode is
    // created, so it does not survive leaving copy mode.
    let mut app = app_with_pane();
    crate::copy_mode::enter_copy_mode(&mut app);
    crate::copy_mode::toggle_position(&mut app);
    assert!(app.copy_hide_position);
    crate::copy_mode::exit_copy_mode(&mut app);
    crate::copy_mode::enter_copy_mode(&mut app);
    assert!(!app.copy_hide_position, "a fresh entry shows the indicator");
}

#[test]
fn copy_mode_dash_h_enters_hidden() {
    let mut app = app_with_pane();
    crate::copy_mode::enter_copy_mode_hidden(&mut app);
    assert!(matches!(app.mode, Mode::CopyMode), "it still enters copy mode");
    assert!(app.copy_hide_position, "-H starts with the indicator hidden");
    assert_eq!(parked_flag(&app), Some(true), "and the pane carries it");
}

#[test]
fn server_ships_the_flag_only_when_it_is_set() {
    let mut app = AppState::new("i704".to_string());
    app.mode = Mode::CopyMode;

    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    assert!(!buf.contains("copy_hide_position"),
        "an ordinary copy mode frame carries no extra bytes for it: {buf}");

    app.copy_hide_position = true;
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    let v: serde_json::Value = serde_json::from_str(&buf).expect("valid json");
    assert_eq!(v["copy_hide_position"], true);
}

#[test]
fn server_does_not_ship_the_flag_outside_copy_mode() {
    // A stale true must not reach a client that is not in copy mode at all.
    let mut app = AppState::new("i704".to_string());
    app.copy_hide_position = true;
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    assert_eq!(buf, "{\"x\":1}", "nothing is appended outside copy mode");

    // With the gutter on, the line number fields still ship and the hidden
    // flag still does not, because the pane is not in copy mode.
    app.user_options.insert("copy-mode-line-numbers".to_string(), "absolute".to_string());
    let mut buf = String::from("{\"x\":1}");
    crate::server::helpers::append_copy_ln_json(&app, &mut buf);
    let v: serde_json::Value = serde_json::from_str(&buf).expect("valid json");
    assert_eq!(v["copy_mode_line_numbers"], "absolute");
    assert!(!buf.contains("copy_hide_position"), "{buf}");
}

/// Render one copy-mode leaf through the real client and return the row the
/// indicator is drawn on, which is the one under the `[copy mode]` label.
fn indicator_row(hide_position: bool) -> String {
    use crate::client::CopyLnRender;
    use crate::layout::{CellJson, LayoutJson};
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;
    use ratatui::style::{Color, Style};
    use ratatui::Terminal;

    let (w, h) = (60u16, 30u16);
    let cell = |ch: char| CellJson {
        text: ch.to_string(), fg: String::new(), bg: String::new(),
        bold: false, italic: false, underline: false, inverse: false,
        dim: false, blink: false, hidden: false, strikethrough: false,
    };
    let content: Vec<Vec<CellJson>> = (0..h).map(|_| (0..w).map(|_| cell('X')).collect()).collect();
    let leaf = LayoutJson::Leaf {
        id: 0, rows: h, cols: w, cursor_row: 0, cursor_col: 0,
        alternate_screen: false, wants_mouse: false, hide_cursor: true, cursor_shape: 0,
        active: true, copy_mode: true, scroll_offset: 68, view_offset: 68,
        sel_start_row: None, sel_start_col: None, sel_end_row: None, sel_end_col: None,
        sel_mode: None, copy_cursor_row: Some(0), copy_cursor_col: Some(0),
        content, rows_v2: Vec::new(), title: None,
    };
    let copy_ln = Some(CopyLnRender {
        mode: crate::copy_line_numbers::CopyLnMode::Off,
        hsize: 173,
        hide_position,
        num_style: Style::default().fg(Color::DarkGray),
        cur_style: Style::default().fg(Color::Yellow),
    });
    let backend = TestBackend::new(w, h);
    let mut term = Terminal::new(backend).unwrap();
    term.draw(|f| {
        let area = Rect::new(0, 0, w, h);
        let active_rect = crate::client::compute_active_rect_json(&leaf, area);
        crate::client::render_layout_json(
            f, &leaf, area, false,
            Style::default().fg(Color::DarkGray),
            Style::default().fg(Color::Green),
            false, Color::Reset, active_rect, "", false, "off", "", 1,
            crate::border_lines::border_chars("single"), copy_ln,
            crate::client::WindowContentStyles::default(),
            crate::pane_border::PaneBorderIndicators::Colour,
        );
    }).unwrap();
    let buf = term.backend().buffer().clone();
    let aw = buf.area.width as usize;
    (0..aw).map(|c| buf.content[aw + c].symbol().chars().next().unwrap_or(' ')).collect()
}

#[test]
fn the_client_draws_the_indicator_when_the_flag_is_clear() {
    let row = indicator_row(false);
    assert!(row.contains("[68/173]"), "row was {row:?}");
}

#[test]
fn the_client_draws_nothing_when_the_flag_is_set() {
    let row = indicator_row(true);
    assert!(!row.contains('['), "the indicator must be gone, row was {row:?}");
    assert!(!row.contains('/'), "row was {row:?}");
}
