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


# --- Linux AppImage (CONTRACT v1.2 amendment) ---------------------------------------------------------------

LINUX_IMAGE_EXPR = "Moonlight-${{ needs.validate.outputs.build_version }}-x86_64.AppImage"
LINUX_OK_EXPR = "LINUX_OK: ${{ needs.linux.result == 'success' }}"


def needs_of(job):
    m = re.search(r"(?m)^    needs: (.*)$", job)
    assert m, "job has no needs"
    return [n.strip() for n in m.group(1).strip("[]").split(",")]


def job_if(job):
    m = re.search(r"(?ms)^    if: (.*?)(?=^    [a-z-]+:)", job)
    assert m, "job has no if"
    return " ".join(m.group(1).replace(">-", " ").split())


def steps_of(job):
    """{step name: text} of a job (name lines are ``      - name: ...``)."""
    parts = re.split(r"(?m)^      - name: ", job.split("    steps:\n", 1)[1])
    return {p.split("\n", 1)[0]: p for p in parts[1:]}


def step(job, prefix):
    hits = [t for n, t in steps_of(job).items() if n.startswith(prefix)]
    assert len(hits) == 1, (prefix, len(hits))
    return hits[0]


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


def test_wrapper_job_graph_and_conditions_make_linux_optional():
    j = jobs(read(WRAPPER))
    assert list(j) == ["validate", "build", "linux", "package", "publish", "notify"]
    assert needs_of(j["package"]) == ["validate", "build", "linux"]
    assert needs_of(j["publish"]) == ["validate", "build", "linux", "package"]
    assert needs_of(j["notify"]) == ["validate", "build", "linux", "package", "publish"]
    # package and publish run although linux failed, but only for a successful, uncancelled Windows build
    pkg_if, pub_if = job_if(j["package"]), job_if(j["publish"])
    for cond in (pkg_if, pub_if):
        assert "!cancelled()" in cond and "always()" not in cond
        assert "needs.validate.result == 'success'" in cond and "needs.build.result == 'success'" in cond
        assert "needs.linux.result" not in cond  # the AppImage never gates the Windows release
    assert "needs.package.result == 'success'" in pub_if
    assert "needs.validate.outputs.dry_run == 'false'" in pub_if  # dry runs and trials never publish
    assert "dry_run" not in pkg_if


def test_every_linux_step_runs_only_when_linux_succeeded():
    j = jobs(read(WRAPPER))
    cond = "if: needs.linux.result == 'success'"
    pkg = steps_of(j["package"])
    for prefix in ("Make sure a squashfs reader", "Download Linux AppImage", "Mandatory gate - AppImage",
                   "Upload AppImage gate summary"):
        assert cond in step(j["package"], prefix), prefix
    pub = j["publish"]
    for prefix in ("Download Linux AppImage", "Download AppImage gate summary"):
        assert cond in step(pub, prefix), prefix
    # Windows-side steps are unconditional on linux
    for prefix in ("Download release artifact", "Download x64", "Download arm64", "Mandatory gate - bundle",
                   "Upload Windows gate summary"):
        assert "needs.linux.result" not in step(j["package"], prefix), prefix
    # the script steps branch on LINUX_OK and never name linux paths unconditionally
    for job, prefix in ((j["package"], "Stage the installer"), (pub, "Stage the installer")):
        st_ = step(job, prefix)
        assert LINUX_OK_EXPR in st_ and 'if [ "$LINUX_OK" = "true" ]; then' in st_
        assert "stage_linux=(--appimage-dir in/linux --appimage-gate-summary" in st_
        assert '"${stage_linux[@]}"' in st_ and '"${gen_linux[@]}"' in st_
        assert "--appimage-dir" not in st_.replace("stage_linux=(--appimage-dir", "")
    assert len(pkg) == len(set(pkg))


