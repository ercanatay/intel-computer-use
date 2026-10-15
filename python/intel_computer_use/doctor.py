from pathlib import Path
import platform
import plistlib
import struct


def macho_architectures(binary):
    try:
        with Path(binary).open("rb") as handle:
            data = handle.read(4096)
    except OSError:
        return []
    if len(data) < 8:
        return []
    magic = data[:4]
    names = {0x01000007: "x86_64", 0x0100000C: "arm64"}
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        byte_order = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
        cpu = struct.unpack_from(byte_order + "I", data, 4)[0]
        return [names[cpu]] if cpu in names else []
    formats = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20), b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}
    if magic not in formats:
        return []
    byte_order, stride = formats[magic]
    count = struct.unpack_from(byte_order + "I", data, 4)[0]
    if not 1 <= count <= 64 or len(data) < 8 + count * stride:
        return []
    cpus = {struct.unpack_from(byte_order + "I", data, 8 + index * stride)[0] for index in range(count)}
    return sorted(names[cpu] for cpu in cpus if cpu in names)


def inspect_vendor(app_path=None, codex_home=None):
    app = Path(app_path or "/Applications/ChatGPT.app")
    home = Path(codex_home or Path.home() / ".codex")
    candidates = [
        home / "computer-use/Codex Computer Use.app",
        app / "Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app",
        app / "Contents/Resources/cua_node/lib/node_modules/@oai/sky/bin/mac/normal/Codex Computer Use.app",
        app / "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app",
    ]
    helpers = [candidate / "Contents/MacOS/SkyComputerUseService" for candidate in candidates]
    installers = [candidate / "Contents/SharedSupport/Codex Computer Use Installer.app/Contents/MacOS/Codex Computer Use Installer" for candidate in candidates]
    helper_present = any(binary.is_file() for binary in helpers)
    installer_present = any(binary.is_file() for binary in installers)
    helper_architectures = sorted({architecture for binary in helpers for architecture in macho_architectures(binary)})
    installer_architectures = sorted({architecture for binary in installers for architecture in macho_architectures(binary)})
    version = None
    info = app / "Contents/Info.plist"
    if info.is_file():
        try:
            with info.open("rb") as handle:
                version = plistlib.load(handle).get("CFBundleShortVersionString")
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
    return {
        "architecture": platform.machine(), "vendor_app_present": app.is_dir(), "vendor_version": version,
        "official_helper_present": helper_present, "locked_use_installer_present": installer_present,
        "candidate_helper_architectures": helper_architectures,
        "candidate_installer_architectures": installer_architectures,
        "intel_payload_present": "x86_64" in helper_architectures and "x86_64" in installer_architectures,
        "locked_use": "unverified",
        "phase_1": "independent MCP native helper; does not replace vendor components",
        "phase_2": "Vendor helper is missing from checked locations." if not helper_present else "A helper file exists; architecture, signature, provenance, and trusted-turn unlock remain unverified.",
    }
