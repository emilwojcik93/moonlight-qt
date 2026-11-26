"""Structural security checks over the workflow files (complements actionlint/zizmor)."""
import glob
import os
import re

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOWS = sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")))
WRAPPER = os.path.join(ROOT, "ci", "wrapper", "patched-windows-release.yml")
ALL = WORKFLOWS + [WRAPPER]


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def uses_lines(text):
    for ln in text.splitlines():
        m = re.match(r"\s*(?:-\s*)?uses:\s*(\S+)(?:\s*#\s*(.*))?$", ln)
        if m:
            yield m.group(1), m.group(2) or ""


def run_blocks(text):
    """Yield the text of every ``run:`` value (block scalar or single line)."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"(\s*)(?:-\s*)?run:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent, rest = len(m.group(1)), m.group(2)
        if rest.startswith(("|", ">")):
            block = []
            i += 1
            while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
                block.append(lines[i])
                i += 1
            yield "\n".join(block)
        else:
            yield rest
            i += 1


def jobs(text):
    """Return {job_name: text} for the top-level jobs mapping (2-space indented keys)."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", body)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts), 2)}


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_top_level_permissions_empty(path):
    assert re.search(r"(?m)^permissions:\s*\{\}\s*$", read(path))


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_no_dangerous_triggers(path):
    text = read(path)
    for bad in ("pull_request_target", "issue_comment", "workflow_run", "pull_request_review", "discussion"):
        assert not re.search(rf"(?m)^\s*{bad}\b", text), bad


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_every_action_pinned_by_sha_with_version_comment(path):
    for ref, comment in uses_lines(read(path)):
        if ref.startswith("./"):
            continue
        assert re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}", ref), ref
        assert re.match(r"v[0-9]+(\.[0-9]+)*", comment), f"missing version comment: {ref}"


def test_same_action_same_sha_everywhere():
    seen = {}
    for path in ALL:
        for ref, _ in uses_lines(read(path)):
            if ref.startswith("./"):
                continue
            name, sha = ref.split("@")
            assert seen.setdefault(name, sha) == sha, f"{name} pinned to different SHAs"


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_no_expression_interpolation_in_run_scripts(path):
    for block in run_blocks(read(path)):
        assert "${{" not in block, block[:120]


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_checkout_never_persists_credentials(path):
    text = read(path)
    for m in re.finditer(r"uses:\s*actions/checkout@[^\n]*\n((?:\s+[a-z-]+:[^\n]*\n)+)", text):
        assert "persist-credentials: false" in m.group(1)


@pytest.mark.parametrize("path", ALL, ids=os.path.basename)
def test_every_job_has_a_timeout_or_is_reusable_call(path):
    for name, body in jobs(read(path)).items():
        assert "timeout-minutes:" in body or re.search(r"(?m)^    uses:", body), name


def test_wrapper_privilege_separation():
    j = jobs(read(WRAPPER))
    for name in ("validate", "build", "package"):
        assert "write" not in re.sub(r"#.*", "", j[name].split("steps:")[0]), name
        assert "id-token" not in j[name]
    assert "permissions: {}" in j["package"]
    pub = j["publish"]
    assert "id-token: write" in pub and "attestations: write" in pub and "contents: write" in pub
    assert "environment:" in pub
    assert "dry_run == 'false'" in pub
    assert "secrets." not in read(WRAPPER)
    # build job passes no secrets to upstream's reusable workflow and never runs on a tag ref
    assert "secrets:" not in j["build"] and "inherit" not in j["build"]
    # the build can only reach the publish job through artifacts: publish needs package (the version gate)
    assert "package" in re.search(r"(?m)^    needs: (.*)$", pub).group(1)


def test_wrapper_build_uses_the_reusable_upstream_workflow_without_secrets():
    build = jobs(read(WRAPPER))["build"]
    assert "uses: ./.github/workflows/build-win-mac.yml" in build
    for expect in ("ci_version: ${{ needs.validate.outputs.build_version }}",
                   "source_ref: ${{ needs.validate.outputs.source_sha }}",
                   "build_macos: false"):
        assert expect in build, expect
    assert "contents: read" in build and "id-token" not in build and "secrets" not in build.replace("no secrets", "")


