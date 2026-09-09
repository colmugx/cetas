#!/usr/bin/env python3
"""Cetas release automation — GitHub-release flow (Python stdlib only).

Usage:
  release.py check                   version consistency gate; exit 1 on skew
  release.py release [flags]         full release flow (default subcommand)

Flags (release):
  --version X.Y.Z   skip the version suggestion prompt
  --notes-file P    use file content as release notes verbatim; skips $EDITOR
  --dry-run         print every action prefixed "DRY:"; no writes/commits/tags
  --yes             skip interactive confirmations (still prints the plan)

Flow: preflight (repo root, unused cetas-v* tag; dirty tree allowed — release
content counts committed changes only) -> scan commits since the
newest cetas-v* tag -> suggest semver (feat/breaking -> minor, else patch;
0.x forever) -> grouped notes draft -> $EDITOR or --notes-file -> preview ->
apply (VERSION, 4 sync targets, CHANGELOG.md insert, commit, annotated tag)
-> optional push prompt + submodule-pointer reminder.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
MOON_READ = re.compile(r'(?m)^version\s*=\s*"([^"]+)"')
ACP_READ = re.compile(r'const\s+CETAS_ACP_VERSION\s*=\s*"([^"]+)"')
MOON_SUB = re.compile(r'(?m)^(version\s*=\s*)"[^"]+"')
ACP_SUB = re.compile(r'(?m)^(const\s+CETAS_ACP_VERSION\s*=\s*)"[^"]+"')
META = re.compile(r"(?m)^([0-9a-f]{40})\x1f")
TYPE = re.compile(r"^([a-z]+)(?:\([^)]*\))?!?:")
FEAT = re.compile(r"^feat(\(|!|:)")
FIX = re.compile(r"^fix(\(|!|:)")
BREAKING = re.compile(r"(?m)^BREAKING[-_ ]CHANGE|^[a-z]+(\([^)]*\))?!:")
RELEASE_SKIP = re.compile(r"^chore\(release\):")
COMPONENTS = frozenset(
    ("cetas-js", "cetas-acp", "cetas-core", "cetas-headless", "cetas-ext-forme", "extension")
)
GROUP_OF = {"feat": "Added", "fix": "Fixed", "refactor": "Changed", "perf": "Changed"}
SYNC = [
    ("cetas-js/moon.mod", MOON_READ, MOON_SUB),
    ("cetas-js/package.json", None, None),
    ("cetas-acp/moon.mod", MOON_READ, MOON_SUB),
    ("cetas-acp/main/main.mbt", ACP_READ, ACP_SUB),
]
NOTES_HEADER = (
    "<!-- 此文件内容将作为发布说明（写入 CHANGELOG.md 小节）。"
    "编辑后保存退出；清空全文则放弃本次发布。 -->"
)


def script_root():
    return Path(__file__).resolve().parent.parent


def die(msg, code=1):
    sys.stderr.write(f"错误: {msg}\n")
    sys.exit(code)


def sh(root, *cmd):
    r = subprocess.run(list(cmd), cwd=str(root), capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"命令失败: {' '.join(cmd)}\n{r.stderr.strip()}\n")
        sys.exit(1)
    return r.stdout


def git(root, *args):
    return sh(root, "git", *args).strip()


def is_tty():
    return sys.stdin.isatty()


# ---------------------------------------------------------------- check


def target_versions(root):
    rows = []
    for rel, rx, _ in SYNC:
        p = root / rel
        if not p.exists():
            rows.append((rel, None, "文件缺失"))
            continue
        if rx is None:
            try:
                rows.append((rel, json.loads(p.read_text())["version"], None))
            except Exception as e:
                rows.append((rel, None, f"解析失败: {e}"))
        else:
            m = rx.search(p.read_text())
            rows.append((rel, m.group(1) if m else None, None if m else "未匹配到版本行"))
    return rows


def cmd_check(args):
    root = script_root()
    vp = root / "VERSION"
    if not vp.exists():
        die("VERSION 不存在")
    expected = vp.read_text().strip()
    if not SEMVER.match(expected):
        die(f"VERSION 内容不是 semver: {expected!r}")
    print(f"版本一致性检查（期望 {expected}）:")
    bad = 0
    for rel, actual, err in target_versions(root):
        if err:
            print(f"  {rel:<26} ERROR {err}")
            bad += 1
        elif actual != expected:
            print(f"  {rel:<26} MISMATCH expected {expected}, found {actual}")
            bad += 1
        else:
            print(f"  {rel:<26} {actual}  ok")
    if bad:
        die(f"{bad} 个目标与 VERSION 不一致")
    print(f"OK: 全部一致 ({expected})")


# ---------------------------------------------------------------- history


def scan_commits(root, base):
    rng = [f"{base}..HEAD"] if base else []
    out = sh(root, "git", "log", "--format=%H%x1f%s%x1f%b%x1e", "--name-only", *rng)
    commits = []
    for chunk in out.split("\x1e"):
        m = META.search(chunk)
        if m:
            if commits:
                commits[-1]["paths"] = [ln for ln in chunk[: m.start()].splitlines() if ln.strip()]
            subject, _, body = chunk[m.end():].partition("\x1f")
            commits.append({"hash": m.group(1), "subject": subject, "body": body, "paths": []})
        elif commits:
            commits[-1]["paths"] = [ln for ln in chunk.splitlines() if ln.strip()]
    return commits


def find_base(root):
    for t in git(root, "tag", "--list", "cetas-v*", "--sort=-v:refname").splitlines():
        if SEMVER.match(t.removeprefix("cetas-v")):
            return t
    return None


def reason_counts(commits):
    return (
        sum(1 for c in commits if FEAT.match(c["subject"])),
        sum(1 for c in commits if FIX.match(c["subject"])),
        sum(1 for c in commits if BREAKING.search(c["subject"]) or BREAKING.search(c["body"])),
    )


def bump(v, level):
    a, b, c = (int(x) for x in v.split("."))
    return f"{a}.{b + 1}.0" if level == "minor" else f"{a}.{b}.{c + 1}"


def component(paths):
    for p in paths:
        seg = p.split("/", 1)[0]
        if seg in COMPONENTS:
            return seg
    return None


def draft_notes(commits):
    groups = {}
    for c in commits:
        if RELEASE_SKIP.match(c["subject"]):
            continue
        m = TYPE.match(c["subject"])
        name = GROUP_OF.get(m.group(1) if m else "", "Internal")
        label = component(c["paths"])
        prefix = f"[{label}] " if label else ""
        groups.setdefault(name, []).append(f"- {prefix}{c['subject']} ({c['hash'][:7]})")
    out = []
    for name in ("Added", "Fixed", "Changed", "Internal"):
        if groups.get(name):
            out.append(f"### {name}")
            out.extend(groups[name])
    return "\n".join(out)


# ---------------------------------------------------------------- flow


def ensure_tag_free(root, v):
    tag = f"cetas-v{v}"
    if git(root, "tag", "--list", tag):
        die(f"标签 {tag} 已存在于本地")
    r = subprocess.run(
        ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}"],
        cwd=str(root), capture_output=True, text=True,
    )
    if r.returncode != 0:
        print("警告: 无法查询 origin tags（无 origin 或离线），仅检查了本地标签")
    elif r.stdout.strip():
        die(f"标签 {tag} 已存在于 origin")
    print(f"标签 {tag} 可用")


def preflight(root, args):
    top = git(root, "rev-parse", "--show-toplevel")
    if Path(top).resolve() != root.resolve():
        die(f"脚本所在仓库根 {root} 与 git 仓库根 {top} 不一致；拒绝在仓库外运行")
    if args.version and not SEMVER.match(args.version):
        die(f"--version 不是 semver: {args.version!r}")
    dirty = git(root, "status", "--porcelain")
    if dirty:
        n = len(dirty.splitlines())
        print(f"警告: 工作区有 {n} 处未提交变更，不参与本次发布；发布内容只统计已提交记录")
    if args.version:
        ensure_tag_free(root, args.version)


def read_current_version(root):
    vp = root / "VERSION"
    if not vp.exists():
        return None
    v = vp.read_text().strip()
    if not SEMVER.match(v):
        die(f"VERSION 内容不是 semver: {v!r}")
    return v


def choose_version(args, cur, suggested, level):
    if args.version:
        print(f"目标版本 {args.version} (--version 指定)")
        return args.version
    if not is_tty() and not args.yes:
        die("非交互环境无法选择版本；请使用 --version X.Y.Z 或 --yes")
    if args.yes:
        if cur is None:
            die("VERSION 缺失且未指定 --version，无法推断版本")
        print(f"目标版本 {suggested} (建议 {level}，--yes)")
        return suggested
    if cur is None:
        die("VERSION 缺失，无法建议版本；请使用 --version X.Y.Z")
    ans = input(f"建议版本 {suggested} ({level})。回车接受，或输入版本号: ").strip()
    v = ans or suggested
    if not SEMVER.match(v):
        die(f"无效版本号: {v!r}")
    return v


def get_notes(args, draft):
    if args.notes_file:
        p = Path(args.notes_file)
        if not p.exists():
            die(f"--notes-file 不存在: {p}")
        return p.read_text().strip("\n")
    if not is_tty():
        die("非交互环境无法打开编辑器；请使用 --notes-file")
    fd, path = tempfile.mkstemp(prefix="cetas-release-", suffix=".md")
    with os.fdopen(fd, "w") as f:
        f.write(NOTES_HEADER + "\n\n" + (draft + "\n" if draft else ""))
    try:
        subprocess.call(shlex.split(os.environ.get("EDITOR") or "vi") + [path])
        text = Path(path).read_text()
    finally:
        os.unlink(path)
    if text.startswith(NOTES_HEADER):
        text = text[len(NOTES_HEADER):]
    if not text.strip():
        die("发布说明为空，已放弃")
    return text.strip("\n")


def changelog_section(v, notes):
    return f"## {v} ({date.today().isoformat()})\n\n{notes.strip('\n')}\n"


def write_changelog(root, section):
    p = root / "CHANGELOG.md"
    if not p.exists():
        p.write_text(f"# Changelog\n\n{section}")
        return "created"
    text = p.read_text()
    m = re.search(r"(?m)^## ", text)
    if m:
        head = text[:m.start()]
        if head.strip():
            head = head.rstrip("\n") + "\n\n"
        p.write_text(head + section + "\n" + text[m.start():])
        return "inserted"
    p.write_text(text.rstrip("\n") + "\n\n" + section)
    return "appended"


def set_version(root, rel, sub_rx, v):
    p = root / rel
    if sub_rx is None:
        data = json.loads(p.read_text())
        data["version"] = v
        p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        return
    text = p.read_text()
    new, n = sub_rx.subn(lambda m: f'{m.group(1)}"{v}"', text, count=1)
    if n != 1:
        die(f"{rel} 中未找到版本行")
    p.write_text(new)


def apply_release(root, v, notes, args):
    section = changelog_section(v, notes)
    commit = f"chore(release): cetas-v{v}"
    tag = f"cetas-v{v}"
    paths = ["VERSION", *(r for r, _, _ in SYNC), "CHANGELOG.md"]
    print("=== 发布内容预览（将插入 CHANGELOG.md）===")
    print(section)
    print("将修改: " + ", ".join(paths))
    print(f"提交: {commit}")
    print(f'标签: {tag} (annotated, "Cetas {v}")')
    if args.dry_run:
        print(f"DRY: 写入 VERSION = {v}")
        for rel, _, _ in SYNC:
            print(f"DRY: 同步 {rel} -> {v}")
        print(f"DRY: {'创建' if not (root / 'CHANGELOG.md').exists() else '更新'} CHANGELOG.md（插入新小节）")
        print(f"DRY: git add -- {' '.join(paths)}")
        print(f"DRY: git commit -m '{commit}'")
        print(f"DRY: git tag -a {tag} -m 'Cetas {v}'")
        return
    if not args.yes:
        if not is_tty():
            die("非交互环境需要 --yes 才能执行写入")
        if input("应用以上变更? [y/N] ").strip().lower() not in ("y", "yes"):
            print("已取消，未做任何修改")
            sys.exit(1)
    (root / "VERSION").write_text(v + "\n")
    print(f"写入 VERSION = {v}")
    for rel, _, sub in SYNC:
        set_version(root, rel, sub, v)
        print(f"同步 {rel} = {v}")
    print(f"{write_changelog(root, section)} CHANGELOG.md")
    git(root, "add", "--", *paths)
    git(root, "commit", "-m", commit)
    print(f"已提交 {commit}")
    git(root, "tag", "-a", tag, "-m", f"Cetas {v}")
    print(f"已打标签 {tag}")


def push_step(root, tag):
    do = is_tty() and input(f"推送 main + tag 到 origin? (触发 release CI) [y/N] ").strip().lower() in ("y", "yes")
    if not do:
        print(f"跳过推送。手动执行: git push origin HEAD:main && git push origin {tag}")
        return
    for cmd in (["git", "push", "origin", "HEAD:main"], ["git", "push", "origin", tag]):
        r = subprocess.run(cmd, cwd=str(root), capture_output=True, text=True)
        if r.returncode != 0:
            print(f"推送失败: {' '.join(cmd)}\n{r.stderr.strip()}")
            print(f"手动执行: git push origin HEAD:main && git push origin {tag}")
            return
    print("已推送。")


def cmd_release(args):
    root = script_root()
    preflight(root, args)
    base = find_base(root)
    commits = scan_commits(root, base)
    rng = f"{base}..HEAD" if base else "仓库起点..HEAD"
    feat, fix, brk = reason_counts(commits)
    level = "minor" if (feat or brk) else "patch"
    if commits:
        print(f"扫描 {rng}: {len(commits)} 个提交 (feat: {feat}, fix: {fix}, breaking: {brk})")
    else:
        print(f"警告: {rng} 没有提交，发布说明需手写")
    cur = read_current_version(root)
    if cur is None:
        print("警告: VERSION 缺失，本次发布将创建它")
    else:
        print(f"当前版本 {cur}，建议版本 {bump(cur, level)} ({level})")
    v = choose_version(args, cur, bump(cur, level) if cur else None, level)
    if not args.version:
        ensure_tag_free(root, v)
    draft = None if args.notes_file else draft_notes(commits)
    notes = get_notes(args, draft)
    apply_release(root, v, notes, args)
    if not args.dry_run:
        push_step(root, f"cetas-v{v}")
    print("提醒: posoco 父仓库的 external/cetas submodule 指针需手动更新。")


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] not in ("release", "check", "-h", "--help"):
        argv = ["release", *argv]
    ap = argparse.ArgumentParser(
        description="Cetas release automation: `check` is the CI version-consistency gate; "
        "`release` (default) runs the full GitHub-release flow. See module docstring for flags."
    )
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="{release,check}")
    rp = sub.add_parser("release", help="full release flow (default subcommand)")
    rp.add_argument("--version", metavar="X.Y.Z", help="skip the version suggestion prompt")
    rp.add_argument("--notes-file", metavar="PATH", help="release notes file; skips $EDITOR")
    rp.add_argument("--dry-run", action="store_true", help="print actions prefixed DRY:; no writes")
    rp.add_argument("--yes", action="store_true", help="skip interactive confirmations")
    rp.set_defaults(func=cmd_release)
    cp = sub.add_parser("check", help="version consistency gate; exit 1 on skew")
    cp.set_defaults(func=cmd_check)
    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
