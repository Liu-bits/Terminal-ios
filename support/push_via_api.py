"""把本地 HEAD 通过 GitHub Git Data API 推成远程 main 的同 hash 提交。

本地 git push 不可用（详见 AGENTS.md「Pushing from this machine」）。

要让本地与远程 hash 完全一致，提交对象的字节必须一模一样，两个坑：
- GitHub 原样保存 message，不会补尾换行；而 `git commit` 一定补一个 \n。
  所以本地提交用 `git hash-object -w -t commit` 手工构造（message 不带尾换行）。
- 时间要写成 UTC（+0000）：GitHub 会把带偏移的时间归一成 Z，偏移不同则 hash 不同。

用法：先手工构造好本地提交对象并让 main 指向它，再运行本脚本。
"""
import base64
import datetime
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
        ["git", *args], capture_output=True, text=text,
        encoding="utf-8" if text else None,
    ).stdout


head = git("rev-parse", "HEAD").strip()
raw = git("cat-file", "commit", "HEAD")
header, message = raw.split("\n\n", 1)  # message 原样使用，不补不剥
fields = header.split("\n")


def field(prefix):
    for line in fields:
        if line.startswith(prefix):
            return line[len(prefix):]
    return None


def ident(line):
    """'Liu-bits <mail> 1790431800 +0000' -> (name, email, iso8601 UTC)"""
    who, _, tz = line.rpartition(" ")
    who, _, epoch = who.rpartition(" ")
    name, _, mail = who.partition(" <")
    mail = mail.rstrip(">")
    sign = -1 if tz.startswith("-") else 1
    offset = datetime.timedelta(hours=int(tz[1:3]), minutes=int(tz[3:5])) * sign
    stamp = datetime.datetime.fromtimestamp(
        int(epoch), datetime.timezone.utc
    ) + offset
    return name, mail, stamp.strftime("%Y-%m-%dT%H:%M:%SZ")


tree_sha = field("tree ")
parents = [line[7:] for line in fields if line.startswith("parent ")]
an, ae, a_date = ident(field("author "))
cn, ce, c_date = ident(field("committer "))

remote_sha = gh(f"repos/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
print("远程 main:", remote_sha[:7], "| 本地 HEAD:", head[:7])

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

tree = gh(f"repos/{REPO}/git/trees", data={"tree": tree_entries})
print("tree:", tree["sha"][:7], "| 本地:", tree_sha[:7],
      "一致" if tree["sha"] == tree_sha else "不一致!")

commit = gh(
    f"repos/{REPO}/git/commits",
    data={
        "message": message,
        "tree": tree_sha,
        "parents": parents,
        "author": {"name": an, "email": ae, "date": a_date},
        "committer": {"name": cn, "email": ce, "date": c_date},
    },
)
if commit["sha"] != head:
    print("commit:", commit["sha"][:7], "| 本地 HEAD:", head[:7], "不一致!")
    print("message 尾部 repr:", repr(message[-40:]))
    back = gh(f"repos/{REPO}/git/commits/{commit['sha']}")
    print("远程回显尾部 repr:", repr(back["message"][-40:]))
    print("远程 author:", back["author"], "本地:", an, ae, a_date)
    print("远程 tree/parents:", back["tree"]["sha"], [p["sha"] for p in back["parents"]])
    sys.exit(1)
print("commit:", commit["sha"][:7], "= 本地 HEAD (hash 完全一致)")

gh(f"repos/{REPO}/git/refs/heads/{BRANCH}",
   data={"sha": commit["sha"], "force": True})
final = gh(f"repos/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
print("远程 main:", final[:7], "| 同步:", final == head)