def test_wrapper_gate_is_mandatory_and_precedes_manifest():
    text = read(WRAPPER)
    pkg = jobs(text)["package"]
    assert "bundle_gate.py" in pkg and "continue-on-error" not in pkg
    assert pkg.index("bundle_gate.py") < pkg.index("stage_assets.py") < pkg.index("manifest_gen.py generate")
    pub = jobs(text)["publish"]
    assert "--gate-summary in/summary/gate-summary.json" in pub  # publish re-binds the staged bytes to the gate
    assert "continue-on-error" not in pub


def test_wrapper_attests_exactly_installer_appimage_sums_and_manifest():
    pub = jobs(read(WRAPPER))["publish"]
    subjects = [ln.strip() for ln in re.search(r"subject-path: \|\n((?:\s+dist/[^\n]+\n)+)", pub).group(1).splitlines()]
    assert subjects == ["dist/MoonlightSetup.exe",
                        "dist/Moonlight-${{ needs.validate.outputs.build_version }}-x86_64.AppImage",
                        "dist/SHA256SUMS", "dist/manifest.json"]
    assert "gh release create" in pub and "dist/attestation.sigstore.json" in pub
    # offline verify with the exact flags the Windows updater passes
    for flag in ("--bundle", "--signer-workflow", "--source-ref", "--source-digest", "--deny-self-hosted-runners",
                 "--predicate-type https://slsa.dev/provenance/v1",
                 "--cert-oidc-issuer https://token.actions.githubusercontent.com"):
        assert flag in pub, flag


def test_wrapper_triggers_only_build_branches():
    text = read(WRAPPER)
    assert "'build/**'" in text and "'ci-trial/**'" in text
    assert not re.search(r"(?m)^\s*(tags|schedule):", text)


def test_upstream_watch_privileges():
    j = jobs(read(os.path.join(ROOT, ".github", "workflows", "upstream-watch.yml")))
    assert "write" not in re.sub(r"#.*", "", j["resolve"].split("steps:")[0])
    assert "environment: build-push" in j["prepare"]
    assert "create-github-app-token" in j["prepare"]
    # no fallback to a broader token for the branch push
    assert "secrets.GITHUB_TOKEN" not in read(os.path.join(ROOT, ".github", "workflows", "upstream-watch.yml"))
    assert "--force" not in j["prepare"].replace("# No --force", "")


def test_wrapper_template_pins_match_workflows():
    """Dependabot does not scan ci/wrapper; fail when its pins drift from the real workflows."""
    wf_pins = {}
    for path in WORKFLOWS:
        for ref, _ in uses_lines(read(path)):
            if not ref.startswith("./"):
                name, sha = ref.split("@")
                wf_pins.setdefault(name, set()).add(sha)
    for ref, _ in uses_lines(read(WRAPPER)):
        if ref.startswith("./"):
            continue
        name, sha = ref.split("@")
        if name in wf_pins:
            assert sha in wf_pins[name], f"{name}: wrapper pin differs from .github/workflows (sync after Dependabot)"


# --- Linux AppImage (CONTRACT v1.2 amendment) -----------------------------------------------------------------

LINUX_IMAGE_EXPR = "Moonlight-${{ needs.validate.outputs.build_version }}-x86_64.AppImage"


def needs_of(job):
    m = re.search(r"(?m)^    needs: (.*)$", job)
    assert m, "job has no needs"
    return [n.strip() for n in m.group(1).strip("[]").split(",")]


def test_wrapper_linux_job_mirrors_the_windows_build_job():
    j = jobs(read(WRAPPER))
    lin = j["linux"]
    assert "uses: ./.github/workflows/build-appimage.yml" in lin
    for expect in ("ci_version: ${{ needs.validate.outputs.build_version }}",
                   "source_ref: ${{ needs.validate.outputs.source_sha }}"):
        assert expect in lin and expect in j["build"], expect
    assert "build_macos" not in lin  # the AppImage workflow has no such input
    assert needs_of(lin) == ["validate"]
    # same permission style as the Windows build: contents: read, nothing else, no secrets
    assert "contents: read" in lin and "write" not in re.sub(r"#.*", "", lin)
    assert "id-token" not in lin and "secrets" not in lin.replace("no secrets", "") and "inherit" not in lin
    assert "runs-on" not in lin and "steps:" not in lin  # a pure reusable-workflow call


