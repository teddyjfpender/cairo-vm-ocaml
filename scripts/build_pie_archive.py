"""Build the pinned optional archive library and collect its redistribution notices."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    manifest = Path(__file__).resolve().parents[1] / "native/pie-archive/Cargo.toml"
    target = prefix / "target"
    subprocess.run(["cargo", "build", "--locked", "--release", "-j1", "--manifest-path",
                    manifest, "--target-dir", target], check=True)
    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked",
                          "--format-version=1", "--manifest-path", manifest]))
    notices = prefix / "licenses"
    notices.mkdir(parents=True, exist_ok=True)
    for package in metadata["packages"]:
        if package["source"] is None:
            continue
        root = Path(package["manifest_path"]).parent
        for name in root.iterdir():
            if name.is_file() and name.name.upper().startswith(("LICENSE", "COPYING", "UNLICENSE")):
                shutil.copyfile(name, notices / f"{package['name']}-{package['version']}-{name.name}")
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    shutil.copyfile(sysroot / "share/doc/rust/COPYRIGHT-library.html", notices / "rust-library.html")
    library = prefix / "liboxcairo_pie_archive.a"
    shutil.copyfile(target / "release" / library.name, library)
    print(library)


if __name__ == "__main__":
    main()
