use std::io;
use std::path::PathBuf;

#[cfg(target_os = "windows")]
pub fn find_darktide() -> io::Result<PathBuf> {
    use std::ffi::OsString;
    use winreg::enums::*;
    use winreg::RegKey;

    const DARKTIDE_CLASS_PATH: &'static str = r"Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Families\FatsharkAB.Warhammer40000DarktideNew_hwm6pnepa3ng2";
    const REGISTRY_PACKAGE_FULL_NAME: &'static str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Index\PackageFullName";
    const REGISTRY_PACKAGE_INDEX: &'static str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Data";

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let hkcr = RegKey::predef(HKEY_CLASSES_ROOT);
    let apps = hkcr.open_subkey(DARKTIDE_CLASS_PATH)?;
    for app_name in apps.enum_keys() {
        let app_name = app_name?;
        let path = format!(r"{REGISTRY_PACKAGE_FULL_NAME}\{app_name}");
        let indexes = hklm.open_subkey(path)?;
        for index in indexes.enum_keys() {
            let index = index?;
            let path = format!(r"{REGISTRY_PACKAGE_INDEX}\{index}");
            let app_info = hklm.open_subkey(path)?;
            let dir: OsString = app_info.get_value("InstalledLocation")?;
            return Ok(PathBuf::from(dir));
        }
    }
    Err(io::Error::new(io::ErrorKind::NotFound, "gamepass version of Darktide not found"))
}

#[cfg(not(target_os = "windows"))]
pub fn find_darktide() -> io::Result<PathBuf> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "Xbox Game Pass lookup only supported on Windows"))
}
