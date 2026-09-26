"""把本地 HEAD 通过 GitHub Git Data API 推成远程 main 的同 hash 提交。

本地 git push 不可用（见 AGENTS.md「Pushing from this machine」）。
关键点：commit 的 author/committer（含 ISO 日期）与 tree/parents 完全一致时，
API 造出的 commit sha 与本地 git commit-tree 造出的完全相同，因此两边不会分叉。
"""
import base64
import json
import subprocess
import sys

REPO = "Liu-bits/Terminal-ios"
BRANCH = "main"


def gh(*args, data=None):
    cmd = ["gh", "api", *args]
    if data is not None:
        cmd += ["--input", "-"]
    p = subprocess.run(
        cmd,
        input=json.dumps(data) if data is not None else None,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if p.returncode != 0:
        print("gh 失败:", " ".join(cmd))
        print(p.stderr[:600])
        sys.exit(1)
    return json.loads(p.stdout or "null")


def git(*args, text=True):
    return subprocess.run(
        ["git", *args], capture_output=True, text=text, encoding="utf-8" if text else None
    ).stdout


head = git("rev-parse", "HEAD").strip()
info = git("log", "-1", "--format=%an%n%ae%n%aI%n%cn%n%ce%n%cI").strip().split("\n")
message = git("log", "-1", "--format=%B").rstrip("\n")
an, ae, aI, cn, ce, cI = info

remote = gh(f"repos/{REPO}/git/ref/heads/{BRANCH}")
remote_sha = remote["object"]["sha"]
print("远程 main:", remote_sha[:7], "| 本地 HEAD:", head[:7])

# 1. blob
tree_entries = []
for item in git("ls-tree", "-r", "-z", "HEAD").split("\0"):
    if not item:
        continue
    meta, path = item.split("\t", 1)
    mode, _t, sha = meta.split()
    content = git("cat-file", "blob", sha, text=False)
    blob = gh(
        f"repos/{REPO}/git/blobs",
        data={"content": base64.b64encode(content).decode(), "encoding": "base64"},
    )
    tree_entries.append(
        {
            "path": path,
            "mode": "100755" if mode == "100755" else "100644",
            "type": "blob",
            "sha": blob["sha"],
        }
    )
print(f"blob 上传: {len(tree_entries)} 个")

# 2. tree
tree = gh(f"repos/{REPO}/git/trees", data={"tree": tree_entries})
local_tree = git("rev-parse", "HEAD^{tree}").strip()
print("tree:", tree["sha"][:7], "| 本地 tree:", local_tree[:7], "一致" if tree["sha"] == local_tree else "不一致!")

# 3. commit
commit = gh(
    f"repos/{REPO}/git/commits",
    data={
        "message": message,
        "tree": tree["sha"],
        "parents": [remote_sha],
        "author": {"name": an, "email": ae, "date": aI},
        "committer": {"name": cn, "email": ce, "date": cI},
    },
)
print("commit:", commit["sha"][:7], "| 本地 HEAD:", head[:7], "一致" if commit["sha"] == head else "不一致!")

# 4. ref
gh(
    f"repos/{REPO}/git/refs/heads/{BRANCH}",
    data={"sha": commit["sha"], "force": True},
)
final = gh(f"repos/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
print("远程 main 更新为:", final[:7], "| 同步:", final == head)
