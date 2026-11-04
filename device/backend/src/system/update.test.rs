use super::*;

const MESSAGE: &[u8] = b"ystreamer update signature test";
/// Made with packaging/sign.sh and the release key
const SIGNATURE: &str =
    "OxHasJoikfV8ax1bSbkuiDJM+KOWrSwxhn6NFy0GUOe2HbVV7Vpint6C4rKqoMib5/c6HN2VTcjO5W7Ev09JDg==";

#[test]
fn release_key_accepts_what_sign_sh_signed() {
    assert_eq!(verify(PUBLIC_KEY, MESSAGE, SIGNATURE), Ok(()));
    assert_eq!(
        verify(PUBLIC_KEY, MESSAGE, &format!("{SIGNATURE}\n")),
        Ok(())
    );
}

#[test]
fn changed_package_is_refused() {
    assert!(verify(PUBLIC_KEY, b"ystreamer update signature tesT", SIGNATURE).is_err());
}

#[test]
fn signature_from_another_key_is_refused() {
    let other = "A".repeat(86) + "==";
    assert!(verify(PUBLIC_KEY, MESSAGE, &other).is_err());
}

#[test]
fn junk_signature_is_refused() {
    assert!(verify(PUBLIC_KEY, MESSAGE, "").is_err());
    assert!(verify(PUBLIC_KEY, MESSAGE, "not base64!").is_err());
    assert!(verify(PUBLIC_KEY, MESSAGE, "c2hvcnQ=").is_err());
}

#[test]
fn packaging_revision_is_dropped_from_the_version() {
    assert_eq!(display_version("0.1.0-1"), "0.1.0");
    assert_eq!(display_version("0.2.0"), "0.2.0");
}

#[test]
fn only_a_higher_version_is_newer() {
    assert!(is_newer("0.2.0", "0.1.0"));
    assert!(is_newer("0.10.0", "0.9.5"));
    assert!(is_newer("1.0.0.1", "1.0.0"));
    assert!(!is_newer("0.1.0", "0.1.0"));
    assert!(!is_newer("0.1.0", "0.2.0"));
    assert!(!is_newer("latest", "0.1.0"));
    assert!(!is_newer("", "0.1.0"));
}

#[test]
fn manifest_reads_without_notes() {
    let manifest: Manifest = serde_json::from_str(
        r#"{"version": "0.2.0", "packages": {"arm64": {"url": "https://example.com/a.deb", "signature": "c2ln"}}}"#,
    )
    .unwrap();
    assert_eq!(manifest.version, "0.2.0");
    assert_eq!(manifest.notes, "");
    assert_eq!(manifest.packages["arm64"].url, "https://example.com/a.deb");
}

