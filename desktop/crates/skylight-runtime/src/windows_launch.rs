//! Batch wrappers need a shell on Windows; CreateProcess cannot launch .cmd.
//! Keep native executables on the direct PTY path. Batch arguments with cmd.exe
//! metacharacters are rejected until that separate quoting contract is supported.
use anyhow::{bail, Result};
pub fn batch_script(program: &str, arguments: &[String]) -> Result<String> {
    for value in std::iter::once(program).chain(arguments.iter().map(String::as_str)) {
        if value.contains(['\r', '\n', '\0', '"', '&', '|', '<', '>', '^', '%', '!']) {
            bail!("This batch launcher contains shell metacharacters. Open a shell and run it there, or choose a native executable.");
        }
    }
    let quoted = |value: &str| format!("'{}'", value.replace('\'', "''"));
    let mut script = format!("& {}", quoted(program));
    for argument in arguments {
        script.push(' ');
        script.push_str(&quoted(argument));
    }
    script.push_str("; exit $LASTEXITCODE");
    Ok(script)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_and_spaces_remain_literal_powershell_values() {
        assert_eq!(
            batch_script("C:\\User Files\\cli.cmd", &["--model".into(), "a b".into()]).unwrap(),
            "& 'C:\\User Files\\cli.cmd' '--model' 'a b'; exit $LASTEXITCODE"
        );
    }
    #[test]
    fn ambiguous_cmd_metacharacters_require_the_shell() {
        for value in ["a&b", "%PATH%", "x|y", "a\"b"] {
            assert!(batch_script("cli.cmd", &[value.into()]).is_err());
        }
    }
}