def test_squashfs_reader_is_installed_before_any_artifact_download():
    pkg = jobs(read(WRAPPER))["package"]
    names = list(steps_of(pkg))
    first_download = min(i for i, n in enumerate(names) if n.startswith("Download"))
    install = next(i for i, n in enumerate(names) if n.startswith("Make sure a squashfs reader"))
    assert install < first_download
    assert "squashfs-tools" in step(pkg, "Make sure a squashfs reader")


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
    assert "--linux-gate-summary appimage-gate-summary.json" in pkg
    assert "--appimage-gate-summary appimage-gate-summary.json" in pkg
    # the image is never run
    assert "squashfs-tools" in pkg and "--appimage-extract" not in text and "chmod +x" not in text
    # summaries: Windows one always, AppImage one only with linux; the dry-run preview holds only small files
    assert re.search(r"name: gate-summary\n\s+path: gate-summary.json\n", pkg)
    assert re.search(r"name: appimage-gate-summary\n\s+path: appimage-gate-summary.json\n", pkg)
    assert "path: preview-upload/" in pkg and "cp preview/manifest.json preview/SHA256SUMS gate-summary.json preview-upload/" in pkg
    assert "preview/Moonlight" not in pkg and ".AppImage preview-upload" not in pkg


def test_wrapper_publish_rebinds_stages_and_publishes_the_appimage_only_with_linux():
    pub = jobs(read(WRAPPER))["publish"]
    assert "name: Moonlight-LinuxAppImage-${{ needs.validate.outputs.build_version }}" in pub and "path: in/linux" in pub
    assert "stage_linux=(--appimage-dir in/linux --appimage-gate-summary in/summary/appimage-gate-summary.json)" in pub
    assert "gen_linux=(--linux-gate-summary in/summary/appimage-gate-summary.json)" in pub
    assert "continue-on-error" not in pub
    assert pub.count(f"LINUX_IMAGE: {LINUX_IMAGE_EXPR}") == 4 and pub.count(LINUX_OK_EXPR) >= 5
    # self-verify, upload, digest check: the AppImage joins the lists only when linux succeeded
    assert 'files=(MoonlightSetup.exe SHA256SUMS manifest.json)' in pub
    assert pub.count('if [ "$LINUX_OK" = "true" ]; then files+=("$LINUX_IMAGE"); fi') == 2
    assert 'files=(MoonlightSetup.exe SHA256SUMS manifest.json attestation.sigstore.json)' in pub
    assert 'assets=(dist/MoonlightSetup.exe dist/SHA256SUMS dist/manifest.json dist/attestation.sigstore.json)' in pub
    assert '"${assets[@]}"' in pub
    # verify-asset: no -f guard on the AppImage itself (it fails when missing)
    assert 'gh release verify-asset "$TAG" "dist/$LINUX_IMAGE"' in pub
    assert 'if [ -f "dist/$LINUX_IMAGE" ]' not in pub
    # the offline verification loop covers it with the unchanged consumer flags
    assert "--source-digest" in pub and "--signer-workflow" in pub and 'dist/$f' in pub


def test_wrapper_has_two_exclusive_attest_steps():
    pub = jobs(read(WRAPPER))["publish"]
    both = step(pub, "Attest installer, AppImage")
    win = step(pub, "Attest installer, SHA256SUMS and manifest")
    assert "needs.linux.result == 'success'" in both and "needs.linux.result != 'success'" in win
    assert "id: attest_both" in both and "id: attest_win" in win
    assert "dist/Moonlight-${{ needs.validate.outputs.build_version }}-x86_64.AppImage" in both
    assert "AppImage" not in win
    assert "steps.attest_both.outputs.bundle-path || steps.attest_win.outputs.bundle-path" in pub


def test_notify_raises_a_distinct_linux_alert_and_keeps_failure_for_windows():
    j = jobs(read(WRAPPER))["notify"]
    cond = job_if(j)
    assert "needs.validate.outputs.trial != 'true'" in cond                      # trials never alert
    assert "needs.linux.result == 'failure'" in cond and "needs.linux.result == 'cancelled'" in cond
    assert "contains(needs.*.result" not in cond                                  # linux must not count as 'failure'
    script = "\n".join(run_blocks(j))
    assert "kinds+=(linuxskipped)" in script and "kinds+=(failure)" in script and "kinds+=(success)" in script
    failure_loop = script.split("for r in", 1)[1].split("done", 1)[0]
    assert '"$VALIDATE" "$BUILD" "$PACKAGE" "$PUBLISHED"' in failure_loop and "LINUX" not in failure_loop
    assert '"$LINUX" = "failure"' in script and '"$LINUX" = "cancelled"' in script


def test_wrapper_never_executes_or_selects_the_appimage_by_pattern():
    text = read(WRAPPER)
    for block in run_blocks(text):
        assert "*.AppImage" not in block and "./dist/Moonlight-" not in block
        assert not re.search(r"(?m)^\s*\./\S*AppImage", block)