/// The install script in a scratch folder, with apt-get, curl and sleep
/// replaced: `apt` is the exit code of each apt-get call in turn, `health`
/// what the device answers
fn run_script(name: &str, apt: &[u8], health: &str, before: &[(&str, &str)]) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;

    let dir = std::env::temp_dir().join(format!("ystreamer-update-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    for (file, contents) in before {
        fs::write(dir.join(file), contents).unwrap();
    }
    let codes: Vec<String> = apt.iter().map(u8::to_string).collect();
    fs::write(dir.join("apt-codes"), codes.join("\n") + "\n").unwrap();
    fs::write(dir.join("health"), health).unwrap();
    let stubs = [
        (
            "apt-get",
            "echo \"$@\" >>apt-calls\ncode=$(head -1 apt-codes); sed -i 1d apt-codes; exit ${code:-0}",
        ),
        ("curl", "cat health"),
        ("sleep", "true"),
    ];
    for (stub, body) in stubs {
        let path = bin.join(stub);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let keep =
        format!("[ ! -f {CURRENT} ] || mv -f {CURRENT} {PREVIOUS}; mv -f {STAGED} {CURRENT}");
    let status = std::process::Command::new("sh")
        .arg("-c")
        .arg(script(&dir.to_string_lossy(), STAGED, "0.2.0", 80, &keep))
        .current_dir(&dir)
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .status()
        .unwrap();
    assert!(status.success());
    dir
}

fn read(dir: &Path, name: &str) -> String {
    fs::read_to_string(dir.join(name))
        .unwrap_or_default()
        .trim()
        .to_string()
}

const RUNNING: &[(&str, &str)] = &[(STAGED, "new"), (CURRENT, "old")];

#[test]
fn version_that_answers_is_kept() {
    let dir = run_script("ok", &[0], r#"{"status":"ok","version":"0.2.0"}"#, RUNNING);
    assert_eq!(read(&dir, RESULT), "0");
    assert_eq!(read(&dir, CURRENT), "new");
    assert_eq!(read(&dir, PREVIOUS), "old");
    assert!(!dir.join(STAGED).exists());
    assert_eq!(read(&dir, "apt-calls").lines().count(), 1);
}

#[test]
fn version_that_never_answers_is_replaced_by_the_one_before() {
    let dir = run_script("silent", &[0, 0], "", RUNNING);
    assert_eq!(read(&dir, RESULT), REVERTED);
    assert_eq!(read(&dir, CURRENT), "old");
    assert_eq!(read(&dir, STAGED), "new");
    assert!(!dir.join(PREVIOUS).exists());
    let calls = read(&dir, "apt-calls");
    assert!(calls.lines().nth(1).unwrap().ends_with(CURRENT), "{calls}");
}

#[test]
fn old_version_still_answering_is_not_taken_for_the_new_one() {
    let dir = run_script(
        "stale",
        &[0, 0],
        r#"{"status":"ok","version":"0.1.0"}"#,
        RUNNING,
    );
    assert_eq!(read(&dir, RESULT), REVERTED);
}

#[test]
fn nothing_to_go_back_to_is_reported() {
    let dir = run_script("first", &[0], "", &[(STAGED, "new")]);
    assert_eq!(read(&dir, RESULT), UNANSWERED);
    assert_eq!(read(&dir, "apt-calls").lines().count(), 1);
}

#[test]
fn failed_install_changes_nothing() {
    let dir = run_script("failed", &[100, 0, 100], "", RUNNING);
    assert_eq!(read(&dir, RESULT), "100");
    assert_eq!(read(&dir, CURRENT), "old");
    assert_eq!(read(&dir, STAGED), "new");
    assert_eq!(read(&dir, "apt-calls").lines().count(), 3);
}

#[test]
fn missing_package_lists_are_fetched_and_the_install_retried() {
    let dir = run_script(
        "lists",
        &[100, 0, 0],
        r#"{"status":"ok","version":"0.2.0"}"#,
        RUNNING,
    );
    assert_eq!(read(&dir, RESULT), "0");
    assert_eq!(read(&dir, CURRENT), "new");
    let calls = read(&dir, "apt-calls");
    assert_eq!(calls.lines().nth(1), Some("update"), "{calls}");
    assert_eq!(calls.lines().count(), 3);
}

#[test]
fn install_script_checks_against_the_same_key() {
    let script = include_str!("../../../packaging/install.sh");
    assert!(script.contains(&format!("PUBLIC_KEY=\"{}\"", PUBLIC_KEY.trim())));
}

/// On the ROCK 3A, install.sh adds Radxa's repository for the video
/// packages; nothing else may come from it, or Radxa's kernel and system
/// packages could replace Armbian's
#[test]
fn install_script_takes_only_the_video_packages_from_radxa() {
    let script = include_str!("../../../packaging/install.sh");
    let packages = "librockchip-mpp1 librga2 gstreamer1.0-rockchip1";
    assert!(script.contains(&format!("ROCKCHIP_PACKAGES=\"{packages}\"")));
    assert!(script.contains(
        "Package: *\nPin: origin radxa-repo.github.io\nPin-Priority: -1\n\n\
         Package: $ROCKCHIP_PACKAGES\nPin: origin radxa-repo.github.io\nPin-Priority: 500\n"
    ));
    assert!(script.contains("RADXA_KEY=/etc/apt/keyrings/ystreamer-radxa.asc\n"));
    assert!(script.contains("Signed-By: $RADXA_KEY\n"));
    assert_eq!(
        script
            .matches("-----BEGIN PGP PUBLIC KEY BLOCK-----")
            .count(),
        1
    );
    assert_eq!(
        script.matches("-----END PGP PUBLIC KEY BLOCK-----").count(),
        1
    );
}

/// Armbian's wired port moves from systemd-networkd to NetworkManager at the
/// next boot. Until then NetworkManager, which the package pulls in, must
/// keep off it, or the SSH session running the install could drop
#[test]
fn install_script_hands_the_wired_port_over_at_the_next_boot() {
    let script = include_str!("../../../packaging/install.sh");
    assert!(script.contains("NETPLAN_ARMBIAN=/etc/netplan/10-dhcp-all-interfaces.yaml\n"));
    assert!(
        script.contains("HANDOVER_CONF=/run/NetworkManager/conf.d/90-ystreamer-handover.conf\n")
    );
    assert!(script.contains("[keyfile]\nunmanaged-devices=type:ethernet\n"));
    assert!(script.contains(
        "systemctl disable systemd-networkd.service systemd-networkd.socket \
         systemd-networkd-wait-online.service"
    ));
    // Nothing takes effect before the reboot, and the reboot is the user's
    assert!(!script.contains("netplan apply"));
    assert!(!script.contains("disable --now systemd-networkd"));
    assert!(!script.lines().any(|l| l.trim_start().starts_with("reboot")));
    let handover = script.find("\n    hand_over_network\n").expect("called");
    let package = script
        .find("apt-get install -y --allow-downgrades \"$DEB\"")
        .unwrap();
    assert!(handover < package);
}

#[test]
fn a_device_takes_the_package_for_its_architecture() {
    let manifest: Manifest = serde_json::from_str(
        r#"{"version": "0.2.0", "packages": {
            "arm64": {"url": "https://example.com/arm64.deb", "signature": "c2ln"}}}"#,
    )
    .unwrap();
    assert_eq!(
        pick_package(&manifest.packages, "arm64").map(|p| p.url.as_str()),
        Some("https://example.com/arm64.deb")
    );
    assert!(pick_package(&manifest.packages, "amd64").is_none());
}
