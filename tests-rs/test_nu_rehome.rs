// Nushell as `default-shell` is documented in docs/multi-shell.md
// (`set -g default-shell nu`), but `rehome_syntax_for_stem` did not know the
// `nu` stem, so an unrecognised shell kept the Windows platform default
// dialect — PowerShell — and every pane with a start directory typed this
// into nushell:
//
//     cd 'C:\code'; try { [System.IO.Directory]::SetCurrentDirectory($PWD.ProviderPath) } catch {}; cls
//     Error: nu::parser::env_var_not_var — Use $env.PWD instead of $PWD.
//
// The parse error also meant the `cd` never executed, so the pane stayed in
// the directory it was spawned in (#600's twin symptom).
//
// Nushell cannot simply join the POSIX dialect because its string rules
// differ from every other shell family:
//   * single quotes are fully literal and NOTHING escapes a quote inside
//     them: '' doubling keeps both characters, \' closes the string;
//   * double quotes DO escape (\\ \" \$) and interpolate ($ and $());
//   * `;` chains and `clear` clears, like POSIX shells.
//
// These tests pin the dialect selection and the exact wire forms, mirroring
// tests-rs/test_issue600_bash_rehome.rs.

use super::*;

// ─────────────────────────── dialect selection ───────────────────────────

/// `set -g default-shell nu` (the documented spelling), the .exe spelling,
/// full paths in either slash style, and the `nushell` package name must all
/// select the Nu dialect — never the PowerShell platform default.
#[test]
fn nushell_default_shell_selects_nu() {
    for shell in [
        "nu",
        "nu.exe",
        r"C:\ProgramData\chocolatey\bin\nu.exe",
        "C:/Program Files/nushell/bin/nu.exe",
        "nushell",
        "/usr/bin/nu",
    ] {
        assert_eq!(
            rehome_syntax_for_shell(shell),
            RehomeSyntax::Nu,
            "{shell} must be treated as Nushell, not the platform default"
        );
    }
}

/// `default-shell` may carry arguments; the dialect must come from the
/// program, not from the whole string.
#[test]
fn nushell_with_arguments_resolves_the_program() {
    assert_eq!(rehome_syntax_for_shell("nu -l"), RehomeSyntax::Nu);
    assert_eq!(rehome_syntax_for_shell("nu.exe --config C:/x/config.nu"), RehomeSyntax::Nu);
}

// ────────────────────────────── wire forms ───────────────────────────────

/// Exact Nushell wire form for an ordinary path: single quotes (fully
/// literal, so no escaping can go wrong), forward separators on Windows,
/// `clear` to hide the echo. It must contain no PowerShell tokens at all —
/// `$PWD`, `try`, braces and parens are exactly what nushell choked on.
#[test]
fn nu_rehome_exact_form_has_no_powershell_tokens() {
    let cmd = rehome_command(r"C:\code\project", RehomeSyntax::Nu);
    if cfg!(windows) {
        assert_eq!(cmd, " cd 'C:/code/project'; clear\r");
    } else {
        assert_eq!(cmd, " cd 'C:\\code\\project'; clear\r");
    }
    assert!(!cmd.contains("SetCurrentDirectory"), "the .NET sync is PowerShell-only, got {cmd:?}");
    assert!(!cmd.contains("$PWD"), "the PowerShell automatic variable, got {cmd:?}");
    for tok in ['(', ')', '{', '}'] {
        assert!(!cmd.contains(tok), "Nu form must not contain {tok:?}, got {cmd:?}");
    }
    assert!(cmd.starts_with(' '), "must start with a space, got {cmd:?}");
    assert_eq!(cmd.matches('\r').count(), 1, "exactly one submitted line, got {cmd:?}");
    assert!(cmd.ends_with("; clear\r"), "must chain a clear to hide the echo, got {cmd:?}");
}

/// Windows separators are normalised exactly like the POSIX form: `cd`
/// accepts forward slashes and a backslash would only invite confusion.
#[test]
fn nu_rehome_normalises_windows_separators() {
    let cmd = rehome_command(r"C:\Users\UserName1\My Code", RehomeSyntax::Nu);
    if cfg!(windows) {
        assert!(cmd.contains("cd 'C:/Users/UserName1/My Code'"), "got {cmd:?}");
        assert!(!cmd.contains('\\'), "no backslash may survive on Windows, got {cmd:?}");
    } else {
        assert!(cmd.contains(r"cd 'C:\Users\UserName1\My Code'"), "got {cmd:?}");
    }
}

/// The apostrophe fallback. Nushell single quotes cannot hold a quote by any
/// spelling, and Windows paths may legally contain apostrophes, so such a
/// path switches to double quotes — where the apostrophe needs no escape —
/// instead of producing a string that closes early and a parse error.
#[test]
fn nu_rehome_apostrophe_switches_to_double_quotes() {
    let cmd = rehome_command(r"C:\code\weird's dir", RehomeSyntax::Nu);
    if cfg!(windows) {
        assert_eq!(cmd, " cd \"C:/code/weird's dir\"; clear\r");
    } else {
        assert_eq!(cmd, " cd \"C:\\code\\weird's dir\"; clear\r");
    }
    assert_eq!(cmd.matches('\r').count(), 1, "exactly one submitted line, got {cmd:?}");
}

/// The double-quoted fallback must escape the characters nushell double
/// quotes treat specially: backslash, double quote (never legal in a Windows
/// path, but the form must stay well-formed regardless), and dollar (the
/// interpolation introducer).
#[test]
fn nu_rehome_double_quote_fallback_escapes_metacharacters() {
    // No Windows separator in the input, so the expectation is the same on
    // every platform.
    let cmd = rehome_command("/tmp/weird's $dir", RehomeSyntax::Nu);
    assert_eq!(cmd, " cd \"/tmp/weird's \\$dir\"; clear\r");
    assert_eq!(cmd.matches('\r').count(), 1, "exactly one submitted line, got {cmd:?}");
}
