// Adapted from Aussiemon's patch_bundle_database-dt.js

//#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;

mod xbox_game_pass;

const BUNDLE_DATABASE_NAME: &'static str = "bundle_database.data";
const BUNDLE_DATABASE_BACKUP: &'static str = "bundle_database.data.bak";
const BOOT_BUNDLE_NEXT_PATCH: &'static str = "9ba626afa44a3aa3.patch_001";
const MOD_PATCH_STARTING_POINT: [u8; 8] = u64::to_be_bytes(0xA33A4AA4AF26A69B);

const OLD_SIZE: usize = 84;
const MOD_PATCH: &[u8] = include_bytes!("./patch.bin");

fn main() -> io::Result<()> {
    let args = env::args_os().collect::<Vec<_>>();

    if let Some(option) = args.get(1) {
        let option = option.to_str();
        match option {
            Some("--patch"
            | "--unpatch"
            | "--toggle") => {
                let bundle_dir = if let Some(path) = args.get(2).map(PathBuf::from) {
                    path
                } else {
                    darktide_dir()?
                };

                match option {
                    Some("--patch")   => patch_darktide(bundle_dir, false)?,
                    Some("--unpatch") => unpatch_darktide(bundle_dir)?,
                    Some("--toggle")  => if let Err(e) = patch_darktide(bundle_dir, true) {
                        patch_failed(&e);
                        return Err(e);
                    }
                    _ => unreachable!(),
                }
            }
            Some("--meta") => {
                let steam = match steam_find::get_steam_app(1361210).map(|app| app.path) {
                    Ok(path) => format!("{:?}", path.display()),
                    Err(_) => String::from("null"),
                };
                let gamepass = match xbox_game_pass::find_darktide() {
                    Ok(path) => format!("{:?}", path.display()),
                    Err(_) => String::from("null"),
                };
                println!("{{");
                println!("  \"steam\": {steam},", );
                println!("  \"xbox_game_pass\": {gamepass}" );
                println!("}}");
            }
            _ => {
                eprintln!("{} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
                eprintln!("{}", env!("CARGO_PKG_REPOSITORY"));
                eprintln!();
                eprintln!("dtkit-patch patches Darktide to load the mod entry bundle.");
                eprintln!();
                eprintln!("If no option is used then dtkit-patch will patch sliently or prompt user to");
                eprintln!("unpatch if Darktide is already patched.");
                eprintln!();
                eprintln!("USAGE:");
                eprintln!("dtkit-patch <OPTION>");
                eprintln!();
                eprintln!("OPTIONS:");
                eprintln!("  --patch [DIR]   Patch database.");
                eprintln!("  --unpatch [DIR] Unpatch database.");
                eprintln!("  --toggle [DIR]  Toggle patch/unpatch on database.");
                eprintln!("  --meta          Print detected paths in JSON.");
            }
        }
    } else {
        let bundle_dir = if let Some(path) = args.get(2).map(PathBuf::from) {
            path
        } else {
            darktide_dir()?
        };

        if let Err(e) = patch_darktide(bundle_dir, true) {
            patch_failed(&e);
            return Err(e);
        }
    }

    Ok(())
}

fn darktide_dir() -> io::Result<PathBuf> {
    let steam = steam_find::get_steam_app(1361210).map(|app| app.path.join("bundle"));
    let xbox_game_pass = xbox_game_pass::find_darktide().map(|path| path.join("Content/bundle"));

    if steam.is_err() && xbox_game_pass.is_err() {
        Err(io::Error::new(io::ErrorKind::NotFound, "Darktide not automatically found for Steam or Xbox Game Pass install"))
    } else if steam.is_ok() && xbox_game_pass.is_ok() {
        let steam = steam.unwrap();
        let xbox_game_pass = xbox_game_pass.unwrap();

        // if both copies of Darktide are found then do comparison with
        // current directory to determine which path should be used.
        if let Ok(current_dir) = env::current_dir() {
            let Ok(s) = steam.parent().unwrap().canonicalize() else {
                return Ok(xbox_game_pass);
            };
            let Ok(xgp) = xbox_game_pass.parent().unwrap().canonicalize() else {
                return Ok(steam);
            };
            let Ok(current_dir) = current_dir.canonicalize() else {
                return Ok(steam);
            };

            if current_dir.starts_with(s) {
                Ok(steam)
            } else if current_dir.starts_with(xgp) {
                Ok(xbox_game_pass)
            } else {
                Ok(steam)
            }
        } else {
            Ok(steam)
        }
    } else {
        steam.or(xbox_game_pass)
    }
}

fn patch_darktide(bundle_dir: PathBuf, interactive_mode: bool) -> io::Result<()> {
    let db_path = bundle_dir.join(BUNDLE_DATABASE_NAME);
    let mut db = match fs::read(&db_path) {
        Ok(db) => db,
        Err(e) => {
            eprintln!("failed to read {BUNDLE_DATABASE_NAME:?}");
            return Err(e);
        }
    };

    // check if already patched for mods
    let mod_patch_match = b"patch_999";
    if bytes_check(&db, mod_patch_match).is_some() {
        if interactive_mode && ask_unpatch() {
            unpatch_darktide(bundle_dir)?;
        } else {
            eprintln!("{BUNDLE_DATABASE_NAME:?} already patched");
        }
        return Ok(());
    }

    // check for unhandled bundle patch
    if bytes_check(&db, BOOT_BUNDLE_NEXT_PATCH.as_bytes()).is_some() {
        return Err(io::Error::new(io::ErrorKind::Unsupported,
            "unexpected data in \"bundle_database.data\""));
    }

    // look for patch offset
    let Some(offset) = bytes_check(&db, &MOD_PATCH_STARTING_POINT) else {
        return Err(io::Error::new(io::ErrorKind::Unsupported,
            "could not find patch offset in \"bundle_database.data\""));
    };

    // write backup
    if let Err(e) = fs::write(bundle_dir.join(BUNDLE_DATABASE_BACKUP), &db) {
        eprintln!("failed to backup \"bundle_database.data\" to \"bundle_database.data.bak\"");
        return Err(e);
    }

    // insert data
    let _ = db.splice(offset..offset + OLD_SIZE, MOD_PATCH.iter().map(|b| *b));

    // write patched database
    if let Err(e) = fs::write(&db_path, &db) {
        eprintln!("failed to write patched \"bundle_database.data\"");
        return Err(e);
    }

    eprintln!("successfully patched {BUNDLE_DATABASE_NAME:?}");

    if interactive_mode {
        patch_successful();
    }

    Ok(())
}

fn unpatch_darktide(bundle_dir: PathBuf) -> io::Result<()> {
    let db_path = bundle_dir.join(BUNDLE_DATABASE_NAME);
    let backup_path = bundle_dir.join(BUNDLE_DATABASE_BACKUP);

    // overwrite patched database with backup database
    match fs::rename(backup_path, db_path) {
        Err(e) => {
            if e.kind() == io::ErrorKind::NotFound {
                eprintln!("backup \"bundle_database.data.bak\" not found");
            }
            return Err(e);
        }
        _ => eprintln!("successfully unpatched {BUNDLE_DATABASE_NAME:?}"),
    }
    Ok(())
}

// helper function to check for slice matches
fn bytes_check(bytes: &[u8], check: &[u8]) -> Option<usize> {
    for (i, window) in bytes.windows(check.len()).enumerate() {
        if window == check {
            return Some(i);
        }
    }
    None
}

#[cfg(windows)]
fn ask_unpatch() -> bool {
    open_prompt(
        "Darktide is already patched.\r\nWould you like to remove the patch?\0",
        false,
        false,
    )
}

#[cfg(not(windows))]
fn ask_unpatch() -> bool { false }

#[cfg(windows)]
fn patch_successful() {
    open_prompt(
        "Darktide is now patched to load mods.\0",
        true,
        false,
    );
}

#[cfg(not(windows))]
fn patch_successful() {}

#[cfg(windows)]
fn patch_failed(error: &io::Error) {
    let msg = format!("dtkit-patch failed to patch Darktide:\n\n{error}\0");
    open_prompt(
        &msg,
        true,
        true,
    );
}

#[cfg(not(windows))]
fn patch_failed(_error: &io::Error) {}

#[cfg(windows)]
fn open_prompt(text: &str, single_button: bool, is_error: bool) -> bool {
    use std::ffi::c_int;
    use std::ffi::c_uint;
    use std::ffi::c_void;
    use std::ptr;

    assert_eq!(0, text.as_bytes()[text.len() - 1]);

    #[link(name = "User32")]
    extern "C" {
        pub fn MessageBoxA(
            hWnd: *mut c_void,
            lpText: *const i8,
            lpCaption: *const i8,
            uType: c_uint,
        ) -> c_int;
    }

    const MB_OK: c_uint = 0;
    const MB_YESNO: c_uint = 4;
    const MB_ICONERROR: c_uint = 0x10;
    const MB_DEFBUTTON2: c_uint = 0x100;
    const IDOK: c_int = 1;
    const IDYES: c_int = 6;

    let mut mode = if single_button {
        MB_OK
    } else {
        MB_YESNO | MB_DEFBUTTON2
    };

    if is_error {
        mode |= MB_ICONERROR;
    }

    let res = unsafe {
        MessageBoxA(
            ptr::null_mut(),
            text.as_ptr() as *const _,
            "dtkit-patch\0".as_ptr() as *const _,
            mode,
        )
    };

    if single_button {
        res == IDOK
    } else {
        res == IDYES
    }
}