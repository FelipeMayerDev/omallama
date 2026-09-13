"""What the widget reads must exist: the manifest points at a real file, and
every API field the QML touches is present in a recorded Ollama response.
Run: python tests/test_plugin.py"""
import json, pathlib, re, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
QML = (ROOT / "OmallamaWidget.qml").read_text()


def test_manifest():
    m = json.loads((ROOT / "manifest.json").read_text())
    assert m["kinds"] == ["bar-widget"]
    assert (ROOT / m["entryPoints"]["barWidget"]).is_file()


def test_api_fields_exist():
    tags = json.loads((ROOT / "tests/fixtures/tags.json").read_text())["models"][0]
    ps = json.loads((ROOT / "tests/fixtures/ps.json").read_text())["models"][0]
    for f in ("name", "size"):
        assert f in tags, f
    assert "context_length" in tags["details"]
    for f in ("name", "context_length", "size_vram"):
        assert f in ps, f


def test_pull_input_is_validated():
    # The pulled name is interpolated into a shell command line, so the guard
    # in front of it is the only thing between a text field and `sh -c`.
    pattern = re.search(r"/\^(.+?)\$/\.test\(name\)", QML).group(1)
    allow = re.compile("^" + pattern.replace("\\/", "/") + "$")
    assert allow.match("llama3.2:3b")
    assert allow.match("hf.co/user/repo:Q4_K_M")
    for bad in ["a; rm -rf ~", "a && b", "$(id)", "a b", "`id`", "a|b"]:
        assert not allow.match(bad), bad


def test_host_settings_are_declared():
    # Both are written by the panel and by the bar's settings pane, so the
    # schema and the defaults have to name them or one side loses the value.
    m = json.loads((ROOT / "manifest.json").read_text())
    keys = [f["key"] for f in m["barWidget"]["schema"]]
    assert keys == ["host", "remote"]
    assert m["barWidget"]["defaults"] == {"host": "", "remote": False}


def test_remote_is_off_without_an_address():
    # An empty address must not leave the widget pointed at nothing.
    assert 'root.remoteHost !== "" && root.setting("remote", false)' in QML


def test_remote_address_is_validated():
    # The address is user-entered and is interpolated into a shell command line
    # when a pull runs in a terminal.
    pattern = re.search(r"safeHost:\s*\n\s*/\^(.+?)\$/\.test", QML).group(1)
    allow = re.compile("^" + pattern.replace("\\/", "/") + "$")
    for good in ["http://127.0.0.1:11434", "https://ollama.lan:11434", "http://100.91.115.40:11434"]:
        assert allow.match(good), good
    for bad in ["http://a; rm -rf ~", "http://a$(id)", "http://a b", "http://a`id`", "ftp://x"]:
        assert not allow.match(bad), bad


def test_delete_goes_through_the_cli():
    # Qt's XMLHttpRequest drops the body on DELETE and Ollama reads the model
    # name from it, so this one call has to leave QML.
    assert 'removal.command = [root.cli, "rm", root.api, name]' in QML
    cli = (ROOT / "bin/omallama").read_text()
    assert "DELETE" in cli and "/api/delete" in cli


def test_delete_refuses_a_bad_host():
    # Unreachable address: curl -sf fails, and the widget reports it rather
    # than claiming the model is gone.
    r = subprocess.run([str(ROOT / "bin/omallama"), "rm", "http://127.0.0.1:1", "whatever"],
                       capture_output=True)
    assert r.returncode != 0


def test_delete_needs_a_model():
    r = subprocess.run([str(ROOT / "bin/omallama"), "rm", "http://127.0.0.1:11434"],
                       capture_output=True)
    assert r.returncode != 0


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn(); print("ok", name)