def test_wrapper_job_graph_with_the_linux_job():
    j = jobs(read(WRAPPER))
    assert list(j) == ["validate", "build", "linux", "package", "publish", "notify"]
    assert needs_of(j["package"]) == ["validate", "build", "linux"]
    assert needs_of(j["publish"]) == ["validate", "build", "linux", "package"]
    assert needs_of(j["notify"]) == ["validate", "build", "linux", "package", "publish"]
    # dry runs: publish still only runs for real releases; notify still reports any failure (incl. linux)
    assert "dry_run == 'false'" in j["publish"]
    assert "contains(needs.*.result, 'failure')" in j["notify"]
    assert "write" not in re.sub(r"#.*", "", j["linux"])


def test_wrapper_adds_no_new_third_party_action():
    refs = {ref.split("@")[0] for ref, _ in uses_lines(read(WRAPPER)) if not ref.startswith("./")}
    assert refs == {"actions/checkout", "actions/download-artifact", "actions/upload-artifact", "actions/attest"}
    local = {ref for ref, _ in uses_lines(read(WRAPPER)) if ref.startswith("./")}
    assert local == {"./.github/workflows/build-win-mac.yml", "./.github/workflows/build-appimage.yml"}


def test_wrapper_appimage_gate_is_mandatory_unprivileged_and_precedes_staging():
    text = read(WRAPPER)
    pkg = jobs(text)["package"]
    assert "appimage_gate.py" in pkg and "continue-on-error" not in pkg and "permissions: {}" in pkg
    assert pkg.index("bundle_gate.py") < pkg.index("appimage_gate.py") < pkg.index("stage_assets.py") \
        < pkg.index("manifest_gen.py generate")
    assert "name: Moonlight-LinuxAppImage-${{ needs.validate.outputs.build_version }}" in pkg
    assert "path: in/linux" in pkg
    assert '--image "in/linux/Moonlight-${BUILD_VERSION}-x86_64.AppImage"' in pkg
    assert "--appimage-dir in/linux --appimage-gate-summary appimage-gate-summary.json" in pkg
    assert "--linux-gate-summary appimage-gate-summary.json" in pkg
    # a reader for the zstd squashfs is installed from the distribution when missing; the image is never run
    assert "squashfs-tools" in pkg and "--appimage-extract" not in text and "chmod +x" not in text
    # both summaries travel to publish in the same artifact; dry runs also preview the Linux one
    assert re.search(r"name: gate-summary\n\s+path: \|\n\s+gate-summary.json\n\s+appimage-gate-summary.json\n", pkg)
    assert "preview/appimage-gate-summary.json" in pkg


def test_wrapper_publish_rebinds_stages_and_publishes_the_appimage():
    pub = jobs(read(WRAPPER))["publish"]
    assert "name: Moonlight-LinuxAppImage-${{ needs.validate.outputs.build_version }}" in pub and "path: in/linux" in pub
    assert "--appimage-dir in/linux --appimage-gate-summary in/summary/appimage-gate-summary.json" in pub
    assert "--linux-gate-summary in/summary/appimage-gate-summary.json" in pub
    assert "continue-on-error" not in pub
    # every step that lists the release files knows the AppImage: self-verify, upload, digest check, verify-asset
    assert pub.count(f"LINUX_IMAGE: {LINUX_IMAGE_EXPR}") == 4
    assert 'for f in MoonlightSetup.exe "$LINUX_IMAGE" SHA256SUMS manifest.json; do' in pub
    assert 'dist/MoonlightSetup.exe "dist/$LINUX_IMAGE" dist/SHA256SUMS dist/manifest.json' in pub
    assert 'for f in MoonlightSetup.exe "$LINUX_IMAGE" SHA256SUMS manifest.json attestation.sigstore.json; do' in pub
    assert 'gh release verify-asset "$TAG" "dist/$LINUX_IMAGE"' in pub
    # the offline verification loop covers it with the unchanged consumer flags
    assert "--source-digest" in pub and "--signer-workflow" in pub
    assert 'dist/$f' in pub


def test_wrapper_never_executes_or_selects_the_appimage_by_pattern():
    text = read(WRAPPER)
    for block in run_blocks(text):
        assert "*.AppImage" not in block and "./dist/Moonlight-" not in block
        assert not re.search(r"(?m)^\s*\./\S*AppImage", block)
